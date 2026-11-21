///|
/// 一帧抓好的画面
pub struct Frame {
  bytes : Bytes
  ts : Int64
}

///|
/// 采集状态：一帧缓存 + 统计 + 一把锁
///
/// spectacle 是单实例应用，同时拉起多个会互相卡死（实测三个并发就永久挂住）。
/// 所以采集必须串行，且并发请求只能合并成一次采集：抢到锁后再判一次帧龄。
pub struct Store {
  shot : String
  lock : @async.Mutex
  magick : String?
  /// 测试用假帧源：设了就不跑 spectacle，直接读这个文件
  fake : String?
  /// 运行时目录（/run/user/<uid>），用来确认 Wayland socket 是否已经就绪
  wl_dir : String
  /// 是否用 PipeWire 取帧（true 时不再起 spectacle）；连续失败会自动回落
  mut pw : Bool
  /// PipeWire 连续失败次数，到阈值就回落 spectacle
  mut pw_fails : Int32
  /// PipeWire 抓帧句柄
  pw_stream : @pipewire.PipeWire
  /// 当前实际使用的取帧来源："pipewire" / "spectacle" / "fake"
  mut source : String
  /// 访问控制的描述，给 /health 用
  mut access_note : String
  /// 最近一次请求的时间戳（毫秒），泵据此决定抓多勤
  mut last_req : Int64
  mut frame : Frame?
  mut cap_ms : Int64
  mut count : Int32
  mut fails : Int32
  mut err : String
  mut seq : Int32
}

///|
pub fn Store::new(
  shot~ : String,
  magick~ : String? = None,
  fake~ : String? = None,
  wl_dir~ : String = "/run/user/1000",
  pw~ : Bool = false,
) -> Store {
  {
    shot,
    lock: @async.Mutex(),
    magick,
    fake,
    wl_dir,
    pw,
    pw_fails: 0,
    pw_stream: @pipewire.PipeWire::new(app_name="screenstream-mb"),
    access_note: "不限",
    source: if pw {
      "pipewire"
    } else if fake is Some(_) {
      "fake"
    } else {
      "spectacle"
    },
    last_req: 0L,
    frame: None,
    cap_ms: 0L,
    count: 0,
    fails: 0,
    err: "",
    seq: 0,
  }
}

///|
fn Store::fresh(self : Store, max_age_ms : Int64) -> Bool {
  match self.frame {
    Some(f) => @async.now() - f.ts <= max_age_ms
    None => false
  }
}

///|
/// 保证有一帧不旧于 max_age_ms 的画面
pub async fn Store::ensure(self : Store, max_age_ms : Int64) -> Unit {
  if self.fresh(max_age_ms) {
    return
  }
  self.lock.acquire()
  defer self.lock.release()
  // 抢到锁之后再判一次，把并发请求合并成一次采集
  if self.fresh(max_age_ms) {
    return
  }
  self.capture()
}

///|

///|
/// 桌面还没起来时 Wayland socket 不存在，这时硬拉 spectacle 会被 Qt 直接 abort
/// （开机时就会看到崩溃框和 coredump）。先确认 socket 在，再决定要不要抓。
async fn wayland_ready(dir : String) -> Bool {
  for name in ["wayland-1", "wayland-0", "wayland-2", "wayland-3"] {
    if @fs.exists("\{dir}/\{name}") {
      return true
    }
  }
  false
}

///|
async fn Store::capture(self : Store) -> Unit {
  let t0 = @async.now()
  if self.pw {
    self.capture_pipewire(t0)
    return
  }
  if self.fake is None && !wayland_ready(self.wl_dir) {
    self.record_fail("Wayland socket 还没就绪，跳过这次抓帧")
    return
  }
  // 假帧源：测试时绕开 spectacle，直接从固定文件读一帧
  if self.fake is Some(path) {
    let data = try {
      let f = @fs.open(path, mode=ReadOnly)
      let bytes = f.read_all().binary()
      f.close()
      bytes
    } catch {
      err => {
        self.record_fail("读假帧失败: \{err}")
        return
      }
    }
    self.record_ok(data, @async.now() - t0)
    return
  }
  // spectacle 是单实例的：别的抓帧客户端占着锁时它会一直等。
  // 没有超时就会永久卡住并一直握着采集锁，所以用 timeout 兜住。
  let code = @process.run("/usr/bin/timeout", [
    "3",
    "/usr/bin/spectacle",
    "-f",
    "-b",
    "-n",
    "-o",
    self.shot,
  ]) catch {
    err => {
      self.record_fail("spectacle 调用失败: \{err}")
      return
    }
  }
  if code == 124 {
    self.record_fail(
      "spectacle 超过 8 秒未完成（多半被别的抓帧进程占着），已中止",
    )
    return
  }
  if code != 0 {
    self.record_fail("spectacle 退出码 \{code}")
    return
  }
  let data = try {
    let file = @fs.open(self.shot, mode=ReadOnly)
    let bytes = file.read_all().binary()
    file.close()
    bytes
  } catch {
    err => {
      self.pw_failed("读帧文件失败: \{err}")
      return
    }
  }
  self.record_ok(data, @async.now() - t0)
}

