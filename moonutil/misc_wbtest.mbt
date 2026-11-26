///|
test "cstr 补结尾 0" {
  let b = cstr("ab")
  assert_eq(b.length(), 3)
  assert_eq(b[0].to_int(), 97)
  assert_eq(b[1].to_int(), 98)
  assert_eq(b[2].to_int(), 0)
  // 空串也要有那个 0
  assert_eq(cstr("").length(), 1)
}

///|
test "parse_int 严格" {
  assert_eq(parse_int("18940", 0), 18940)
  assert_eq(parse_int("0", 7), 0)
  assert_eq(parse_int("", 7), 7)
  assert_eq(parse_int("12a", 7), 7)
  assert_eq(parse_int("--1", 7), 7)
  assert_eq(parse_int("-1", 7), 7)
}

///|
test "pick 取值与回落" {
  let cmd = @argparse.Command("t", options=[
    @argparse.OptionArg("port", default_values=["1"]),
  ])
  let m = cmd.parse(argv=["--port", "9999"])
  assert_eq(pick(m, "port", "1"), "9999")
  assert_eq(pick(m, "nope", "dflt"), "dflt")
}

///|
test "b64_encode 三种尾巴" {
  // 3 字节整组
  assert_eq(b64_encode(b"abc"), "YWJj")
  // 剩 1 字节补 ==
  assert_eq(b64_encode(b"a"), "YQ==")
  // 剩 2 字节补 =
  assert_eq(b64_encode(b"ab"), "YWI=")
  // 空
  assert_eq(b64_encode(b""), "")
}

///|
test "配置文件路径：认 XDG_CONFIG_HOME" {
  assert_eq(
    access_conf_path_with(Some("/tmp/xdg-cfg"), Some("/home/u")),
    "/tmp/xdg-cfg/screen-kacha/access.conf",
  )
  assert_eq(
    access_conf_path_with(None, Some("/home/u")),
    "/home/u/.config/screen-kacha/access.conf",
  )
  // 两个都没有时退到系统级路径，这个是有意的
  assert_eq(access_conf_path_with(None, None), "/etc/screen-kacha/access.conf")
}

///|
test "RuntimePaths 统一解析 state config 和 runtime 路径" {
  let paths = runtime_paths_with(
    Some("/xdg/state"),
    Some("/xdg/config"),
    Some("/run/user/4242"),
    Some("/home/u"),
    1000,
  )
  assert_eq(paths.state_dir, Some("/xdg/state/screen-kacha"))
  assert_eq(paths.access_conf, "/xdg/config/screen-kacha/access.conf")
  assert_eq(paths.runtime_dir, "/run/user/4242")
  assert_eq(paths.app_runtime_dir, "/run/user/4242/screen-kacha")
}

///|
test "RuntimePaths 用 HOME 和 UID 回退" {
  let paths = runtime_paths_with(None, None, None, Some("/home/u"), 4242)
  assert_eq(paths.state_dir, Some("/home/u/.local/state/screen-kacha"))
  assert_eq(paths.access_conf, "/home/u/.config/screen-kacha/access.conf")
  assert_eq(paths.runtime_dir, "/run/user/4242")
  assert_eq(paths.app_runtime_dir, "/run/user/4242/screen-kacha")
}

///|
test "RuntimePaths 不为缺失 HOME 编造用户目录" {
  let paths = runtime_paths_with(None, None, None, None, 0)
  assert_eq(paths.state_dir, None)
  assert_eq(paths.access_conf, "/etc/screen-kacha/access.conf")
  assert_eq(paths.runtime_dir, "/run/user/0")
}

///|
test "实例状态目录按实例名隔离" {
  assert_eq(
    instance_state_dir_with(
      Some("/xdg/state"),
      Some("/home/u"),
      Some("default"),
    ),
    Some("/xdg/state/screen-kacha"),
  )
  assert_eq(
    instance_state_dir_with(None, Some("/home/u"), Some("worker-2")),
    Some("/home/u/.local/state/screen-kacha/instances/worker-2"),
  )
  assert_eq(instance_state_dir_with(None, None, Some("default")), None)
  assert_eq(
    instance_state_dir_with(None, Some("/home/u"), Some("bad/name")),
    None,
  )
}

///|
test "布尔解析：大小写和空白都认" {
  assert_true(parse_flag("true"))
  assert_true(parse_flag("  TRUE "))
  assert_true(parse_flag("1"))
  assert_true(parse_flag("Yes"))
  assert_true(parse_flag("on"))
  assert_false(parse_flag("false"))
  assert_false(parse_flag("0"))
  assert_false(parse_flag(""))
  assert_false(parse_flag("enable"))
}
