///|
/// 托盘的心跳记录。
///
/// 托盘每 5 秒整份重写一次（跟着它的 tick），服务读它判断托盘还在不在。
/// 放在 moonutil 而不是两边各写一份：格式只有一种，写方（托盘）和读方
/// （服务）不会各自演化出一个不兼容的版本。
pub struct TrayOwner {
  /// 托盘进程 pid
  pid : Int32
  /// 该由这个托盘负责卸载的 KWin 脚本名；空串表示它没挂过脚本
  script : String
  /// cursor helper 的 pid，没在跑就是 0
  helper : Int32
  /// 写这一行的时刻（自 epoch 的毫秒数）
  ts_ms : Int64
  /// 服务累计的连续心跳失败次数。托盘只是抄一遍，自己不数
  miss : Int32
}

///|
/// 造一条记录。
///
/// 字段对别的包是只读的，所以得走这个构造器 —— 读的人不该随手改出
/// 一条自相矛盾的记录（比如换了 pid 却没换脚本名）。
pub fn TrayOwner::new(
  pid : Int32,
  script : String,
  helper : Int32,
  ts_ms : Int64,
  miss : Int32,
) -> TrayOwner {
  { pid, script, helper, ts_ms, miss, }
}

///|
/// 一条记录的字符数上限。
///
/// 读的时候超过这个长度就整条丢掉：`tray.owner` 只有五个短字段，
/// 长成这样说明读到的是别的东西（写坏的、别的进程占了这个路径），
/// 拿去判死活只会得出奇怪的结论。
pub const TRAY_OWNER_MAX_BYTES : Int32 = 4096

///|
/// 序列化成逐行 `key=value`。
///
/// 逐行的理由：`cat` 一下就能看懂，坏一行也只坏一个字段；
/// 而且托盘的字段和服务写的 `miss` 分开在两行，谁改哪一行一眼就看得出来。
pub fn TrayOwner::render(self : TrayOwner) -> String {
  "pid=\{self.pid}\n" +
  "script=\{self.script}\n" +
  "helper=\{self.helper}\n" +
  "ts_ms=\{self.ts_ms}\n" +
  "miss=\{self.miss}\n"
}

///|
/// 在这一行里找第一个 `=`，拆成键和值。
fn split_kv(line : StringView) -> (String, String)? {
  for i = 0; i < line.length(); i = i + 1 {
    if line[i].to_int() == 61 {
      return Some((line[0:i].to_owned(), line[i + 1:].to_owned()))
    }
  }
  None
}

///|
/// 解析心跳记录。
///
/// `pid` 或 `ts_ms` 缺失、不是数字、不是正数，一律返回 None：
/// 没有 pid 没法清场，没有时间戳判不了死活，半条记录比没有更危险
/// （比如 pid 读成 0 还照着它去 kill，kill 的是整个进程组）。
///
/// 其余字段宽松处理：`script` 缺失就是空串，`helper` / `miss` 缺失或
/// 读成垃圾、负数，都退到 0 —— 这两处「什么都不做」正是对的默认。
pub fn TrayOwner::parse(text : String) -> TrayOwner? {
  let mut pid = 0
  let mut script = ""
  let mut helper = 0
  let mut ts = 0L
  let mut miss = 0
  for line in text.split("\n") {
    match split_kv(line.trim()) {
      None => ()
      Some((k, v)) =>
        if k == "pid" {
          pid = parse_int(v.trim(), 0)
        } else if k == "script" {
          script = v.trim().to_owned()
        } else if k == "helper" {
          helper = parse_int(v.trim(), 0)
        } else if k == "ts_ms" {
          ts = parse_int64(v.trim(), 0L)
        } else if k == "miss" {
          miss = parse_int(v.trim(), 0)
        }
    }
  }
  if pid <= 0 || ts <= 0L {
    return None
  }
  Some({
    pid,
    script,
    helper: if helper < 0 {
      0
    } else {
      helper
    },
    ts_ms: ts,
    miss: if miss < 0 {
      0
    } else {
      miss
    },
  })
}

///|
/// 解析十进制 Int64，非法返回默认值。
///
/// 这里不能借 `parse_int`（那是 Int32，时间戳装不下），规则保持一致：
/// 空串、带符号、夹了别的东西一律算非法。
fn parse_int64(s : StringView, dflt : Int64) -> Int64 {
  if s.length() == 0 || s.length() > 19 {
    return dflt
  }
  let mut n = 0L
  for i = 0; i < s.length(); i = i + 1 {
    let c = s[i]
    guard c >= 48 && c <= 57 else { return dflt }
    n = n * 10L + (c.to_int() - 48).to_int64()
  }
  n
}
