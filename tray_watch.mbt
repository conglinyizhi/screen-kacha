///|
/// 服务侧盯着托盘的心跳。
///
/// 托盘崩掉之后，它留在系统里的东西不会自己消失：KWin 里的脚本还挂着，
/// 每 200ms 往一个没人接的 D-Bus 名字上打坐标；cursor helper 还活着，
/// 占着那个名字。正常的退出口（菜单、SIGTERM）托盘自己会收，
/// 崩溃、被 SIGKILL、死锁都收不了 —— 所以由服务这边兜底。
///
/// 心跳是反过来的：托盘每 5 秒写一次 `tray.owner`，服务读它。
/// 服务只做「读心跳 + 判断 + 清场」，托盘只做「写心跳」，两边没有共享状态。

///|
/// 托盘心跳的基准间隔：托盘每 5 秒写一次，服务也按这个节奏看。
///
/// 判定用的「新鲜」阈值也是它：一条 5 秒内写过的心跳算活着。
pub const TRAY_PROBE_BASE_MS : Int32 = 5000

///|
/// 连续几次「读到的心跳已经过期」算托盘死了。
///
/// 3 次：第一次过期多半只是调度抖动（托盘被抢占了几百毫秒、系统在换页），
/// 后面两次是缩短到 1.5 秒一次催出来的。再往后等没有收益 ——
/// 那段时间里 KWin 脚本一直在打没人接的 D-Bus。
pub const TRAY_MISS_DEAD : Int32 = 3

///|
/// 高压力阈值：PSI（`/proc/pressure/cpu|io`）的 some avg10 超过它算高压。
///
/// 单位是百分之一：6000 = 60%。PSI 的 avg10 本来就只有两位小数，
/// 用整数比浮点省事，也不会在阈值附近抖。
const PRESSURE_AVG10_HIGH : Int32 = 6000

///|
/// 没有 PSI 时退到 `/proc/loadavg`：load1 / CPU 核数 超过它算高压。
///
/// 单位同样是百分之一：150 = 1.5 倍核数。
const PRESSURE_LOAD_PER_CORE : Int32 = 150

///|
/// 这一轮探测的结论。
pub enum ProbeDecision {
  /// 继续盯着：下一次的连续失败次数、下一次隔多久看
  Keep(Int32, Int32)
  /// 连续失败够多次了，该清场
  Dead
  /// 托盘写的时间在我们之后：两边时钟不统一，这一轮不算数
  Skew
}

///|
/// 心跳过去多久了（毫秒）。负数表示记录里的时间在未来。
///
/// 单独一个函数是为了让「时钟不统一」这件事在测试里能直接摆出来：
/// 托盘写 CLOCK_MONOTONIC、服务读墙上时钟时，差值就是个负数。
pub fn stale_ms_of(now_ms : Int64, ts_ms : Int64) -> Int64 {
  now_ms - ts_ms
}

///|
/// 判定过期之后催问的间隔：基准的 3/10（5 秒的基准就是 1.5 秒）。
///
/// 缩短是为了尽快拿到「到底是抖动还是真死」的证据：真死了三轮很快就问完，
/// 只是抖动的话下一轮就能看见新心跳、计数归零。
fn probe_interval(base_ms : Int32) -> Int32 {
  let v = base_ms * 3 / 10
  if v < 1 {
    1
  } else {
    v
  }
}

///|
/// 这一轮该怎么处理。纯函数：只吃标量，不读时钟、不碰文件、不碰进程。
///
/// 规则（顺序就是优先级）：
/// 1. 时间戳在未来 → 时钟不统一，`Skew`：不判死、不升级
/// 2. 心跳新鲜（`stale_ms < base_ms`）→ 计数归零
/// 3. 过期但压力高 → 不升级也不判死，间隔放宽到 `base * 2`
/// 4. 过期且已经失败满 `TRAY_MISS_DEAD` 次 → `Dead`
/// 5. 过期 → 计数 +1，间隔缩短去催
pub fn decide_probe(
  miss_count : Int32,
  pressure : Bool,
  stale_ms : Int64,
  base_ms : Int32,
) -> ProbeDecision {
  // 时钟不统一：差值是负的。这时候「过期」和「新鲜」都算不出来，
  // 拿它去累计失败会攒出一个假死判定 —— 而托盘可能活得好好的。
  // 只记一次异常，计数归零。
  if stale_ms < 0L {
    return Skew
  }
  if stale_ms < base_ms.to_int64() {
    // 新鲜心跳。高压下也照样归零：真的收到了心跳，没有理由还挂着旧的失败。
    return Keep(0, if pressure { base_ms * 2 } else { base_ms })
  }
  if pressure {
    // 过期，但机器正忙：读到的「过期」可能是我们自己的调度延迟。
    // 不升级、不判死，间隔放宽一倍，等压力过去。
    return Keep(miss_count, base_ms * 2)
  }
  if miss_count >= TRAY_MISS_DEAD {
    Dead
  } else {
    Keep(miss_count + 1, probe_interval(base_ms))
  }
}

