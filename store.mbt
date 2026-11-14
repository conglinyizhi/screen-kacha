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
) -> Store {
  {
    shot,
    lock: @async.Mutex(),
    magick,
    fake,
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
async fn Store::capture(self : Store) -> Unit {
  let t0 = @async.now()
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
