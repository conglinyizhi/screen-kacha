///|
test "原图路径" {
  inspect(parse_snapshot("snapshot.jpg") is Some((None, "jpg")), content="true")
  inspect(parse_snapshot("snapshot.webp") is Some((None, "webp")), content="true")
}

///|
test "带宽度的路径" {
  inspect(parse_snapshot("snapshot-1280.jpg") is Some((Some(1280), "jpg")), content="true")
  inspect(parse_snapshot("snapshot-640.webp") is Some((Some(640), "webp")), content="true")
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