///|
pub fn Store::bytes(self : Store) -> Bytes? {
  match self.frame {
    Some(f) => Some(f.bytes)
    None => None
  }
}

///|
pub fn Store::age_ms(self : Store) -> Int64 {
  match self.frame {
    Some(f) => @async.now() - f.ts
    None => -1L
  }
}

///|
pub fn Store::cap_ms(self : Store) -> Int64 {
  self.cap_ms
}

///|
pub fn Store::count(self : Store) -> Int32 {
  self.count
}

///|
pub fn Store::fails(self : Store) -> Int32 {
  self.fails
}

///|
pub fn Store::err(self : Store) -> String {
  self.err
}

///|
pub fn Store::shot(self : Store) -> String {
  self.shot
}

///|
pub fn Store::next_tmp(self : Store, ext : String) -> String {
  self.seq += 1
  "/tmp/screenstream-mb-\{self.seq}.\{ext}"
}

///|
pub fn Store::magick(self : Store) -> String? {
  self.magick
}

///|
pub fn Store::has_magick(self : Store) -> Bool {
  match self.magick {
    Some(_) => true
    None => false
  }
}

///|
/// 采集成功记一笔。单独抽出来，采集本身要真跑 spectacle，这层逻辑可以单测。
fn Store::record_ok(self : Store, bytes : Bytes, cap_ms : Int64) -> Unit {
  self.cap_ms = cap_ms
  self.count += 1
  self.err = ""
  self.frame = Some({ bytes, ts: @async.now(), })
}

///|
/// 采集失败记一笔，保留失败原因。
fn Store::record_fail(self : Store, msg : String) -> Unit {
  self.fails += 1
  self.err = msg
}

///|
/// 有人来取图时打点，泵据此判断当前是不是有人在看屏幕。
pub fn Store::mark_request(self : Store) -> Unit {
  self.last_req = @async.now()
}

///|
/// 距离最近一次取图过去了多久（毫秒）。泵用它决定抓帧频率。
pub fn Store::idle_ms(self : Store) -> Int64 {
  if self.last_req == 0L {
    return 1L << 40
  }
  @async.now() - self.last_req
}

///|
/// 用 PipeWire 的常驻流取帧：把最新原始帧落盘，再让 magick 转成 JPEG。

///|
/// PipeWire 取帧失败：累计到 3 次就切回 spectacle，避免一直报错。
fn Store::pw_failed(self : Store, why : String) -> Unit {
  self.pw_fails = self.pw_fails + 1
  if self.pw_fails >= 3 {
    self.pw = false
    self.source = "spectacle"
    eprintln(
      "PipeWire 连续失败 \{self.pw_fails} 次，回落到 spectacle: \{why}",
    )
  }
  self.record_fail(why)
}

///|
async fn Store::capture_pipewire(self : Store, t0 : Int64) -> Unit {
  let (w, h) = self.pw_stream.size()
  if w <= 0 || h <= 0 {
    self.pw_failed("PipeWire 还没协商出画面格式")
    return
  }
  let raw = "\{self.shot}.bgra"
  if self.pw_stream.save_frame(raw) <= 0 {
    self.pw_failed("PipeWire 还没有可用帧")
    return
  }
  let size = "\{w}x\{h}"
  let code = @process.run("/usr/bin/magick", [
    "-size",
    size,
    "-depth",
    "8",
    "bgra:" + raw,
    "-quality",
    "82",
    self.shot,
  ]) catch {
    err => {
      self.pw_failed("magick 转码失败: \{err}")
      return
    }
  }
  if code != 0 {
    self.pw_failed("magick 退出码 \{code}")
    return
  }
  let data = try {
    let f = @fs.open(self.shot, mode=ReadOnly)
    let b = f.read_all().binary()
    f.close()
    b
  } catch {
    err => {
      self.pw_failed("读帧文件失败: \{err}")
      return
    }
  }
  self.record_ok(data, @async.now() - t0)
}

///|
/// 记录当前实际使用的取帧来源，供 /health 展示。
pub fn Store::set_source(self : Store, name : String) -> Unit {
  self.source = name
}

///|
pub fn Store::source(self : Store) -> String {
  self.source
}

///|
/// portal 拿到 node 之后切到 PipeWire 取帧。
pub fn Store::enable_pipewire(self : Store, node : Int32) -> Bool {
  if self.pw_stream.connect(node) != 0 {
    eprintln("PipeWire 启动失败，继续用 spectacle")
    return false
  }
  self.pw = true
  self.pw_fails = 0
  self.source = "pipewire"
  eprintln("已切到 PipeWire 取帧，node=\{node}")
  true
}

///|
pub fn Store::pipewire_on(self : Store) -> Bool {
  self.pw
}

///|
/// 记录访问控制策略，供 /health 展示。
pub fn Store::set_access_note(self : Store, note : String) -> Unit {
  self.access_note = note
}

///|
pub fn Store::access_note(self : Store) -> String {
  self.access_note
}
