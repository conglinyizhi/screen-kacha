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
test "两套素材的尺寸各不相同，且和文件对得上" {
  // 新版 29x41，旧版 29x40 —— 负片要按这个尺寸裁，
  // 混用会差一行、边缘错位，所以专门锁一下
  let (_, _, w1, h1) = ({ style: Soft, classic: false, } : Cursor).assets()
  let (_, _, w2, h2) = ({ style: Soft, classic: true, } : Cursor).assets()
  assert_eq((w1, h1), (29, 41))
  assert_eq((w2, h2), (29, 40))
  assert_true(h1 != h2)
}

///|
test "每套素材里软边和负片用的文件名不一样" {
  let (arrow_new, mask_new, _, _) = ({ style: Soft, classic: false, } : Cursor).assets()
  let (arrow_new_neg, mask_new_neg, _, _) = (
    { style: Neg, classic: false, } : Cursor).assets()
  assert_true(arrow_new.has_prefix("cursor-arrow"))
  assert_true(mask_new.has_prefix("cursor-mask"))
  // 负片只用蒙版去裁，不需要箭头图
  assert_true(arrow_new_neg.has_prefix("cursor-mask"))
  assert_eq(mask_new, mask_new_neg)

  let (arrow_old, mask_old, _, _) = ({ style: Soft, classic: true, } : Cursor).assets()
  assert_true(arrow_old.contains("classic"))
  assert_true(mask_old.contains("classic"))
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
    29,
    41,
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
    29,
    41,
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
    29,
    41,
    Some(640),
  )
  assert_true(scaled.contains("-resize"))
  assert_true(scaled.contains("640x"))
  // 负片的 crop 尺寸必须来自参数，跟素材走。写死成常量的话，
  // 换素材（29x41 / 29x40）就会差一行，边缘错位。
  let neg44 = cursor_args(
    Neg,
    "in.jpg",
    "out.jpg",
    7,
    9,
    "a.png",
    "m.png",
    29,
    40,
    None,
  )
  assert_true(neg44.contains("29x40+7+9"))
  let neg41 = cursor_args(
    Neg,
    "in.jpg",
    "out.jpg",
    7,
    9,
    "a.png",
    "m.png",
    29,
    41,
    None,
  )
  assert_true(neg41.contains("29x41+7+9"))
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
