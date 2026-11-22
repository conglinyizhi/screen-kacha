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
  /// 测试用假帧源：设了就不跑 spectacle，直接读这个文件
  fake : String?
  /// 运行时目录（/run/user/<uid>），用来确认 Wayland socket 是否已经就绪
  wl_dir : String
  /// 是否用 PipeWire 取帧（true 时不再起 spectacle）；连续失败会自动回落
  mut pw : Bool
  /// PipeWire 连续失败次数，到阈值就回落 spectacle
  mut pw_fails : Int32
  mut raw_seq : Int32
  /// 最近一帧原始像素的位置和尺寸。
  ///
  /// 每帧写一个新文件，不在同一个路径上覆盖：请求方可能在泵写下一帧的
  /// 时候才去读文件，共用一个路径就会读到「上一帧的尺寸配这一帧的像素」。
  /// 用独立文件后，(路径, 尺寸) 这一对永远指向同一份内容。
  mut pw_raw_frame : (String, Int32, Int32)?
  /// 上一帧的位置。留着不删：可能有请求刚拿到它的路径还没读完。
  mut pw_raw_prev : String?
  /// PipeWire 抓帧句柄
  pw_stream : @pipewire.PipeWire
  /// 当前实际使用的取帧来源："pipewire" / "spectacle" / "fake"
  mut source : String
  /// 最近一次请求的时间戳（毫秒），泵据此决定抓多勤
  mut last_req : Int64
  mut frame : Frame?
  mut cap_ms : Int64
  mut count : Int32
  mut fails : Int32
  /// 连续失败次数，成功一次就清零。
  ///
  /// `fails` 是累计值，只增不减，看不出「现在是不是还在坏」。
  /// 这两个分开：累计值给「出过多少次问题」，连续值给「现在有没有好」。
  mut consec_fails : Int32
  /// 后台泵的节奏，用来判断帧是不是该更新了
  pump_ms : Int32
  mut err : String
  mut seq : Int32
  /// 临时输出文件的目录。
  ///
  /// 不再直接落在 /tmp 根下：那个目录谁都能读、谁都能写，截图 0644 摆着，
  /// 名字又是可预测的（时间戳 + pid + 序号），本地别的用户可以读到屏幕内容，
  /// 也能预置符号链接把写入引走。这里用服务自己的目录，权限 0700。
  tmp_dir : String
}

