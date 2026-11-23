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
