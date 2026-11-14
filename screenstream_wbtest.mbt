///|
test "原图路径" {
  inspect(parse_snapshot("snapshot.jpg") is Some((None, "jpg")), content="true")
  inspect(
    parse_snapshot("snapshot.webp") is Some((None, "webp")),
    content="true",
  )
}

///|
test "带宽度的路径" {
  inspect(
    parse_snapshot("snapshot-1280.jpg") is Some((Some(1280), "jpg")),
    content="true",
  )
  inspect(
    parse_snapshot("snapshot-640.webp") is Some((Some(640), "webp")),
    content="true",
  )
}

///|
test "不合法路径一律 None" {
  inspect(parse_snapshot("snapshot.jpgx") is None, content="true")
  inspect(parse_snapshot("nope.jpg") is None, content="true")
  inspect(parse_snapshot("snapshot-abc.jpg") is None, content="true")
  inspect(parse_snapshot("snapshot-.jpg") is None, content="true")
  inspect(parse_snapshot("snapshot-123456.jpg") is None, content="true")
  inspect(parse_snapshot("snapshot-12a4.jpg") is None, content="true")
}

///|
test "宽度夹取" {
  inspect(clamp_width(Some(100)) is Some(160), content="true")
  inspect(clamp_width(Some(9999)) is Some(3840), content="true")
  inspect(clamp_width(Some(1280)) is Some(1280), content="true")
  inspect(clamp_width(None) is None, content="true")
}

///|
test "解析 age 秒数：整数" {
  inspect(parse_seconds_ms("5") is Some(5000L), content="true")
  inspect(parse_seconds_ms("0") is Some(0L), content="true")
  inspect(parse_seconds_ms("60") is Some(60000L), content="true")
}

///|
test "解析 age 秒数：小数" {
  inspect(parse_seconds_ms("0.4") is Some(400L), content="true")
  inspect(parse_seconds_ms("0.05") is Some(50L), content="true")
  inspect(parse_seconds_ms("1.25") is Some(1250L), content="true")
}

///|
test "解析 age 秒数：非法输入返回 None" {
  inspect(parse_seconds_ms("") is None, content="true")
  inspect(parse_seconds_ms("abc") is None, content="true")
  inspect(parse_seconds_ms("1.2.3") is None, content="true")
  inspect(parse_seconds_ms("1a") is None, content="true")
  inspect(parse_seconds_ms("-1") is None, content="true")
}

///|
test "解析查询参数宽度" {
  inspect(parse_width("1280") is Some(1280), content="true")
  inspect(parse_width("160") is Some(160), content="true")
  inspect(parse_width("") is None, content="true")
  inspect(parse_width("12a") is None, content="true")
  inspect(parse_width("123456") is None, content="true")
}
