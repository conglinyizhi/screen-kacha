///|
/// PipeWire 抓帧 shim 的 MoonBit 侧绑定。
extern "c" fn pw_start(node_id : Int32) -> Int32 = "moonbit_pw_shim_start"

///|
extern "c" fn pw_width() -> Int32 = "moonbit_pw_shim_width"

///|
extern "c" fn pw_height() -> Int32 = "moonbit_pw_shim_height"

///|
extern "c" fn pw_seq() -> Int64 = "moonbit_pw_shim_seq"

///|
extern "c" fn pw_save_raw() -> Int32 = "moonbit_pw_save_raw"

///|
/// 启动抓帧流。返回 0 表示成功。
pub fn pipewire_start(node_id : Int32) -> Int32 {
  pw_start(node_id)
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
/// 把最新帧写成原始 BGRx 文件，返回字节数。
pub fn pipewire_save_raw() -> Int32 {
  pw_save_raw()
}

///|
extern "c" fn pw_kill(pid : Int32) -> Int32 = "moonbit_pw_kill"

///|
/// 结束一个残留的 portal 助手进程。
pub fn pipewire_kill(pid : Int32) -> Int32 {
  pw_kill(pid)
}
