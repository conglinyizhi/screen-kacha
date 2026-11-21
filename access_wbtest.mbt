///|
test "peer_ip 去掉端口" {
  assert_eq(peer_ip("192.168.1.21:8930"), "192.168.1.21")
  assert_eq(peer_ip("[::1]:8930"), "::1")
  assert_eq(peer_ip("::1"), "::1")
  assert_eq(peer_ip("127.0.0.1:80"), "127.0.0.1")
}

///|
test "回环永远放行" {
  let closed : Access = { allow_lan: false, allow_public: false, allow: [], }
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
