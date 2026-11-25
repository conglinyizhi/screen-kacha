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
  let clean = config_warnings(
    "allow_lan = true\nallow_public = false\nallow = 10.0.0.1\n",
  )
  assert_eq(clean.length(), 0)
}

///|
async test "访问控制配置不存在时使用兼容默认策略" {
  let loaded : Access? = load_access("/tmp/ssmb-missing-access-config")
  match loaded {
    Some(access) => {
      assert_true(access.allows("192.168.1.2:8930"))
      assert_false(access.allows("8.8.8.8:8930"))
    }
    None => fail("缺失配置应返回默认策略")
  }
}

///|
async test "访问控制配置读取失败时不返回默认放行策略" {
  let path = "/tmp/ssmb-access-config-is-directory"
  @fs.mkdir(path, recursive=true) catch { _ => () }
  let loaded : Access? = load_access(path)
  @fs.remove(path) catch { _ => () }
  assert_true(loaded is None)
}

///|
/// IPv4-mapped 地址要还原成 IPv4 再判定。
///
/// `--bind [::]` 时 IPv4 客户端连进来对端就是 `::ffff:192.168.1.5` 这种写法。
/// 不还原的话它既不是回环也不是局域网，本机用 127.0.0.1 都会被 403。
test "IPv4-mapped 地址按 IPv4 判定" {
  assert_eq(unmap_ipv4("::ffff:192.168.1.5"), "192.168.1.5")
  assert_eq(unmap_ipv4("0:0:0:0:0:ffff:10.0.0.1"), "10.0.0.1")
  assert_eq(unmap_ipv4("192.168.1.5"), "192.168.1.5")
  // 走 peer_ip 那条完整路径
  assert_eq(peer_ip("[::ffff:192.168.1.5]:8930"), "192.168.1.5")
  assert_true(is_loopback("::ffff:127.0.0.1"))
  assert_true(is_lan("::ffff:192.168.1.5"))
  assert_true(is_cgnat("::ffff:100.64.0.1"))
}

///|
/// fe80::/10 是 fe80–febf，不是只有 fe80 开头。
test "链路本地覆盖整个 fe80::/10" {
  assert_true(is_lan("fe80::1"))
  assert_true(is_lan("fe90::1"))
  assert_true(is_lan("fea0::1"))
  assert_true(is_lan("febf::1"))
  // fec0::/10 是旧的 site-local，不算链路本地
  assert_false(is_lan("fec0::1"))
  // ULA 仍然认
  assert_true(is_lan("fc00::1"))
  assert_true(is_lan("fd12:3456::1"))
}
