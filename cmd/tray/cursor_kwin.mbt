///|
/// 托盘侧：把 KWin 脚本动态挂上去 / 摘下来。
///
/// 脚本本身写在 runtime 目录（tmpfs），不落 `~/.local/share/kwin/scripts`：
/// 重启就没了，也不用在系统设置里翻开关。用完 `stop` + 删文件。

///|
/// KWin 脚本的内容。QTimer 每 200ms 把 cursorPos 打给坐标服务。
///
/// 不能用 setInterval，KWin 的脚本引擎不是浏览器，只有 QTimer。
/// 200ms 对「大致在哪」够用，再快也只是多耗 D-Bus。
let kwin_script_src : String = "var t = new QTimer();\n" +
  "t.timeout.connect(function () {\n" +
  "    var p = workspace.cursorPos;\n" +
  "    if (!p) return;\n" +
  "    callDBus('io.github.conglinyizhi.screenkacha', '/cursor', 'io.github.conglinyizhi.screenkacha', 'Moved', p.x, p.y);\n" +
  "});\n" +
  "t.start(200);\n"

///|
/// 脚本文件放哪。tmpfs，重启自动没。
fn kwin_script_path() -> String {
  let paths = @util.runtime_paths()
  "\{paths.app_runtime_dir}/cursor-kwin.js"
}

///|
/// 坐标服务在不在跑（它就是那个 D-Bus 名字的持有者）。
fn cursor_helper_alive() -> Bool {
  run_status(
    "busctl --user status io.github.conglinyizhi.screenkacha >/dev/null 2>&1",
  ) ==
  0
}

///|
/// 坐标是不是真的在流动：文件存在，且 3 秒内更新过。
///
/// 这是判断「跟踪有没有生效」的唯一可靠依据。helper 活着、脚本编号拿到了，
/// 都不代表 KWin 真的在往我们这儿送坐标。
fn cursor_pos_fresh() -> Bool {
  let pos = cursor_pos_path()
  let text = capture("cat '\{pos}' 2>/dev/null", 64)
  if text.trim() == "" {
    return false
  }
  // find -newermt 一条命令就能问「这个文件比 N 秒前新吗」
  let hit = capture("find '\{pos}' -newermt '-3 seconds' 2>/dev/null", 128)
  hit.trim() != ""
}

///|
/// 本进程 pid。加载 KWin 脚本时要用它区分不同的托盘实例。
extern "c" fn current_pid_raw() -> Int32 = "moonbit_screen_kacha_pid"

///|
fn current_pid() -> Int32 {
  current_pid_raw()
}

///|
/// 我们的脚本在 KWin 那边叫什么。
///
/// 必须带 pid。原来是写死的 `cursorprobe`：两个托盘实例（手滑起第二份、
/// 新旧两个 unit 同时装着）会抢同一个名字 —— 后加载的顶掉前一个，
/// 先退出的那个按名字一卸载，另一个的脚本也跟着没了，而且它自己不知道，
/// 勾选还亮着、箭头已经不动了。
fn cursor_script_name(pid : Int32) -> String {
  "screen-kacha-cursor-\{pid}"
}

///|
/// 本进程加载脚本用的名字。
fn own_script_name() -> String {
  cursor_script_name(current_pid())
}

///|
/// 挂上：写脚本、加载、启动，最后确认坐标真的开始流动。
fn cursor_tracking_on(helper_bin : String) -> Bool {
  let path = kwin_script_path()
  if !write_file(path, kwin_script_src) {
    return false
  }
  if !cursor_helper_alive() {
    sh("(setsid '\{helper_bin}' >/dev/null 2>&1 &)")
    // 给它一点时间抢到总线名字，下面还要复查。
    //
    // 这里必须用 run_status 而不是 sh：sh 是双 fork 后立刻返回、不等子进程，
    // 所以 `sh("sleep 0.6")` 根本不会等，helper 刚拉起来就被判定为不在。
    // 这个 bug 让「第一次开必失败、第二次开看起来成功」。
    let _ = run_status("sleep 0.6")
    if !cursor_helper_alive() {
      // helper 没起来就别继续了：脚本挂上去也收不到坐标，
      // 用户会看到勾选成功但截图没箭头。
      return false
    }
  }
  let name = own_script_name()
  let load_cmd = "gdbus call --session --dest org.kde.KWin --object-path /Scripting --method org.kde.kwin.Scripting.loadScript '\{path}' '\{name}' 2>/dev/null"
  let raw = capture(load_cmd, 64)
  let id = parse_script_id(raw)
  if id < 0 {
    cursor_tracking_off()
    return false
  }
  // 光有编号不算数：脚本文件不存在时 KWin 照样返回一个编号，
  // 问一句「这个脚本真加载了吗」才靠得住。
  let loaded = capture(
    "gdbus call --session --dest org.kde.KWin --object-path /Scripting --method org.kde.kwin.Scripting.isScriptLoaded '\{name}' 2>/dev/null",
    64,
  )
  if !loaded.contains("true") {
    cursor_tracking_off()
    return false
  }
  if run_status(
      "gdbus call --session --dest org.kde.KWin --object-path /Scripting --method org.kde.kwin.Scripting.start >/dev/null 2>&1",
    ) !=
    0 {
    cursor_tracking_off()
    return false
  }
  // 最后一步，也是唯一作数的一步：坐标到底流没流动。
  //
  // 之前只看 helper 活着就返回成功，于是会出现「勾选成功了、截图里却没有
  // 箭头」：脚本没加载、KWin 没跑起来、helper 名字没抢到，全都看不出来。
  for i = 0; i < 8; i = i + 1 {
    let _ = run_status("sleep 0.2")
    if cursor_pos_fresh() {
      return true
    }
  }
  // 没动静就把刚挂的东西收干净，别留一半
  cursor_tracking_off()
  false
}

