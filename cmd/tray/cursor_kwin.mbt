///|
/// 托盘侧：把 KWin 脚本动态挂上去 / 摘下来。
///
/// 脚本本身写在 runtime 目录（tmpfs），不落 `~/.local/share/kwin/scripts`：
/// 重启就没了，也不用在系统设置里翻开关。用完 `stop` + 删文件。

///|
/// KWin 脚本的内容。QTimer 每 200ms 把 cursorPos 打给坐标服务。
///
/// 不能用 setInterval —— KWin 的脚本引擎不是浏览器，只有 QTimer。
/// 200ms 对「大致在哪」够用，再快也只是多耗 D-Bus。
let kwin_script_src : String = "var t = new QTimer();\n" +
  "t.timeout.connect(function () {\n" +
  "    var p = workspace.cursorPos;\n" +
  "    if (!p) return;\n" +
  "    callDBus('org.kde.screenstream', '/cursor', 'org.kde.screenstream', 'Moved', p.x, p.y);\n" +
  "});\n" +
  "t.start(200);\n"

///|
/// 脚本文件放哪。tmpfs，重启自动没。
fn kwin_script_path() -> String {
  let rt = match @env.get_env_var("XDG_RUNTIME_DIR") {
    Some(v) => v
    None => "/tmp"
  }
  "\{rt}/screenstream/cursor-kwin.js"
}

///|
/// 坐标服务在不在跑（它就是那个 D-Bus 名字的持有者）。
fn cursor_helper_alive() -> Bool {
  run_status("busctl --user status org.kde.screenstream >/dev/null 2>&1") == 0
}

///|
/// 挂上：写脚本、加载、启动。helper 没跑就先拉起来。
fn cursor_tracking_on(helper_bin : String) -> Bool {
  let path = kwin_script_path()
  // 先保证目录和文件
  if !write_file(path, kwin_script_src) {
    return false
  }
  if !cursor_helper_alive() {
    sh("(setsid '\{helper_bin}' >/dev/null 2>&1 &)")
    // 给它一点时间抢到总线名字
    sh("sleep 0.6")
  }
  let load_cmd = "gdbus call --session --dest org.kde.KWin --object-path /Scripting --method org.kde.kwin.Scripting.loadScript '\{path}' cursorprobe 2>/dev/null"
  let id = capture(load_cmd, 64)
  if id.trim() == "" {
    return false
  }
  sh(
    "gdbus call --session --dest org.kde.KWin --object-path /Scripting --method org.kde.kwin.Scripting.start >/dev/null 2>&1",
  )
  true
}

///|
/// 摘下来：停脚本、删文件、杀掉 helper、清掉坐标。
fn cursor_tracking_off() -> Unit {
  // 逐个试停 1..8 号脚本；找不存在的会失败，无害
  sh(
    "for i in 1 2 3 4 5 6 7 8; do gdbus call --session --dest org.kde.KWin --object-path /Scripting/Script$i --method org.kde.kwin.Script.stop >/dev/null 2>&1; done",
  )
  sh("rm -f '\{kwin_script_path()}'")
  sh("pkill -f screenstream-cursor 2>/dev/null")
  sh("rm -f '\{cursor_pos_path()}'")
}

///|
/// 当前坐标文件的位置（和服务端同一个约定）。
fn cursor_pos_path() -> String {
  let rt = match @env.get_env_var("XDG_RUNTIME_DIR") {
    Some(v) => v
    None => "/tmp"
  }
  "\{rt}/screenstream/cursor.pos"
}
