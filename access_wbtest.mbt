///|
test "peer_ip 去掉端口" {
  assert_eq(peer_ip("192.168.1.21:8930"), "192.168.1.21")
  assert_eq(peer_ip("[::1]:8930"), "::1")
  assert_eq(peer_ip("::1"), "::1")
  assert_eq(peer_ip("127.0.0.1:80"), "127.0.0.1")
}

///|
test "回环永远放行" {
  let closed : Access = {
    allow_lan: false,
    allow_public: false,
    allow_cgnat: false,
    allow: [],
  }
  assert_true(closed.allows("127.0.0.1:5000"))
  assert_true(closed.allows("[::1]:5000"))
}

///|
test "局域网判定" {
  assert_true(is_lan("10.1.2.3"))
  assert_true(is_lan("172.16.0.1"))
  assert_true(is_lan("172.31.255.255"))
  assert_false(is_lan("172.32.0.1"))
  assert_true(is_lan("192.168.1.21"))
  assert_false(is_lan("8.8.8.8"))
  assert_false(is_lan("garbage"))
}

///|
test "两档开关的实际行为" {
  // 默认：局域网放行、公网不放行
  let d = Access::default()
  assert_true(d.allows("192.168.1.20:1234"))
  assert_false(d.allows("8.8.8.8:1234"))
  // 全关
  let only_local = parse_access("allow_lan = false\nallow_public = false\n")
  assert_false(only_local.allows("192.168.1.20:1"))
  assert_true(only_local.allows("127.0.0.1:1"))
  // 全开
  let open = parse_access("allow_lan = false\nallow_public = true\n")
  assert_true(open.allows("8.8.8.8:1"))
  // 名单单独放行
  let listed = parse_access(
    "allow_lan = false\nallow_public = false\nallow = 192.168.1.20\n",
  )
  assert_true(listed.allows("192.168.1.20:1"))
  assert_false(listed.allows("192.168.1.21:1"))
}

///|
test "老配置 local_only 仍然生效" {
  let a = parse_access("local_only = true\n")
  assert_false(a.allows("192.168.1.20:1"))
  assert_true(a.allows("127.0.0.1:1"))
}

///|
test "100.64/10 的边界" {
  // 运营商级 NAT 段，边界是 100.64 到 100.127。
  // Tailscale 这类工具会把地址落在这里，公网上也确实分配过这一段。
  assert_false(is_cgnat("100.63.255.255"))
  assert_true(is_cgnat("100.64.0.0"))
  assert_true(is_cgnat("100.64.0.1"))
  assert_true(is_cgnat("100.127.255.255"))
  assert_false(is_cgnat("100.128.0.0"))
  assert_false(is_cgnat("10.0.0.1"))
  assert_false(is_cgnat("192.168.1.1"))
  assert_false(is_cgnat("::1"))
  assert_false(is_cgnat("garbage"))
  assert_false(is_cgnat("100.64.0"))
}

///|
test "100.64/10 默认不算局域网" {
  let d = Access::default()
  assert_false(d.allow_cgnat)
  assert_false(d.allows("100.64.1.2:1234"))
}

///|
test "打开额外豁免后跟着局域网开关走" {
  let a = parse_access("allow_lan = true\nallow_cgnat = true\n")
  assert_true(a.allow_cgnat)
  assert_true(a.allows("100.64.1.2:1234"))
  // 跟着 allow_lan，不是无条件放行
  let b = parse_access("allow_lan = false\nallow_cgnat = true\n")
  assert_false(b.allows("100.64.1.2:1234"))
  // 公网段不受这个开关影响
  assert_false(a.allows("8.8.8.8:1234"))
  // 真正的局域网也不受影响
  assert_true(a.allows("192.168.1.20:1234"))
}

///|
test "描述里标出额外豁免" {
  assert_true(
    parse_access("allow_cgnat = true\n").describe().contains("100.64/10"),
  )
  assert_false(parse_access("").describe().contains("100.64/10"))
}

///|
/// key 要按完整名字取，注释和空行不算。
///
/// 托盘原来是前缀匹配：`allow_lan_next = false` 会被改写成
/// `allow_lan = <值>`，而服务端只认 key 完全相等的行。
test "config_line_key 取完整 key" {
  assert_eq(config_line_key("allow_lan = true"), Some("allow_lan"))
  assert_eq(config_line_key("  allow = 1.2.3.4 "), Some("allow"))
  assert_eq(config_line_key("allow_lan_next = false"), Some("allow_lan_next"))
  assert_true(config_line_key("# allow_lan = true") is None)
  assert_true(config_line_key("") is None)
  assert_true(config_line_key("没有等号") is None)
}

///|
/// 布尔值大小写不敏感。
///
/// 原来只认全小写，`allow_public = True` 会被静默当成 false：
/// 用户以为放开了，实际没开，而且没有任何提示。
test "布尔值解析大小写不敏感" {
  assert_true(parse_flag_value("true"))
  assert_true(parse_flag_value("True"))
  assert_true(parse_flag_value("TRUE"))
  assert_true(parse_flag_value(" yes "))
  assert_true(parse_flag_value("1"))
  assert_true(parse_flag_value("On"))
  assert_false(parse_flag_value("false"))
  assert_false(parse_flag_value("False"))
  assert_false(parse_flag_value("0"))
  assert_false(parse_flag_value("乱写"))
}

///|
/// local_only 要按值处理，托盘和服务端得是同一个结论。
///
/// 原来不看值：`local_only = false` 也被当成两档全关，而托盘根本不认这个键，
/// 显示的是「放行局域网」。
test "local_only 按值生效" {
  let on = parse_access("local_only = true\n")
  assert_false(on.allow_lan)
  assert_false(on.allow_public)
  // false 就当没写，不能把开关关掉
  let off = parse_access("local_only = false\n")
  assert_true(off.allow_lan)
  assert_false(off.allow_public)
}

///|
/// 废弃键和拼错的键都要能被指出来。
test "配置警告能指出废弃键和未知键" {
  let warns = config_warnings(
    "# 注释\nallow_lan = true\nlocal_only = true\nalow_lan = false\n",
  )
  let joined = warns.join("|")
  assert_true(joined.contains("local_only 已废弃"))
  assert_true(joined.contains("alow_lan"))
  // 正常的键不该报警
  let clean = config_warnings("allow_lan = true\nallow_public = false\nallow = 10.0.0.1\n")
  assert_eq(clean.length(), 0)
}
