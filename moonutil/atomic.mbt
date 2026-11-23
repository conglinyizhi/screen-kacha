///|
/// 原子写小文件：先写同目录下的临时文件（名字带 pid 和进程内序号），
/// 再 `rename` 到目标。同文件系统内 rename 是原子的，读方只可能看到
/// 旧内容或新内容，不会看到半截。
///
/// 为什么需要它：端口文件、`portal.node`、`access.conf` 都是「一个进程写、
/// 另一个进程随时读」。原来是打开→写→关闭，读方可能读到半截——配置读到
/// 一半会让 `parse_access` 退回默认值（默认放开局域网），写方崩在中间就
/// 留下一个空文件或者半截数字。
///
/// 实现在 `atomic_write.c`：托盘是同步循环，调不了 MoonBit 的 async `@fs`，
/// 三处调用方必须共用同一份实现。
///
/// 返回 0 成功，负数是 `-errno`。
#borrow(path, data)
extern "c" fn write_atomic_raw(
  path : Bytes,
  data : Bytes,
  len : Int32,
) -> Int32 = "moonbit_util_write_atomic"

///|
/// 原子写一段字节。
pub fn write_atomic(path : String, data : Bytes) -> Int32 {
  write_atomic_raw(cstr(path), data, data.length())
}

///|
/// 原子写一段文本（按 UTF-8 编码）。配置文件、端口号这种都是文本。
pub fn write_atomic_text(path : String, text : String) -> Int32 {
  write_atomic(path, @utf8.encode(text))
}
