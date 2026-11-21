///|
test "parse_cursor 只认 0/1/2" {
  assert_true(parse_cursor(Some("1")) is Some(Soft))
  assert_true(parse_cursor(Some("2")) is Some(Neg))
  // 不带参数 = 默认（当前不画）
  assert_true(parse_cursor(None) is None)
  // 0 显式关掉
  assert_true(parse_cursor(Some("0")) is None)
  // 以前认的别名、乱写的值，现在都不认 —— 收敛成三个值，
  // 写错了就安静地不画，比猜一个更安全
  assert_true(parse_cursor(Some("soft")) is None)
  assert_true(parse_cursor(Some("neg")) is None)
  assert_true(parse_cursor(Some("invert")) is None)
  assert_true(parse_cursor(Some("on")) is None)
  assert_true(parse_cursor(Some("")) is None)
  // 前后空白不算错
  assert_true(parse_cursor(Some("  2  ")) is Some(Neg))
}

///|
test "cursor_args 两种样式的参数形状" {
  let soft = cursor_args(
    Soft,
    "in.jpg",
    "out.jpg",
    10,
    20,
    "a.png",
    "m.png",
    None,
  )
  // 半透明：直接把箭头贴上去
  assert_true(soft.contains("a.png"))
  assert_false(soft.contains("+clone"))
  assert_true(soft.contains("+10+20"))
  // 负片：要裁剪+反色+蒙版
  let neg = cursor_args(
    Neg,
    "in.jpg",
    "out.jpg",
    10,
    20,
    "a.png",
    "m.png",
    None,
  )
  assert_true(neg.contains("+clone"))
  assert_true(neg.contains("-negate"))
  assert_true(neg.contains("CopyOpacity"))
  assert_true(neg.contains("m.png"))
  // 带宽度时最后要缩放
  let scaled = cursor_args(
    Soft,
    "in.jpg",
    "out.jpg",
    0,
    0,
    "a.png",
    "m.png",
    Some(640),
  )
  assert_true(scaled.contains("-resize"))
  assert_true(scaled.contains("640x"))
}
