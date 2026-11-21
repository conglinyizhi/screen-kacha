///|
/// 谁能访问这个服务。
///
/// 配置是纯文本，一行一项，`#` 开头是注释：
///
///   local_only = true          # 只允许本机（回环地址）访问
///   allow = 192.168.1.20, .21  # 额外放行；留空表示不放行任何外部地址
///
/// 白名单现在是「精确 IP 或前缀」，以后要扩成网段/令牌只要改这里。
pub struct Access {
  local_only : Bool
  allow : Array[String]
}

///|
/// 默认：允许所有地址（保持原有行为）。
pub fn Access::open() -> Access {
  { local_only: false, allow: [], }
}

///|
/// 有没有启用任何限制。
pub fn Access::restricted(self : Access) -> Bool {
  self.local_only || self.allow.length() > 0
}

///|
/// 去掉端口，只留地址部分。`[::1]:8930` → `::1`，`1.2.3.4:80` → `1.2.3.4`
pub fn peer_ip(peer : String) -> String {
  if peer.has_prefix("[") {
    match peer.find("]") {
      Some(i) => return peer[i + 1:].to_owned()
      None => return peer
    }
  }
  // 从右往左找最后一个冒号（IPv6 没有端口时不该截断，这里只处理带端口的常见情形）
  let mut cut = -1
  let mut i = 0
  while i < peer.length() {
    if peer[i] == ':' {
      cut = i
    }
    i = i + 1
  }
  if cut > 0 && peer[:cut].find(":") is None {
    return peer[:cut].to_owned()
  }
  peer
}

///|
/// 回环地址：IPv4 的 127.0.0.0/8 与 IPv6 的 ::1。
pub fn is_loopback(ip : String) -> Bool {
  if ip == "::1" || ip == "0:0:0:0:0:0:0:1" {
    return true
  }
  ip.has_prefix("127.")
}

///|
/// 这条连接能不能访问。
pub fn Access::allows(self : Access, peer : String) -> Bool {
  if !self.restricted() {
    return true
  }
  let ip = peer_ip(peer)
  if is_loopback(ip) {
    return true
  }
  // 白名单：完整地址，或 `.` 结尾/开头的短前缀
  for rule in self.allow {
    let r : String = rule.trim().to_owned()
    if r == "" {
      continue
    }
    if ip == r || (ip.has_prefix(r) && r.has_suffix(".")) {
      return true
    }
  }
  false
}

///|
/// 解析配置文件内容。坏行直接忽略，不让配置把服务拦死。
pub fn parse_access(text : String) -> Access {
  let mut local_only = false
  let allow : Array[String] = []
  for line in text.split("\n") {
    let s = line.trim()
    if s == "" || s.has_prefix("#") {
      continue
    }
    match s.find("=") {
      None => ()
      Some(eq) => {
        let key : String = s[:eq].trim().to_owned()
        let value : String = s[eq + 1:].trim().to_owned()
        if key == "local_only" {
          local_only = value == "true" || value == "1" || value == "yes"
        } else if key == "allow" {
          for item in value.split(",") {
            let t : String = item.trim().to_owned()
            if t != "" {
              allow.push(t)
            }
          }
        }
      }
    }
  }
  { local_only, allow, }
}

///|
/// 读配置文件；文件不存在就用默认（不限制）。
pub async fn load_access(path : String) -> Access {
  let exists = @fs.exists(path) catch { _ => false }
  if !exists {
    return Access::open()
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
  if !self.restricted() {
    return "不限"
  }
  let parts : Array[String] = []
  if self.local_only {
    parts.push("仅本机")
  }
  if self.allow.length() > 0 {
    parts.push("白名单 " + self.allow.join(","))
  }
  parts.join(" + ")
}
