///|
/// 谁能访问这个服务。
///
/// 两级开关 + 一份预留名单。配置是纯文本，一行一项，`#` 开头是注释：
///
///   allow_lan    = true    # 局域网放行
///   allow_public = false   # 非局域网放行，危险，默认关
///   allow_cgnat  = false   # 把 100.64/10 也算局域网（穿透工具用）
///   allow        =         # 预留：显式放行的地址，优先于上面两档
///
/// 回环地址永远放行。
pub struct Access {
  mut allow_lan : Bool
  mut allow_public : Bool
  /// 把 100.64/10 也当局域网。默认关，见 `is_cgnat` 的说明。
  mut allow_cgnat : Bool
  allow : Array[String]
}

///|
/// 默认：局域网放行、公网不放行、没有额外名单。
pub fn Access::default() -> Access {
  { allow_lan: true, allow_public: false, allow_cgnat: false, allow: [], }
}

///|
/// 完全放开。
pub fn Access::open() -> Access {
  { allow_lan: true, allow_public: true, allow_cgnat: false, allow: [], }
}

///|
/// 要不要走带过滤的监听循环。公网都放行就等于不限制。
pub fn Access::restricted(self : Access) -> Bool {
  !self.allow_public
}

///|
/// 把 IPv4-mapped IPv6 还原成 IPv4。
///
/// `--bind [::]` 时 IPv4 客户端连进来，对端地址是 `::ffff:192.168.1.5` 这种写法。
/// 不还原的话它既不是回环也不是局域网，会被当成外部地址直接 403 ——
/// 本机用 127.0.0.1 访问都进不去。
pub fn unmap_ipv4(ip : String) -> String {
  let low = ascii_lower(ip)
  if low.has_prefix("::ffff:") {
    low[7:].to_owned()
  } else if low.has_prefix("0:0:0:0:0:ffff:") {
    low[15:].to_owned()
  } else {
    ip
  }
}

///|
/// IPv6 地址的第一段十六进制数。解析不出来返回 None。
fn first_hextet(ip : String) -> Int32? {
  let mut n = 0
  let mut any = false
  let mut i = 0
  while i < ip.length() {
    let c = ip[i].to_int()
    let d = if c >= 48 && c <= 57 {
      c - 48
    } else if c >= 97 && c <= 102 {
      c - 87
    } else if c >= 65 && c <= 70 {
      c - 55
    } else {
      -1
    }
    if d < 0 {
      break
    }
    n = n * 16 + d
    any = true
    i = i + 1
  }
  if any {
    Some(n)
  } else {
    None
  }
}

///|
/// 去掉端口，只留地址。`[::1]:8930` → `::1`，`1.2.3.4:80` → `1.2.3.4`
pub fn peer_ip(peer : String) -> String {
  if peer.has_prefix("[") {
    match peer.find("]") {
      Some(i) => return unmap_ipv4(peer[1:i].to_owned())
      None => return peer
    }
  }
  let mut cut = -1
  let mut i = 0
  while i < peer.length() {
    if peer[i] == ':' {
      cut = i
    }
    i = i + 1
  }
  // 只有一个冒号才当成 IPv4:port
  if cut > 0 {
    let head : String = peer[:cut].to_owned()
    if head.find(":") is None {
      return unmap_ipv4(head)
    }
  }
  peer
}

///|
/// 回环：127.0.0.0/8 与 ::1
pub fn is_loopback(ip : String) -> Bool {
  let addr = unmap_ipv4(ip)
  addr == "::1" || addr == "0:0:0:0:0:0:0:1" || addr.has_prefix("127.")
}

///|
/// 解析 IPv4 的一段；非法或越界返回 -1。
fn parse_octet(s : String) -> Int32 {
  if s.length() == 0 || s.length() > 3 {
    return -1
  }
  let mut n = 0
  for i = 0; i < s.length(); i = i + 1 {
    let c = s[i].to_int()
    if c < 48 || c > 57 {
      return -1
    }
    n = n * 10 + (c - 48)
  }
  if n > 255 {
    return -1
  }
  n
}