///|
/// 把 "45.67" 这种两位小数读成百分之一为单位的整数（4567）。
///
/// PSI 的 avg10 和 loadavg 都是这个形状，用整数比较就够了。
/// 第三位以后直接丢（"0.005" 不会出现在这两个文件里）。
fn parse_hundredths(s : StringView) -> Int32? {
  let t = s.trim()
  if t.length() == 0 {
    return None
  }
  let mut int_part = 0
  let mut frac = 0
  let mut frac_digits = 0
  let mut seen_dot = false
  for i = 0; i < t.length(); i = i + 1 {
    let c = t[i].to_int()
    if c == 46 {
      // '.'
      if seen_dot {
        return None
      }
      seen_dot = true
    } else if c >= 48 && c <= 57 {
      if seen_dot {
        if frac_digits < 2 {
          frac = frac * 10 + (c - 48)
          frac_digits = frac_digits + 1
        }
      } else {
        int_part = int_part * 10 + (c - 48)
      }
    } else {
      return None
    }
  }
  let scale = if frac_digits == 0 {
    100
  } else if frac_digits == 1 {
    10
  } else {
    1
  }
  Some(int_part * 100 + frac * scale)
}

///|
/// 从 `/proc/pressure/*` 里取 `some` 那一行的 `avg10`（百分之一为单位）。
///
/// 格式：`some avg10=0.00 avg60=0.00 avg300=0.00 total=152175145`
/// （io 文件下面还有一行 `full ...`，那行不看；cpu 文件也一样有。）
pub fn parse_psi_some_avg10(text : String) -> Int32? {
  for line in text.split("\n") {
    let s = line.trim()
    if !s.has_prefix("some ") {
      continue
    }
    for field in s.split(" ") {
      if field.has_prefix("avg10=") {
        return parse_hundredths(field[6:])
      }
    }
    return None
  }
  None
}

///|
/// 从 `/proc/loadavg` 里取 load1（百分之一为单位）。
///
/// 格式：`0.24 0.20 0.29 1/1471 252732`
pub fn parse_load1(text : String) -> Int32? {
  let s = text.trim()
  if s.length() == 0 {
    return None
  }
  for i = 0; i < s.length(); i = i + 1 {
    if s[i].to_int() == 32 {
      return parse_hundredths(s[0:i])
    }
  }
  parse_hundredths(s)
}

///|
/// 这一轮算不算高压力。
///
/// 有 PSI 就以 PSI 为准（cpu 或 io 任一超阈值），两个都读不到才退到
/// load1 / 核数。全都没有（奇怪的容器环境）就当正常 ——
/// 判死比判压力重要，不该因为读不到压力就把托盘晾着不管。
pub fn pressure_is_high(
  cpu_avg10 : Int32?,
  io_avg10 : Int32?,
  load1 : Int32?,
  ncpu : Int32,
) -> Bool {
  let mut psi_seen = false
  match cpu_avg10 {
    Some(v) => {
      psi_seen = true
      if v > PRESSURE_AVG10_HIGH {
        return true
      }
    }
    None => ()
  }
  match io_avg10 {
    Some(v) => {
      psi_seen = true
      if v > PRESSURE_AVG10_HIGH {
        return true
      }
    }
    None => ()
  }
  if psi_seen {
    return false
  }
  match load1 {
    Some(v) => ncpu > 0 && v > PRESSURE_LOAD_PER_CORE * ncpu
    None => false
  }
}

///|
/// 托盘心跳记录的路径。
pub fn tray_owner_path() -> String? {
  match @util.state_dir() {
    Some(d) => Some("\{d}/tray.owner")
    None => None
  }
}

