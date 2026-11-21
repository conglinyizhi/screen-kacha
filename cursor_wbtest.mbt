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

///|
/// 负坐标必须整条拒绝。
///
/// 这条曾经真的坏了：`-` 被当普通分隔符，`-300 400` 解析成 (300, 400)，
/// 箭头画到镜像位置。多屏时副屏在主屏左边/上边，KWin 给的坐标必然是负数 ——
/// 这是常态不是异常，画错位置比不画更误导。
test "含负号的坐标一律拒绝" {
  assert_true(parse_cursor_pos_text("-300 400") is None)
  assert_true(parse_cursor_pos_text("300 -400") is None)
  assert_true(parse_cursor_pos_text("-1 -1") is None)
}

///|
test "正常坐标能解析出来" {
  assert_eq(parse_cursor_pos_text("1638 355"), Some((1638, 355)))
  assert_eq(parse_cursor_pos_text("0 0"), Some((0, 0)))
  assert_eq(parse_cursor_pos_text("  1920   1080  "), Some((1920, 1080)))
}

///|
test "缺项、空文件、垃圾内容都拒绝" {
  assert_true(parse_cursor_pos_text("") is None)
  assert_true(parse_cursor_pos_text("123") is None)
  assert_true(parse_cursor_pos_text("abc") is None)
  assert_true(parse_cursor_pos_text("12x 34") is None)
}

///|
test "超大数值不溢出回绕成正数" {
  // Int32 回绕可能把 429496729600 变成一个小正数，那样会画到随机位置
  assert_true(parse_cursor_pos_text("999999999999 1") is None)
}
