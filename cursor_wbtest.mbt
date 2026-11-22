///|
test "parse_cursor 只认 0/1/2/3/4" {
  // 1/2 是新版（无尾巴），3/4 是旧版（带尾巴）
  assert_true(parse_cursor(Some("1")) is Some({ style: Soft, classic: false, }))
  assert_true(parse_cursor(Some("2")) is Some({ style: Neg, classic: false, }))
  assert_true(parse_cursor(Some("3")) is Some({ style: Soft, classic: true, }))
  assert_true(parse_cursor(Some("4")) is Some({ style: Neg, classic: true, }))
  // 不带参数 = 默认（当前不画）
  assert_true(parse_cursor(None) is None)
  // 0 显式关掉
  assert_true(parse_cursor(Some("0")) is None)
  // 越界和乱写的值都不画
  assert_true(parse_cursor(Some("5")) is None)
  assert_true(parse_cursor(Some("-1")) is None)
  assert_true(parse_cursor(Some("soft")) is None)
  assert_true(parse_cursor(Some("")) is None)
  // 前后空白不算错
  assert_true(
    parse_cursor(Some("  2  ")) is Some({ style: Neg, classic: false, }),
  )
}

///|
test "两套素材的文件名分得开" {
  // 尺寸由 C 侧从 PNG 头里读，这里只管用的是哪一套
  let (a1, m1) = ({ style: Soft, classic: false, } : Cursor).assets()
  let (a2, m2) = ({ style: Soft, classic: true, } : Cursor).assets()
  assert_false(a1.contains("classic"))
  assert_false(m1.contains("classic"))
  assert_true(a2.contains("classic"))
  assert_true(m2.contains("classic"))
}

///|
test "每套素材里软边和负片用的文件名不一样" {
  let (arrow_new, mask_new) = ({ style: Soft, classic: false, } : Cursor).assets()
  let (arrow_new_neg, mask_new_neg) = ({ style: Neg, classic: false, } : Cursor).assets()
  assert_true(arrow_new.has_prefix("cursor-arrow"))
  assert_true(mask_new.has_prefix("cursor-mask"))
  // 负片只用蒙版去裁，不需要箭头图
  assert_true(arrow_new_neg.has_prefix("cursor-mask"))
  assert_eq(mask_new, mask_new_neg)

  let (arrow_old, mask_old) = ({ style: Soft, classic: true, } : Cursor).assets()
  assert_true(arrow_old.contains("classic"))
  assert_true(mask_old.contains("classic"))
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
