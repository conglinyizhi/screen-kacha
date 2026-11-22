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
/// 去掉端口，只留地址。`[::1]:8930` → `::1`，`1.2.3.4:80` → `1.2.3.4`
pub fn peer_ip(peer : String) -> String {
  if peer.has_prefix("[") {
    match peer.find("]") {
      Some(i) => return peer[1:i].to_owned()
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
      return head
    }
  }
  peer
}

///|
/// 回环：127.0.0.0/8 与 ::1
pub fn is_loopback(ip : String) -> Bool {
  ip == "::1" || ip == "0:0:0:0:0:0:0:1" || ip.has_prefix("127.")
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
  if ip.contains(":") {
    if ip.has_prefix("fc") || ip.has_prefix("FC") {
      return true
    }
    if ip.has_prefix("fd") || ip.has_prefix("FD") {
      return true
    }
    if ip.has_prefix("fe80") || ip.has_prefix("FE80") {
      return true
    }
    return false
  }
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
/// 解析配置。坏行忽略；老配置里的 `local_only = true` 仍然认。
pub fn parse_access(text : String) -> Access {
  let a = Access::default()
  for line in text.split("\n") {
    let s : String = line.trim().to_owned()
    if s == "" || s.has_prefix("#") {
      continue
    }
    match s.find("=") {
      None => ()
      Some(eq) => {
        let key : String = s[:eq].trim().to_owned()
        let value : String = s[eq + 1:].trim().to_owned()
        let on = value == "true" || value == "1" || value == "yes"
        if key == "allow_lan" {
          a.allow_lan = on
        } else if key == "allow_public" {
          a.allow_public = on
        } else if key == "allow_cgnat" {
          a.allow_cgnat = on
        } else if key == "local_only" {
          a.allow_lan = false
          a.allow_public = false
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
/// 读配置；文件不存在就用默认（局域网放行、公网不放行）。
pub async fn load_access(path : String) -> Access {
  let exists = @fs.exists(path) catch { _ => false }
  if !exists {
    return Access::default()
  }
  let text = try {
    let f = @fs.open(path, mode=ReadOnly)
    let b = f.read_all().binary()
    f.close()
    @utf8.decode_lossy(b)
  } catch {
    _ => ""
  }
  parse_access(text)
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
