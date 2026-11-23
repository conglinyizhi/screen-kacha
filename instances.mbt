///|
/// 同一块屏上有没有第二个 screen-kacha 在抓。
///
/// 为什么要管：`spectacle` 是单实例应用，两个抓帧进程并发跑会互相卡死
/// （实测三个并发就永久挂住）。这种症状看起来是「截图卡了」，从外面完全
/// 看不出是「你自己开了两份」，所以启动时把这件事说出来。
///
/// 只警告，不拦。用户可能就是有意开一份临时实例（换端口、换帧目录、假帧源），
/// 值不值得继续由人决定。

///|
/// 一个同机进程的画像。判定只认这四个字段。
priv struct ProcInfo {
  pid : Int32
  /// `/proc/<pid>/cmdline` 里 argv[0] 的 basename
  exe : String
  wayland_display : String
  display : String
}

///|
/// 这两个名字才算「同一个抓帧程序」。
///
/// `screen-kacha` 是装好的名字，`main.exe` 是开发时直接跑构建产物。
/// 托盘（`screen-kacha-tray`）和 portal 助手（`screen-kacha-portal`）不算：
/// 它们本来就会和主服务同时存在，而且助手手里那条流正是我们要的。
fn is_capture_exe(name : String) -> Bool {
  name == "screen-kacha" || name == "main.exe"
}

///|
/// 两边的显示标识对得上吗。
///
/// 逐个变量比：相等算对上；**有一边没设这个变量也算对上** —— 知道的那一边
/// 不能推翻不知道的那一边。
///
/// 为什么不要求四个值全等：`screen-kacha.service` 里设了 `WAYLAND_DISPLAY`
/// 但没有 `DISPLAY`，而从终端手动起的那份两个都有。全等的话，最该抓到的
/// 那种情况（手滑多起一份，基本都是从终端起的）正好漏掉。
fn display_value_matches(a : String, b : String) -> Bool {
  a == b || a == "" || b == ""
}

///|
/// 从候选里挑出「正在抓同一块屏」的别的实例，返回它们的 pid。
///
/// 纯函数：候选从哪来（`/proc`、测试里的假列表）由调用方决定，判定才好单测。
/// 自己不算 —— 这条检查是给别人看的。
fn screen_capture_conflicts(
  me : ProcInfo,
  candidates : Array[ProcInfo],
) -> Array[Int32] {
  let out : Array[Int32] = []
  for c in candidates {
    if c.pid == me.pid {
      continue
    }
    if !is_capture_exe(c.exe) {
      continue
    }
    if !display_value_matches(c.wayland_display, me.wayland_display) {
      continue
    }
    if !display_value_matches(c.display, me.display) {
      continue
    }
    out.push(c.pid)
  }
  out
}

///|
/// 按 NUL 切开。`/proc/<pid>/cmdline` 和 `/proc/<pid>/environ` 都是这个格式。
fn split_nul(b : Bytes) -> Array[String] {
  let out : Array[String] = []
  let mut start = 0
  let n = b.length()
  for i = 0; i <= n; i = i + 1 {
    if i == n || b[i].to_int() == 0 {
      if i > start {
        out.push(@utf8.decode_lossy(b[start:i]))
      }
      start = i + 1
    }
  }
  out
}

///|
/// 取路径最后一段。
fn basename(path : String) -> String {
  let mut cut = -1
  for i = 0; i < path.length(); i = i + 1 {
    if path[i].to_int() == 47 {
      cut = i
    }
  }
  if cut < 0 {
    path
  } else {
    path[cut + 1:].to_owned()
  }
}

///|
/// 读一个小文本文件，读不到返回 None。
///
/// `/proc` 下面那些（cmdline、environ、pressure）和状态目录里的文件都走它：
/// 读失败不抛，交给调用方按「没有」处理。
async fn read_file_or_none(path : String) -> Bytes? {
  let f = Some(@fs.open(path, mode=ReadOnly)) catch { _ => return None }
  let file = match f {
    Some(x) => x
    None => return None
  }
  // defer：读失败也要把它关掉。这个 helper 被 5 秒一轮的监督循环用着，
  // 漏一个 fd 就是每 5 秒漏一个，跑一天能把进程的 fd 耗光。
  defer file.close()
  Some(file.read_all().binary()) catch {
    _ => None
  }
}

