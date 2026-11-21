///|
/// MoonBit 字符串没有结尾 NUL，传给 C 之前补一个。
fn cstr(s : String) -> Bytes {
  let b = @utf8.encode(s)
  let n = b.length()
  Bytes::makei(n + 1, fn(i) { if i < n { b[i] } else { 0 } })
}

///|
#borrow(app)
extern "c" fn c_start(node_id : Int32, app : Bytes) -> Int32 = "moonbit_pw_shim_start"

///|
extern "c" fn c_stop() -> Int32 = "moonbit_pw_shim_stop"

///|
extern "c" fn c_width() -> Int32 = "moonbit_pw_shim_width"

///|
extern "c" fn c_height() -> Int32 = "moonbit_pw_shim_height"

///|
extern "c" fn c_seq() -> Int64 = "moonbit_pw_shim_seq"

///|
#borrow(dst)
extern "c" fn c_latest(dst : Bytes, cap : Int32) -> Int32 = "moonbit_pw_shim_latest"

///|
#borrow(path)
extern "c" fn c_save_raw(path : Bytes) -> Int32 = "moonbit_pw_save_raw"

///|
/// 写一帧，返回写入字节数。
///
/// 尺寸不通过出参回传 —— MoonBit 的 Bytes 是它自己管理的内存，
/// C 侧直接写会踩坏（实测 SEGV）。改由 C 的静态变量暂存，
/// 紧接着用下面两个 getter 取走。抓帧是串行的，没有竞态。
#borrow(path)
extern "c" fn c_save_consistent(path : Bytes) -> Int32 = "moonbit_pw_save_raw_consistent"

///|
extern "c" fn c_saved_w() -> Int32 = "moonbit_pw_saved_w"

///|
extern "c" fn c_saved_h() -> Int32 = "moonbit_pw_saved_h"

///|
extern "c" fn c_kill(pid : Int32) -> Int32 = "moonbit_pw_kill"

///|
/// 一条 PipeWire 抓帧流的句柄。
///
/// 照官方 http 的写法分两步：构造只是记住配置，`start` 才真正连流。
/// 连流本身不阻塞（底层在 C 线程里跑 main loop），阻塞的是 portal 那一侧。
///
/// 一个进程目前只能有一条流。
pub struct PipeWire {
  app_name : String
  mut started : Bool
}

///|
/// 构造句柄，不做任何 I/O。
pub fn PipeWire::new(app_name~ : String = "moonpipewire") -> PipeWire {
  { app_name, started: false, }
}

///|
/// 连到指定 node 开始抓帧。返回 0 表示成功；立刻返回，不等第一帧。
///
/// `app_name` 只决定这条流在 pw-dump / pavucontrol 里怎么显示，不影响权限。
pub fn PipeWire::connect(self : PipeWire, node_id : Int32) -> Int32 {
  let rc = c_start(node_id, cstr(self.app_name))
  if rc == 0 {
    self.started = true
  }
  rc
}

///|
/// 断开并回收底层线程。没启动时调用是空操作。
pub fn PipeWire::disconnect(self : PipeWire) -> Unit {
  if self.started {
    c_stop() |> ignore
    self.started = false
  }
}

///|
pub fn PipeWire::started(self : PipeWire) -> Bool {
  self.started
}

///|
/// 当前协商出来的尺寸；还没协商好时返回 0。
pub fn PipeWire::size(self : PipeWire) -> (Int32, Int32) {
  let _ = self
  (c_width(), c_height())
}

///|
/// 最新帧序号，用来判断有没有新帧。
pub fn PipeWire::seq(self : PipeWire) -> Int64 {
  let _ = self
  c_seq()
}

///|
/// 把最新帧拷进调用方的缓冲区，返回写入字节数；还没有帧时返回 0。
///
/// 原始像素是 BGRx，每行 `宽 * 4` 字节，所以缓冲区大小至少要 `宽 * 高 * 4`。
pub fn PipeWire::copy_frame(self : PipeWire, dst : Bytes) -> Int32 {
  let _ = self
  c_latest(dst, dst.length())
}

///|
/// 把最新帧写成原始 BGRx 文件（每行 width*4 字节），返回字节数。
pub fn PipeWire::save_frame(self : PipeWire, path : String) -> Int32 {
  let _ = self
  c_save_raw(cstr(path))
}

///|
/// 一次调用同时拿到这一帧的像素和尺寸，返回写入字节数（失败 -1）。
///
/// 用它替代「先 size() 再 save_frame()」：那两步是两次独立调用，
/// 中间可以换帧甚至换分辨率，拿到的尺寸和像素可能不是同一帧 ——
/// 解码按错的尺寸走就是花屏。
///
/// 实现上开一块 2 个 Int32 的缓冲当出参，C 侧在同一把锁里填。
pub fn PipeWire::save_frame_consistent(
  self : PipeWire,
  path : String,
) -> (Int32, Int32, Int32) {
  let _ = self
  let n = c_save_consistent(cstr(path))
  // 这两个 getter 必须在同一次抓帧里紧跟着调用：
  // C 侧只保留「最后一次写出的那一帧」的尺寸。
  (n, c_saved_w(), c_saved_h())
}

///|
/// 结束一个残留的 portal 助手进程。
pub fn pipewire_kill(pid : Int32) -> Int32 {
  c_kill(pid)
}
