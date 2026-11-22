///|
/// 托盘改配置只动完整 key 的那几行。
///
/// 原来是 `has_prefix("allow_lan")`：`allow_lan_next = false` 这种未知键会被
/// 改写成 `allow_lan = <值>`，而服务端只认 key 完全相等的行，两边就对不上。
test "rewrite_flags 只改完整 key" {
  let old = "# 注释\nallow_lan = true\nallow_lan_next = false\nallow = 10.0.0.1\n"
  let out = rewrite_flags(Some(old), false, false, true)
  // 该改的改了
  assert_true(out.contains("allow_lan = false"))
  assert_true(out.contains("allow_cgnat = true"))
  // 未知键原样保留，没有被吃成 allow_lan
  assert_true(out.contains("allow_lan_next = false"))
  // 注释和名单也保留
  assert_true(out.contains("# 注释"))
  assert_true(out.contains("allow = 10.0.0.1"))
}

///|
/// 缺的键要补在末尾，不能一个都不写。
test "rewrite_flags 补齐缺的键" {
  let out = rewrite_flags(None, true, false, false)
  assert_true(out.contains("allow_lan = true"))
  assert_true(out.contains("allow_public = false"))
  assert_true(out.contains("allow_cgnat = false"))
}

///|
/// 托盘那份 key 提取要和服务端同一套规则。
test "config_key 与服务端规则一致" {
  assert_eq(config_key("allow_lan = true"), Some("allow_lan"))
  assert_eq(config_key("  allow_public=false  "), Some("allow_public"))
  assert_true(config_key("# 注释") is None)
  assert_true(config_key("") is None)
}

///|
/// 写配置文件走的是「先写 .tmp 再 rename」，写完不能留下半截文件或临时文件。
///
/// 原来是 fopen(path,"w") 直接截断：写完之前主服务读到半截会让
/// parse_access 退回默认值（默认 allow_lan = true），安全开关翻到放开那一侧。
test "写配置不留临时文件，内容完整" {
  let path = "/tmp/tray-cfg-test/access.conf"
  assert_true(write_file(path, "allow_lan = false\nallow_public = false\n"))
  // 临时文件必须已经 rename 掉（capture_whole 读不到时给空串）
  assert_eq(capture_whole("\{path}.tmp"), Some(""))
  // 内容要完整
  assert_eq(
    capture_whole(path),
    Some("allow_lan = false\nallow_public = false\n"),
  )
}
