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
