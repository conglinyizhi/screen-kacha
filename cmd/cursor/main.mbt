///|
/// 光标坐标中转：KWin 脚本用 callDBus 把 cursorPos 发到这里，
/// 这里落盘，主服务读文件自己画。
///
/// 为什么不并进主服务：主服务是 MoonBit async（单线程事件循环），
/// moondbus 是同步阻塞的，塞进去会把整个事件循环卡死。所以单独一个进程。
///
/// 写出去的格式是两个十进制数，空格分隔：
///
///   1146 525
///
/// 不用 JSON 是因为主服务那边只要拆两个数，引一个解析器不值当。
/// 新鲜度靠文件 mtime 判断，省得自己维护时间戳。

///|
const BUS_NAME : String = "org.kde.screen-kacha"

///|
const IFACE : String = "org.kde.screen-kacha"

///|
const OBJ_PATH : String = "/cursor"

///|
/// 多久没收到坐标就认为跟踪已经停了。tick 是 500ms，
/// 4 个 tick = 2 秒，比脚本的 200ms 间隔宽松很多，不会误判。
const STALE_TICKS : Int32 = 4

///|
#borrow(path, data)
extern "c" fn write_pos_raw(path : Bytes, data : Bytes) -> Int32 = "moonbit_cursor_write"

///|
extern "c" fn exit_now(code : Int32) -> Unit = "moonbit_cursor_exit"

///|
#borrow(path)
extern "c" fn remove_pos_raw(path : Bytes) -> Int32 = "moonbit_cursor_remove"

///|
/// 坐标文件路径。放 runtime 目录，重启就没了，本来也是瞬时状态。
fn pos_path() -> String {
  let rt = match @env.get_env_var("XDG_RUNTIME_DIR") {
    Some(v) => v
    None => "/tmp"
  }
  "\{rt}/screen-kacha/cursor.pos"
}

///|
/// D-Bus 的 int32 是小端。body 开头两个就是 x、y。
fn read_i32(b : Bytes, at : Int32) -> Int32 {
  let b0 = b[at].to_int()
  let b1 = b[at + 1].to_int()
  let b2 = b[at + 2].to_int()
  let b3 = b[at + 3].to_int()
  b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
}

///|
/// 写坐标文件。返回是否写成功。
///
/// 原来用 `let _ = ...` 把结果丢掉：写不进去就永远没有箭头，主服务那边
/// 只会看到「坐标文件不存在」，跟「没开跟踪」完全一样，没有任何线索。
fn save_pos(x : Int32, y : Int32) -> Bool {
  write_pos_raw(@util.cstr(pos_path()), @util.cstr("\{x} \{y}")) == 0
}

///|
fn main {
  let server = match @dbus.Server::connect() {
    Err(e) => {
      eprintln("连不上会话总线，错误码 \{e}")
      return
    }
    Ok(s) => s
  }
  match @dbus.Server::hello(server) {
    Err(e) => {
      eprintln("Hello 失败，错误码 \{e}")
      return
    }
    Ok(_) => ()
  }
  match @dbus.Server::request_name(server, BUS_NAME, 0) {
    Err(e) => {
      eprintln("注册 \{BUS_NAME} 失败，错误码 \{e}")
      return
    }
    Ok(_) => eprintln("光标坐标服务已就绪：\{BUS_NAME}\{OBJ_PATH}")
  }
  // 每 500ms 一次 tick。KWin 脚本是**无条件**每 200ms 发一次的
  // （不管光标动没动），所以「连着几个 tick 没收到」就等于脚本没了
  // （KWin 重启、脚本被停）。这时候把坐标文件删掉：
  // 留着会画出一个停在原地的假光标，比不画更误导。
  let seen_tick : Ref[Int32] = Ref(0)
  let tick_no : Ref[Int32] = Ref(0)
  @dbus.Server::serve_with_tick(
    server,
    fn(_s, ctx) {
      if ctx.iface == IFACE && ctx.member == "Moved" && ctx.body.length() >= 8 {
        seen_tick.val = tick_no.val
        // 写不进去就退出：托盘那边有「坐标到底流没流动」的检查，
        // 会看到失败并把跟踪状态收回去，比留一个静默失效的 helper 好
        if !save_pos(read_i32(ctx.body, 0), read_i32(ctx.body, 4)) {
          eprintln("写坐标文件失败，退出让托盘重新接管")
          exit_now(1)
        }
      }
      Some(@dbus.Reply::make(Bytes::new(0), ""))
    },
    fn(_s) {
      tick_no.val = tick_no.val + 1
      if tick_no.val - seen_tick.val > STALE_TICKS {
        let _ = remove_pos_raw(@util.cstr(pos_path()))
      }
    },
    500,
  )
}
