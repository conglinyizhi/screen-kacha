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