///|
/// 局域网：10/8、172.16/12、192.168/16、169.254/16；IPv6 的 fc00::/7 与 fe80::/10。
pub fn is_lan(ip : String) -> Bool {
  let addr = unmap_ipv4(ip)
  if addr.contains(":") {
    let low = ascii_lower(addr)
    // fc00::/7：唯一本地地址
    if low.has_prefix("fc") || low.has_prefix("fd") {
      return true
    }
    // fe80::/10 是链路本地，区间是 fe80–febf。
    // 原来只匹配 "fe80" 开头，fe90::、feb0:: 这些同属链路的地址被漏掉了。
    match first_hextet(low) {
      Some(h) => if h >= 0xFE80 && h <= 0xFEBF { return true }
      None => ()
    }
    return false
  }
  let ip = addr
  // split 返回的迭代器只能走一遍：先落成数组，再数长度、再遍历
  let parts : Array[String] = ip
    .split(".")
    .map(fn(x) { x.to_owned() })
    .to_array()
  if parts.length() != 4 {
    return false
  }
  let nums : Array[Int32] = []
  for p in parts {
    let n = parse_octet(p)
    if n < 0 {
      return false
    }
    nums.push(n)
  }
  if nums[0] == 10 {
    return true
  }
  if nums[0] == 172 && nums[1] >= 16 && nums[1] <= 31 {
    return true
  }
  if nums[0] == 192 && nums[1] == 168 {
    return true
  }
  if nums[0] == 169 && nums[1] == 254 {
    return true
  }
  false
}

///|
/// 运营商级 NAT 段 100.64.0.0/10（100.64 到 100.127）。
///
/// Tailscale、内网穿透这类工具常把地址落在这里。它不属于 RFC1918，
/// 公网上确实分配过这段，所以默认不当局域网：放宽会模糊「局域网」
/// 这个词的含义，而多数人根本用不到。需要的人自己在托盘里打开。
pub fn is_cgnat(ip : String) -> Bool {
  let ip = unmap_ipv4(ip)
  if ip.contains(":") {
    return false
  }
  let parts : Array[String] = ip
    .split(".")
    .map(fn(x) { x.to_owned() })
    .to_array()
  if parts.length() != 4 {
    return false
  }
  let a = parse_octet(parts[0])
  let b = parse_octet(parts[1])
  if a < 0 || b < 0 {
    return false
  }
  a == 100 && b >= 64 && b <= 127
}

///|
/// 这条连接能不能访问。
pub fn Access::allows(self : Access, peer : String) -> Bool {
  let ip = peer_ip(peer)
  if is_loopback(ip) {
    return true
  }
  for rule in self.allow {
    let r : String = rule.trim().to_owned()
    if r == "" {
      continue
    }
    if ip == r || (ip.has_prefix(r) && r.has_suffix(".")) {
      return true
    }
  }
  if is_lan(ip) || (self.allow_cgnat && is_cgnat(ip)) {
    return self.allow_lan
  }
  self.allow_public
}

///|
/// 解析布尔值。大小写不敏感：`True`、`TRUE`、`On` 都算真。
///
/// 原来只认全小写的 `true`/`1`/`yes`，`allow_public = True` 会被静默当成
/// false：用户以为放开了，实际没开，而且没人报错。
pub fn parse_flag_value(v : String) -> Bool {
  // 实现统一在 @util.parse_flag：托盘那边原来还有一份同名不同逻辑的副本
  @util.parse_flag(v)
}

