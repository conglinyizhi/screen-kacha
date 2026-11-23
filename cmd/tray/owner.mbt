///|
/// 托盘的心跳记录（`tray.owner`）。
///
/// 托盘崩掉之后，它留在系统里的东西不会自己消失：KWin 里的脚本还挂着，
/// 每 200ms 往一个没人接的 D-Bus 名字上打坐标；cursor helper 还占着那个名字。
/// 正常的退出口（菜单、SIGTERM）托盘自己收得干净，崩溃和 SIGKILL 收不了 ——
/// 所以留一份记录给服务，让它能替我们收：pid、脚本名、helper 的 pid。
///
/// 每 5 秒跟着 `run_with_tick` 整份重写一次，服务按最后写的时间判活。

///|
/// cursor helper 的 pid；没在跑就是 0。
///
/// 匹配整条命令行而不是进程名：`screen-kacha-cursor` 是 18 个字符，
/// Linux 的 comm 只留前 15 个，`pgrep -x` 永远匹配不到（详见 cursor_kwin.mbt）。
/// 模式里用 `[/]` 把斜杠包起来：正在执行这条命令的那个 shell，命令行里是
/// 字面的 `[/]`，不含连续的 `/screen-kacha-cursor`，不会匹配到自己。
fn cursor_helper_pid() -> Int32 {
  let out = capture("pgrep -f '[/]screen-kacha-cursor' 2>/dev/null", 256)
  for line in out.split("\n") {
    let p = @util.parse_int(line.trim(), 0)
    if p > 0 {
      return p
    }
  }
  0
}

///|
/// 服务写回来的连续失败次数。读不到就是 0。
///
/// 托盘只抄这个值、自己不数：真正的计数在服务那边（它才是判定活死的一方）。
/// 抄进来是为了让 `tray.owner` 单独 cat 出来就能看懂当前状态。
fn read_service_miss(dir : String) -> Int32 {
  match capture_whole("\{dir}/tray.miss") {
    Some(t) => {
      let n = @util.parse_int(t.trim(), 0)
      if n > 0 {
        n
      } else {
        0
      }
    }
    None => 0
  }
}

///|
/// 写一次心跳。在 tick 里每 5 秒调一次。
///
/// 写的是「该由我负责的脚本名」，不是「KWin 里真的加载了哪一个」：
/// 名字没加载过时，服务那边卸一次只是空调用（gdbus 返回 false，不报错）；
/// 反过来漏写的话，脚本就永远留在 KWin 里打没人接的 D-Bus。两边代价差得远。
fn write_tray_owner() -> Unit {
  let dir = match @util.state_dir() {
    Some(d) => d
    None => return
  }
  let record = @util.TrayOwner::new(
    current_pid(),
    own_script_name(),
    cursor_helper_pid(),
    @util.now_ms(),
    read_service_miss(dir),
  )
  // 原子写：服务随时可能在读，读到半截会算出一个假的「过期」，
  // 然后就朝着一个活得好好的托盘数失败次数。
  let _ = @util.write_atomic_text("\{dir}/tray.owner", record.render())
}

///|
/// 干净退出时把记录删掉。
///
/// 不删的话：托盘正常退出之后服务还看得见一条停住的心跳，十几秒后
/// 郑重其事地「清理」一个早就收干净的托盘，日志里全是假警报。
fn remove_tray_owner() -> Unit {
  match @util.state_dir() {
    Some(d) => {
      let _ = remove_file("\{d}/tray.owner")
    }
    None => ()
  }
}
