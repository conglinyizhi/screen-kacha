///|
test "parse_int：正常、空串与非法字符" {
  assert_eq(parse_int("18940", 0), 18940)
  assert_eq(parse_int("0", 7), 0)
  assert_eq(parse_int("", 7), 7)
  assert_eq(parse_int("12a", 7), 7)
  assert_eq(parse_int("--1", 7), 7)
}

///|
test "pick：取到值、回落默认、未知键" {
  let cmd = cli_cmd()
  let m = cmd.parse(argv=["--port", "9999", "--idle", "0"])
  assert_eq(pick(m, "port", "1"), "9999")
  assert_eq(pick(m, "idle", "20"), "0")
  assert_eq(pick(m, "bind", "0.0.0.0"), "0.0.0.0")
  assert_eq(pick(m, "nope", "dflt"), "dflt")
}

///|
test "cli_cmd：五个选项都有默认值" {
  let cmd = cli_cmd()
  let m = cmd.parse(argv=[])
  assert_eq(pick(m, "port", ""), "18940")
  assert_eq(pick(m, "bind", ""), "0.0.0.0")
  assert_eq(pick(m, "idle", ""), "20")
  assert_eq(pick(m, "shm", ""), "/tmp/screenstream-mb")
  assert_eq(pick(m, "max-conns", ""), "64")
}

///|
/// 启动横幅要陈述「谁能取图」，不能把「局域网放行」包装成「访问控制：启用」。
///
/// 原来那行的判据是 `allow_public`，局域网放行也走「启用」分支，读起来像
/// 已经有一层防护，其实同网段任何设备都能取整屏。
test "启动横幅只说事实，不说「启用」" {
  let lan = @store.parse_access("allow_lan = true\nallow_public = false")
  let lines = access_banner(lan, "0.0.0.0", 8930)
  assert_true(lines[0].has_prefix("允许来源："))
  let text = lines.join("\n")
  assert_false(text.contains("启用"))
  // 必须点明放行的是整个网段，不是只有自己的设备
  assert_true(text.contains("整个局域网网段"))
  // 全放行要给更直白的警示
  let open = @store.parse_access("allow_public = true")
  assert_true(
    access_banner(open, "0.0.0.0", 8930).join("\n").contains("都能取整屏"),
  )
  // 仅本机时不啰嗦，只留一行
  let solo = @store.parse_access("allow_lan = false\nallow_public = false")
  let solo_lines = access_banner(solo, "127.0.0.1", 8930)
  assert_eq(solo_lines.length(), 1)
  assert_true(solo_lines[0].contains("仅本机"))
}

///|
/// 清理陈旧原始帧要用文件名前缀，得能正确取出最后一段。
test "base_name 取路径最后一段" {
  assert_eq(base_name("/run/user/1000/screenstream/latest.jpg"), "latest.jpg")
  assert_eq(base_name("latest.jpg"), "latest.jpg")
  assert_eq(base_name("/a/b/c.png"), "c.png")
  assert_eq(base_name("/"), "")
  assert_eq(base_name(""), "")
}