///|
/// 服务写给托盘看的「连续失败次数」。
///
/// 为什么和 owner 分两个文件：两个进程写同一个文件，谁后写谁赢。
/// 托盘每 5 秒整份重写 owner，服务刚写进去的 `miss=2` 会被托盘按它手里的
/// 旧值覆盖回 0 —— 计数永远涨不到 3，看门狗永远不触发，功能等于没有。
/// 分成两个文件各写各的，不需要任何协调，也不需要谁先读后写。
pub fn tray_miss_path() -> String? {
  match @util.state_dir() {
    Some(d) => Some("\{d}/tray.miss")
    None => None
  }
}

///|
/// 读托盘心跳。没有、读不出来、格式不对都返回 None（当作「没有托盘」）。
async fn read_tray_owner() -> @util.TrayOwner? {
  let path = match tray_owner_path() {
    Some(p) => p
    None => return None
  }
  let bytes = match read_file_or_none(path) {
    Some(b) => b
    None => return None
  }
  if bytes.length() > @util.TRAY_OWNER_MAX_BYTES {
    return None
  }
  @util.TrayOwner::parse(@utf8.decode_lossy(bytes))
}

///|
/// 把连续失败次数写给托盘。写不进去不影响判定，下一轮还会再写。
fn write_tray_miss(n : Int32) -> Unit {
  match tray_miss_path() {
    Some(p) => {
      let _ = @util.write_atomic_text(p, n.to_string())
    }
    None => ()
  }
}

///|
/// 这一轮算不算高压力。读不到就按「不高」处理。
async fn read_pressure_high() -> Bool {
  let cpu = match read_file_or_none("/proc/pressure/cpu") {
    Some(b) => parse_psi_some_avg10(@utf8.decode_lossy(b))
    None => None
  }
  let io = match read_file_or_none("/proc/pressure/io") {
    Some(b) => parse_psi_some_avg10(@utf8.decode_lossy(b))
    None => None
  }
  // 读得到 PSI 就不看 loadavg：PSI 量的是「真的被堵了多久」，
  // loadavg 只是排队长度，能拿到前者就没必要退到后者。
  let load1 = if cpu is None && io is None {
    match read_file_or_none("/proc/loadavg") {
      Some(b) => parse_load1(@utf8.decode_lossy(b))
      None => None
    }
  } else {
    None
  }
  pressure_is_high(cpu, io, load1, cpu_count())
}

///|
/// 卸掉一个 KWin 脚本（按名字，不按编号）。
///
/// 服务是 headless，没有 D-Bus 客户端代码，起一个 `gdbus` 就够。
/// 参数按 argv 传、不拼 shell：脚本名里就算有奇怪字符也不会被解释。
/// KWin 没在跑（纯 X11 会话、正在重启）时这里会失败，那不算异常 ——
/// 清场剩下的步骤照样要走。
async fn unload_kwin_script(name : String) -> Unit {
  let script = name.trim().to_owned()
  if script == "" {
    return
  }
  let (code, stdout) = @process.collect_stdout("/usr/bin/gdbus", [
    "call", "--session", "--dest", "org.kde.KWin", "--object-path", "/Scripting",
    "--method", "org.kde.kwin.Scripting.unloadScript", script,
  ]) catch {
    err => {
      eprintln("卸 KWin 脚本 \{script} 没起来：\{err}")
      return
    }
  }
  let text = stdout.text() catch { _ => "" }
  if code != 0 || text.trim() == "" {
    eprintln("卸 KWin 脚本 \{script} 没成功（退出码 \{code}）")
  }
}

///|
/// 杀掉那个 cursor helper。
///
/// pid 可能已经被内核复用给别的进程，所以先看它现在的命令行是不是
/// cursor helper：不是就不动。一个多活的 helper 会占着 D-Bus 名字，
/// 但误杀别人的进程更糟。
async fn kill_cursor_helper(pid : Int32) -> Unit {
  if pid <= 0 {
    return
  }
  let exe = match proc_exe("/proc/\{pid}") {
    Some(e) => e
    // 进程已经不在了：这也是最常见的正常情况，不用说话
    None => return
  }
  if exe != "screen-kacha-cursor" {
    eprintln("pid=\{pid} 现在是 \{exe}，不是坐标进程，跳过")
    return
  }
  let rc = kill_term(pid)
  if rc != 0 {
    eprintln("给坐标进程 pid=\{pid} 发 SIGTERM 失败（errno \{-rc}）")
  }
}