///|
/// 取一行配置的 key（`=` 左边，去掉空白）。空行和注释返回 None。
///
/// 服务端和托盘共用这一个判定。托盘原来是 `has_prefix("allow_lan")`，
/// 于是 `allow_lan_next = false` 这种未知键会被改写成 `allow_lan = <值>`，
/// 而服务端只认 key 完全相等的行。
pub fn config_line_key(line : String) -> String? {
  let s : String = line.trim().to_owned()
  if s == "" || s.has_prefix("#") {
    return None
  }
  match s.find("=") {
    None => None
    Some(eq) => Some(s[:eq].trim().to_owned())
  }
}

///|
/// 配置里值得提醒一句的地方：废弃键、不认识的键。
///
/// 原来全都不响：拼错的键（`alow_lan`）被静默忽略，跑的是默认值；
/// `local_only` 这种老写法也不提示，用户不知道自己该改。
pub fn config_warnings(text : String) -> Array[String] {
  let known : Array[String] = [
    "allow_lan", "allow_public", "allow_cgnat", "allow", "local_only",
  ]
  let warns : Array[String] = []
  let mut said_deprecated = false
  for line in text.split("\n") {
    let key = match config_line_key(line.to_owned()) {
      Some(k) => k
      None => continue
    }
    if key == "local_only" {
      if !said_deprecated {
        warns.push("local_only 已废弃：请改用 allow_lan / allow_public")
        said_deprecated = true
      }
    } else if !known.contains(key) {
      warns.push("未知配置项 \{key}，已忽略")
    }
  }
  warns
}

///|
/// 解析配置。坏行忽略；老配置里的 `local_only = true` 仍然认。
pub fn parse_access(text : String) -> Access {
  let a = Access::default()
  for line in text.split("\n") {
    let s : String = line.trim().to_owned()
    let key : String = match config_line_key(s) {
      Some(k) => k
      None => continue
    }
    match s.find("=") {
      None => ()
      Some(eq) => {
        let value : String = s[eq + 1:].trim().to_owned()
        let on = parse_flag_value(value)
        if key == "allow_lan" {
          a.allow_lan = on
        } else if key == "allow_public" {
          a.allow_public = on
        } else if key == "allow_cgnat" {
          a.allow_cgnat = on
        } else if key == "local_only" {
          // 老写法，按值处理：只有 true 才是「仅本机」。
          // 原来不看值，`local_only = false` 也被当成两档全关，
          // 而托盘根本不认这个键，显示的是「放行局域网」。
          if on {
            a.allow_lan = false
            a.allow_public = false
          }
        } else if key == "allow" {
          for item in value.split(",") {
            let t : String = item.trim().to_owned()
            if t != "" {
              a.allow.push(t)
            }
          }
        }
      }
    }
  }
  a
}

///|
/// 读配置；文件不存在就用默认，其他读取错误返回 None，调用方必须拒绝启动。
pub async fn load_access(path : String) -> Access? {
  let file = Some(@fs.open(path, mode=ReadOnly)) catch {
    @os_error.OSError(_) as err if err.is_ENOENT() =>
      return Some(Access::default())
    err => {
      eprintln("读取访问控制配置失败（\{path}）：\{err}")
      return None
    }
  }
  let file = file.unwrap()
  defer file.close()
  let text = try {
    @utf8.decode_lossy(file.read_all().binary())
  } catch {
    err => {
      eprintln("读取访问控制配置失败（\{path}）：\{err}")
      return None
    }
  }
  for w in config_warnings(text) {
    eprintln("配置警告：\{w}")
  }
  Some(parse_access(text))
}

///|
/// 一句话描述当前策略，给启动日志和 /health 用。
pub fn Access::describe(self : Access) -> String {
  let parts : Array[String] = []
  if self.allow_public {
    parts.push("全部放行")
  } else if self.allow_lan {
    parts.push("局域网放行")
  } else {
    parts.push("仅本机")
  }
  if self.allow_cgnat {
    parts.push("含 100.64/10")
  }
  if self.allow.length() > 0 {
    parts.push("名单 " + self.allow.join(","))
  }
  parts.join(" + ")
}
