///|
/// MoonBit 字符串没有结尾 NUL，传给 C 之前补一个。
fn cstr(s : String) -> Bytes {
  let b = @utf8.encode(s)
  let n = b.length()
  Bytes::makei(n + 1, fn(i) { if i < n { b[i] } else { 0 } })
}

///|
#borrow(app)
extern "c" fn pw_start(node_id : Int32, app : Bytes) -> Int32 = "moonbit_pw_shim_start"

///|
extern "c" fn pw_width() -> Int32 = "moonbit_pw_shim_width"

///|
extern "c" fn pw_height() -> Int32 = "moonbit_pw_shim_height"

///|
extern "c" fn pw_seq() -> Int64 = "moonbit_pw_shim_seq"

///|
#borrow(path)
extern "c" fn pw_save_raw(path : Bytes) -> Int32 = "moonbit_pw_save_raw"

///|
extern "c" fn pw_kill(pid : Int32) -> Int32 = "moonbit_pw_kill"

///|
/// 启动抓帧流。返回 0 表示成功。
///
/// `app_name` 只决定这条流在 pw-dump / pavucontrol 里怎么显示，不影响任何权限。
pub fn pipewire_start(
  node_id : Int32,
  app_name~ : String = "moonpipewire",
) -> Int32 {
  pw_start(node_id, cstr(app_name))
}

///|
/// 当前协商出来的尺寸；还没协商好时返回 0。
pub fn pipewire_size() -> (Int32, Int32) {
  (pw_width(), pw_height())
}

///|
/// 最新帧序号，用来判断有没有新帧。
pub fn pipewire_seq() -> Int64 {
  pw_seq()
}

///|
/// 把最新帧写成原始 BGRx 文件（每行 width*4 字节），返回字节数。
pub fn pipewire_save_raw(path : String) -> Int32 {
  pw_save_raw(cstr(path))
}

///|
/// 结束一个残留的 portal 助手进程。
pub fn pipewire_kill(pid : Int32) -> Int32 {
  pw_kill(pid)
}