///|
/// 从 `(uint32 5,)` 这种 gdbus 输出里抠出脚本编号。
/// 抠不到返回 -1。
fn parse_script_id(raw : String) -> Int32 {
  let mut n = -1
  for i = 0; i < raw.length(); i = i + 1 {
    let c = raw[i].to_int()
    if c >= 48 && c <= 57 {
      let d = c - 48
      n = if n < 0 { d } else { n * 10 + d }
    } else if n >= 0 {
      // 数字后面又出现了非数字，说明这个数已经读完了
      break
    }
  }
  n
}

///|
/// 摘下来：停脚本、删文件、杀掉 helper、清掉坐标。
///
/// 顺序有讲究，不能随便调：
///
/// 1. **先删坐标**。删晚了（比如被下面的 shell 问题打断）会留一个
///    停住的假箭头在图上，用户取消勾选却看不出变化。
/// 2. **杀 helper 不能写成 `pkill -f screen-kacha-cursor`**。
///    `sh()` 是通过 `sh -c '...'` 执行的，那个 shell 的 cmdline 里
///    就含这串字符，pkill 会连自己和后面的命令一起打死，
///    实测过：连 `pkill -f 一个不存在的名字` 都返回 Terminated。
///    用 `pgrep -x` 按进程名精确匹配，cmdline 不参与，杀不到自己。
/// 3. 最后删脚本文件。
fn cursor_tracking_off() -> Unit {
  let pos = cursor_pos_path()
  let script = kwin_script_path()

  // ① 先把坐标清掉：这一步失败也不能影响后面收摊
  let _ = remove_file(pos)

  // ② 停掉我们加载的那个脚本：按名字卸。
  //
  //    名字里带 pid，所以这一句只会卸自己那份，卸不到另一个托盘实例头上。
  //
  //    原来按 loadScript 返回的编号去停 /Scripting/Script{id}：编号是 KWin
  //    全局分配的，记录一旦过期（托盘重启、两个实例先后写了同一份记录文件），
  //    就可能停到别人——包括用户自己——的脚本上。再往前的版本更粗，盲停
  //    Script1..8，两头都错：既可能停掉用户自己开的脚本，也可能因为我们的
  //    编号 >8 而停不掉自己。
  let name = own_script_name()
  sh(
    "gdbus call --session --dest org.kde.KWin --object-path /Scripting --method org.kde.kwin.Scripting.unloadScript '\{name}' >/dev/null 2>&1",
  )

  // ③ 杀 helper。
  //
  // 不能用 `pgrep -x`：Linux 的 comm 只保留前 15 个字符，
  // `screen-kacha-cursor` 是 18 个，`-x` 永远匹配不到，等于从来没杀过，
  // helper 会一直活着占着 D-Bus 名字，下次勾选就直接复用这个僵尸。
  //
  // 改用 `-f` 匹配整条命令行，但模式写成 `[/]screen-kacha-cursor`：
  // 正则能匹配到 helper 自己，却匹配不到正在执行这条命令的 shell
  // （后者的 cmdline 里是字面上的方括号，不含连续的 /screen-kacha-cursor）。
  //
  // 这里原来写的是 `[s]creenstream-cursor` —— 项目改名之前的旧名字，
  // 现在一个进程都匹配不上，这句 kill 从来没生效过。名字跟着二进制走：
  // install.sh 装的是 `~/.local/bin/screen-kacha-cursor`。
  let pids = capture("pgrep -f '[/]screen-kacha-cursor' 2>/dev/null", 512)
  for line in pids.split("\n") {
    let t : String = line.trim().to_owned()
    if t != "" {
      sh("kill \{t} 2>/dev/null")
    }
  }

  // ④ 删脚本文件。脚本在 KWin 那边已经按名字卸掉了，文件留着没用。
  let _ = remove_file(script)
}

///|
/// 删一个文件。失败不报错，收摊过程最怕因为一步失败就中断。
fn remove_file(path : String) -> Bool {
  run_status("rm -f '\{path}'") == 0
}

///|
/// 当前坐标文件的位置（和服务端同一个约定）。
fn cursor_pos_path() -> String {
  let paths = @util.runtime_paths()
  "\{paths.app_runtime_dir}/cursor.pos"
}