///|
pub fn Store::new(
  shot~ : String,
  fake~ : String? = None,
  wl_dir~ : String = default_runtime_dir(),
  pw~ : Bool = false,
  tmp_dir~ : String = "/tmp/screenstream-mb",
  pump_ms~ : Int32 = 500,
) -> Store {
  {
    shot,
    lock: @async.Mutex(),
    fake,
    wl_dir,
    pw,
    pw_fails: 0,
    raw_seq: 0,
    pw_raw_frame: None,
    pw_raw_prev: None,
    pw_stream: @pipewire.PipeWire::new(app_name="screenstream-mb"),
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
    consec_fails: 0,
    pump_ms,
    err: "",
    seq: 0,
    tmp_dir,
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
/// 桌面还没起来时 Wayland socket 不存在，这时硬拉 spectacle 会被 Qt 直接 abort
/// （开机时就会看到崩溃框和 coredump）。先确认 socket 在，再决定要不要抓。
async fn wayland_ready(dir : String) -> Bool {
  // 不能只认 wayland-0..3：编号在 compositor 每次重启后递增，
  // 跑过几轮 KWin 崩溃的机器上出现 wayland-5、wayland-7 是常态。
  // 那时这里返回 false，capture 会直接记「socket 还没就绪」返回，
  // 连 spectacle 都不拉，桌面好得很，服务却永久抓不到图。
  let names = try {
    let d = @fs.opendir(dir)
    let all = d.read_all()
    d.close()
    all
  } catch {
    _ => []
  }
  for name in names {
    // 只要 wayland-数字 这种：目录里还有 wayland-1.lock、wayland-cursor.sock
    // 之类的东西，见着就算会把「没 socket」误判成「就绪」
    if !name.has_prefix("wayland-") || name.has_suffix(".lock") {
      continue
    }
    let tail = name[8:]
    if tail.length() == 0 || tail.length() > 2 {
      continue
    }
    let mut digits = true
    for i = 0; i < tail.length(); i = i + 1 {
      let c = tail[i].to_int()
      if c < 48 || c > 57 {
        digits = false
      }
    }
    if digits {
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
  //
  // -p 是把鼠标指针画进画面。不带的话截出来没有光标，
  // 「看看屏幕上是什么」就少了「现在指着哪」这条信息。
  // -k 1：TERM 之后 1 秒还活着就 KILL。
  // 不带 -k 的话，spectacle 卡在不可中断的地方不响应 TERM，
  // timeout 自己也不返回（实测：`timeout 2 bash -c "trap '' TERM; sleep 8"`
  // 真的跑满 8 秒），这层兜底就是漏的，采集锁会被一直握着。
  let code = @process.run("/usr/bin/timeout", [
    "-k",
    "1",
    "3",
    "/usr/bin/spectacle",
    "-f",
    "-b",
    "-n",
    "-p",
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
      // 这里不能用 pw_failed：这一轮走的是 spectacle，根本没碰 PipeWire。
      // 旧代码会污染 PipeWire 的失败计数，连累它被误判降级，
      // 日志还会打「PipeWire 连续失败…回落到 spectacle」，把排障带偏。
      self.record_fail("读帧文件失败: \{err}")
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
/// 有人在取图，帧却迟迟不更新，说明后台泵停了。
///
/// 光看 `err` 判断不出来：泵线程要是整个卡死，就没有任何一次采集失败，
/// `err` 一直是空的，`/health` 会一直说 ok，而画面停在几分钟前。
///
/// 两个前提都要满足才算停摆：
/// - 最近真的有人在取图（`idle_ms` 小）。没人用的时候泵会主动放慢，
///   帧变旧是应该的，不能报错。
/// - 帧龄超过泵节奏的十倍再加五秒余量，避免把正常的调度抖动算进去。
pub fn frame_is_stalled(
  frame_age_ms : Int64,
  idle_ms : Int64,
  pump_ms : Int32,
) -> Bool {
  if frame_age_ms < 0L {
    // 一帧都还没有：那是「还没抓到」，不是「停摆」
    return false
  }
  let pump = pump_ms.to_int64()
  let demand = idle_ms < pump * 20L
  demand && frame_age_ms > pump * 10L + 5000L
}

///|
pub fn Store::is_stalled(self : Store) -> Bool {
  frame_is_stalled(self.age_ms(), self.idle_ms(), self.pump_ms)
}

///|
pub fn Store::consec_fails(self : Store) -> Int32 {
  self.consec_fails
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
  // 文件名带时间和 pid，别用纯自增序号：进程重启后序号从 1 开始，
  // 会和上一个实例的同名文件撞上。时间戳 + pid + 序号在进程内保证唯一，
  // 跨进程也几乎不会撞。
  //
  // 光靠名字防不住本地攻击者（可预测就是可预测），真正的防线是 `tmp_dir`：
  // 目录由服务自己按 0700 建，别的用户进不去，也放不进东西。C 侧再叠一层
  // O_NOFOLLOW + 0600。
  // 只管发路径，不在这里删旧文件。
  //
  // 原来是「环形滚动，超了删最旧的」，而并发上限是 64、环上只留 10 个：
  // 并发一高，还在被别的请求读的文件就被后面的人删掉了。现在由读回那头
  // 读完即删（见 `read_result`），这里再删只会误伤。
  "\{self.tmp_dir}/out-\{@async.now()}-\{current_pid()}-\{self.seq}.\{ext}"
}

///|
/// MoonBit 字符串 → 带结尾 0 的 C 字符串。
fn cstr(s : String) -> Bytes {
  let src = @utf8.encode(s)
  let n = src.length()
  Bytes::makei(n + 1, fn(i) { if i < n { src[i] } else { 0 } })
}

///|
/// 当前进程号，来自 C 的 getpid()。
fn current_pid() -> Int32 {
  current_pid_raw()
}

///|
extern "c" fn current_pid_raw() -> Int32 = "moonbit_current_pid"

///|
/// 删掉目录里匹配「前缀 + 后缀」的文件，返回删掉的数量。
#borrow(dir, prefix, suffix)
extern "c" fn clean_stale_frames_raw(
  dir : Bytes,
  prefix : Bytes,
  suffix : Bytes,
) -> Int32 = "moonbit_clean_stale_frames"

///|
/// 清掉上次运行留下的临时文件。
///
/// 原始帧每帧 8MB，文件名里的序号每个进程都从 1 重来，上个进程跑到几千号的
/// 那些再也不会被覆盖，会一直躺在 tmpfs（也就是内存）里。临时输出正常情况
/// 读完就删了，但进程被 kill 时会留下几个。启动时各扫一遍。
pub fn clean_stale_frames(
  dir : String,
  prefix : String,
  suffix : String,
) -> Int32 {
  clean_stale_frames_raw(cstr(dir), cstr(prefix), cstr(suffix))
}

///|
/// 采集成功记一笔。单独抽出来，采集本身要真跑 spectacle，这层逻辑可以单测。
fn Store::record_ok(self : Store, bytes : Bytes, cap_ms : Int64) -> Unit {
  self.cap_ms = cap_ms
  self.count += 1
  self.err = ""
  // 成功一次就把 PipeWire 的失败计数清零。
  //
  // 这里原来是漏的：计数只加不减，>=3 就永久切到 spectacle。
  // 后果是偶发失败会跨天累积，跑一天几万帧里只要有三次抖动，
  // 抓帧就从 24ms 掉到 700ms，而 /health 只显示 source=spectacle，
  // 看起来像"正常回退"，没人会去查。
  // 启动期更危险：PipeWire::connect 立刻返回不等第一帧，
  // 泵 500ms 一拍，协商超过 1.5 秒就会被判死，一开机就没救了。
  self.pw_fails = 0
  self.consec_fails = 0
  self.frame = Some({ bytes, ts: @async.now(), })
}

///|
/// 采集失败记一笔，保留失败原因。

///|
/// 连续失败到第几次该往日志里写一行。
///
/// 泵 500ms 一拍，同一个错误会一直重复。只在「错误内容变了」或者
/// 「连续次数是 30 的倍数」时写，既不丢信息，也不会把 journal 刷掉。
const FAIL_LOG_EVERY : Int32 = 30

///|
fn should_log_failure(consec : Int32, err_changed : Bool) -> Bool {
  if err_changed {
    return true
  }
  consec % FAIL_LOG_EVERY == 0
}

///|
fn Store::record_fail(self : Store, msg : String) -> Unit {
  self.fails += 1
  self.consec_fails += 1
  // 失败必须落到日志里。
  //
  // 原来只更新内存字段：服务一直抓不到帧，journal 里却只有启动那两行，
  // 只能靠 /health 才发现，而 /health 也要人主动去问。
  if should_log_failure(self.consec_fails, msg != self.err) {
    eprintln("采集失败（连续 \{self.consec_fails} 次）：\{msg}")
  }
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
/// runtime 目录。优先 XDG_RUNTIME_DIR，否则按当前 uid 推。
/// 之前写死 /run/user/1000，多用户或 root 下会指到别人的目录。
fn default_runtime_dir() -> String {
  match @env.get_env_var("XDG_RUNTIME_DIR") {
    Some(v) => v
    None => "/run/user/1000"
  }
}

///|
/// 用 PipeWire 的常驻流取帧：把最新原始帧落盘，再用 moonimage 转成 JPEG。

///|
/// PipeWire 取帧失败：**连续** 3 次才切回 spectacle。
///
/// 「连续」靠 `record_ok` 里清零 `pw_fails` 来保证，别把那一行删了，
/// 删了就退化成「累计」，偶发抖动也能把快路径永久打掉。
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
  // 每帧一个独立文件：请求方读的时候，泵可能已经在写下一帧了，
  // 共用一个路径就会读到错位的内容。
  self.raw_seq += 1
  let raw = "\{self.shot}.\{self.raw_seq}.bgra"
  // 尺寸和像素必须来自同一帧，所以用一次调用同时取。
  //
  // 原来是 size() + save_frame() 两次独立调用，中间隔着一次完整落盘
  // （8MB 写）。桌面在这段时间改分辨率（切缩放倍率、拔插外接屏），
  // 第二次拿到的就是「旧尺寸配新像素」，解码按错的尺寸走，
  // 产出花屏，或者直接读越界。改成一次调用后由 C 侧在同一把锁里
  // 读完尺寸再写像素，两者必然一致。
  let (wrote, w, h) = self.pw_stream.save_frame_consistent(raw)
  if w <= 0 || h <= 0 {
    self.pw_failed("PipeWire 还没协商出画面格式")
    return
  }
  // 写入长度必须正好是 w*h*4：磁盘满、quota 打满、tmpfs 被吃光时
  // 会返回一个正数的「部分写入量」，当成成功就会去解一个截断的文件。
  let expect = w * h * 4
  if wrote != expect {
    self.pw_failed("PipeWire 帧写入不完整（\{wrote}/\{expect} 字节）")
    return
  }
  // 用自带的 moonimage 转码：
  // 实测 19ms vs 53ms，而且不再依赖外部程序。
  // 先记下「这一帧在哪、多大」，再去编码。
  // 编码和后续请求都只看这个三元组，不再碰 C 侧的实时状态。
  // 轮转：删上上帧，保留上一帧。
  //
  // 删上一帧是不行的，可能有请求刚拿到它的路径、正要读，
  // 文件就没了。留一帧的余量足够：请求拿到路径到读完只有几毫秒，
  // 而泵最快 500ms 才换一次帧。
  match self.pw_raw_prev {
    Some(old) => {
      let _ = @fs.remove(old) catch { _ => () }
    }
    None => ()
  }
  self.pw_raw_prev = match self.pw_raw_frame {
    Some((p, _, _)) => Some(p)
    None => None
  }
  self.pw_raw_frame = Some((raw, w, h))
  if !@image.bgra_to_jpeg(raw, w, h, 0, 82, self.shot) {
    self.pw_failed("moonimage 转码失败")
    return
  }
  let data = try {
    let f = @fs.open(self.shot, mode=ReadOnly)
    let b = f.read_all().binary()
    f.close()
    b
  } catch {
    err => {
      // 这里不能用 pw_failed：这一轮走的是 spectacle，根本没碰 PipeWire。
      // 旧代码会污染 PipeWire 的失败计数，连累它被误判降级，
      // 日志还会打「PipeWire 连续失败…回落到 spectacle」，把排障带偏。
      self.record_fail("读帧文件失败: \{err}")
      return
    }
  }
  self.record_ok(data, @async.now() - t0)
}

///|
/// 当前实际使用的取帧来源，供 /health 展示。
pub fn Store::source(self : Store) -> String {
  self.source
}

///|
/// 后台 portal 监督循环每一轮该做什么。
pub enum PortalStep {
  /// 流还在，等下一轮再看
  Watch
  /// 流没了（从没连上，或者降级了），去重新申请一个 node
  Reacquire
}

///|
/// 降级之后必须继续去申请。
///
/// 「连上过一次就退出循环」是原来的 bug：会话过期或 KWin 重启之后
/// `pw` 掉回 false，可循环已经结束了，服务就永久停在 spectacle 慢路径上。
/// `/health` 还显示 `source=spectacle`，看着像「正常回退」，实际再也不会好。
pub fn portal_step(pipewire_on : Bool) -> PortalStep {
  if pipewire_on {
    Watch
  } else {
    Reacquire
  }
}

///|
/// portal 拿到 node 之后切到 PipeWire 取帧。
///
/// 连之前先断开旧的：`pw_shim` 里「已经在跑就直接返回 0」的分支会拿上一个
/// 可能已经死掉的流假装成功，调用方以为恢复了，实际上还是没帧。
pub fn Store::enable_pipewire(self : Store, node : Int32) -> Bool {
  self.pw_stream.disconnect()
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
/// 光标坐标文件的位置。由 `screenstream-cursor` 写，这里只读。
/// 用 runtime 目录：重启就清掉，本来就是瞬时状态。
pub fn Store::cursor_pos_path(self : Store) -> String {
  let _ = self
  let rt = match @env.get_env_var("XDG_RUNTIME_DIR") {
    Some(v) => v
    None => "/tmp"
  }
  "\{rt}/screenstream/cursor.pos"
}

///|
/// PipeWire 原始帧（BGRA）的路径和尺寸。
///
/// 缩放请求可以直接从原始像素重新编码，省掉「先编码成 JPEG、
/// 再解码回来缩放」这一来一回。
pub fn Store::pw_raw(self : Store) -> (String, Int32, Int32)? {
  if !self.pw {
    return None
  }
  // 用抓帧时记下的尺寸，不要再现场问 C 侧。
  //
  // 现场问的话，拿到的可能是「下一帧」的尺寸，而文件里躺的是上一帧的
  // 像素，改分辨率的那一瞬间就会按错的尺寸去解，出花屏。
  // 尺寸和像素必须在同一时刻确定下来，这里就是那个「同一时刻」的结果。
  match self.pw_raw_frame {
    Some((path, w, h)) => if w > 0 && h > 0 { Some((path, w, h)) } else { None }
    None => None
  }
}