///|
/// 删掉心跳记录和失败计数。已经不在不算错。
async fn remove_tray_files() -> Unit {
  for path in [tray_owner_path(), tray_miss_path()] {
    match path {
      Some(p) => @fs.remove(p) catch { _ => () }
      None => ()
    }
  }
}

///|
/// 把一个不再心跳的托盘留在系统里的东西收掉。
///
/// 顺序：验 pid → 卸 KWin 脚本 → 杀 cursor helper → 删记录 → 留日志。
/// 每一步失败都只记不抛：监督循环不能因为某一步失败就整个停掉，
/// 那等于下一次崩溃又没人管。
pub async fn cleanup_tray(owner : @util.TrayOwner) -> Unit {
  // ① 先看那个 pid 还在不在。
  //
  // 不在了是最常见的（崩溃、被 kill -9）。还在也不正常 —— 心跳停了 3 轮，
  // 说明它卡在什么地方（死锁、被 SIGSTOP 冻住）。两种都要清场：
  // 它留在 KWin 和总线上的东西，跟它进程活不活着没关系。
  let alive = pid_alive(owner.pid) != 0
  // ② 卸脚本
  unload_kwin_script(owner.script)
  // ③ 杀坐标进程
  kill_cursor_helper(owner.helper)
  // ④ 删记录，下一次「托盘重新出现」从干净的 0 开始
  remove_tray_files()
  // ⑤ 留一行。用户从 journal 里能看出「昨天那个幽灵脚本是谁收掉的」
  eprintln(
    "托盘 pid=\{owner.pid} 连续 \{TRAY_MISS_DEAD} 次心跳超时，已清理它的 KWin 脚本和坐标进程",
  )
  if alive {
    eprintln(
      "托盘 pid=\{owner.pid} 进程还在但不再写心跳（死锁或被冻住），建议手动重启托盘",
    )
  }
}

///|
/// 托盘监督循环。
///
/// 每轮：读心跳 → 算停滞时长 → 读压力 → 判定 → 更新失败计数 → 睡到下一次。
/// 没有心跳文件时就按基准间隔慢慢看，不叫也不清场：
/// 「没有托盘」和「托盘死了」是两件事，后者才有文件留下来。
pub async fn supervise_tray() -> Unit {
  let mut miss = 0
  let mut interval = TRAY_PROBE_BASE_MS
  let mut skewed = false
  for ;; {
    @async.sleep(interval)
    let owner = match read_tray_owner() {
      Some(o) => o
      None => {
        if miss != 0 {
          write_tray_miss(0)
        }
        miss = 0
        skewed = false
        interval = TRAY_PROBE_BASE_MS
        continue
      }
    }
    let stale = stale_ms_of(@util.now_ms(), owner.ts_ms)
    let pressure = read_pressure_high()
    match decide_probe(miss, pressure, stale, TRAY_PROBE_BASE_MS) {
      Skew => {
        // 时钟对不上：不判死，但要说一声。不说的话症状是
        // 「托盘崩了，服务一直不说话」，没人知道是时钟的锅。
        if !skewed {
          eprintln(
            "托盘心跳的时间戳比我们还晚（\{stale}ms），两边时钟不一致，暂不判死",
          )
        }
        skewed = true
        if miss != 0 {
          write_tray_miss(0)
        }
        miss = 0
        interval = TRAY_PROBE_BASE_MS
      }
      Dead => {
        cleanup_tray(owner)
        miss = 0
        skewed = false
        interval = TRAY_PROBE_BASE_MS
      }
      Keep(next_miss, next_interval) => {
        if skewed {
          eprintln("托盘心跳恢复正常，继续盯着")
        }
        skewed = false
        if next_miss != miss {
          write_tray_miss(next_miss)
        }
        miss = next_miss
        interval = next_interval
      }
    }
  }
}

///|
/// 这个 pid 还在不在。
extern "c" fn pid_alive(pid : Int32) -> Int32 = "moonbit_pid_alive"

///|
/// 给一个进程发 SIGTERM。pid <= 0 会被 C 侧拒掉（那是进程组）。
extern "c" fn kill_term(pid : Int32) -> Int32 = "moonbit_kill_term"

///|
/// 在线 CPU 数，至少 1。
extern "c" fn cpu_count() -> Int32 = "moonbit_cpu_count"