///|
/// 进程的可执行名（argv[0] 的最后一段）。
///
/// `base` 是 `/proc/<pid>` 或 `/proc/self`。
async fn proc_exe(base : String) -> String? {
  match read_file_or_none("\{base}/cmdline") {
    Some(b) =>
      match split_nul(b) {
        [] => None
        [argv0, ..] => Some(basename(argv0))
      }
    None => None
  }
}

///|
/// 进程环境里的 `WAYLAND_DISPLAY` 和 `DISPLAY`。
///
/// 读不到返回 None：`/proc/<pid>/environ` 是 0400，别的用户的进程读不了。
/// 那种进程抓不到我们的屏，直接跳过 —— 但要靠 None 和「读到空值」区分开，
/// 否则会把它当成「显示未知」而误报。
async fn proc_display_env(base : String) -> (String, String)? {
  match read_file_or_none("\{base}/environ") {
    None => None
    Some(b) => {
      let mut wl = ""
      let mut disp = ""
      for kv in split_nul(b) {
        if kv.has_prefix("WAYLAND_DISPLAY=") {
          wl = kv[16:].to_owned()
        } else if kv.has_prefix("DISPLAY=") {
          disp = kv[8:].to_owned()
        }
      }
      Some((wl, disp))
    }
  }
}

///|
/// 扫一遍 `/proc`，挑出可能抓屏的别的进程。
///
/// 先按 cmdline 判名字，名字对上了才去读 environ：读别的用户进程的
/// environ 会 EACCES，不为几百个无关进程各付一次失败的 open。
async fn scan_capture_procs() -> Array[ProcInfo] {
  let names = try {
    let d = @fs.opendir("/proc")
    let all = d.read_all()
    d.close()
    all
  } catch {
    _ => ([] : Array[String])
  }
  let out : Array[ProcInfo] = []
  for name in names {
    let pid = @util.parse_int(name, -1)
    if pid <= 0 {
      continue
    }
    let base = "/proc/\{pid}"
    let exe = match proc_exe(base) {
      Some(e) => e
      None => continue
    }
    if !is_capture_exe(exe) {
      continue
    }
    match proc_display_env(base) {
      Some((wl, disp)) =>
        out.push({ pid, exe, wayland_display: wl, display: disp, })
      None => ()
    }
  }
  out
}

///|
/// 本进程的画像，问的是 `/proc/self`（省一次自己 pid 的拼接）。
async fn self_info() -> ProcInfo? {
  let exe = match proc_exe("/proc/self") {
    Some(e) => e
    None => return None
  }
  let (wl, disp) = match proc_display_env("/proc/self") {
    Some(pair) => pair
    None => ("", "")
  }
  Some({ pid: current_pid(), exe, wayland_display: wl, display: disp, })
}

///|
/// 启动时自检：同机有没有第二个 screen-kacha 在抓同一块屏。
///
/// 找到就每个 pid 打一行警告，返回这些 pid（调用方要拿去做别的判断也行，
/// 目前只打日志）。扫不到 `/proc` 这类环境问题一律按「没有」处理 ——
/// 这是自检，不能因为它自己失败就挡住启动。
pub async fn warn_duplicate_instances() -> Array[Int32] {
  let me = match self_info() {
    Some(p) => p
    None => return []
  }
  let conflicts = screen_capture_conflicts(me, scan_capture_procs())
  for pid in conflicts {
    eprintln(
      "另一个 screen-kacha 实例正在抓同一块屏（pid=\{pid}）。spectacle 是单实例应用，并发抓帧会互相卡死；确认这是你要的再继续。",
    )
  }
  conflicts
}
