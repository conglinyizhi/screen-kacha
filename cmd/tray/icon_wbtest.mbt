///|
test "状态灯颜色按健康状态选" {
  assert_eq(lamp_color(""), 0xFF808080)
  assert_eq(lamp_color("{\"ok\": true, \"count\": 5}"), 0xFF3FBF5F)
  assert_eq(lamp_color("{\"ok\": false, \"count\": 0}"), 0xFFE0B020)
  assert_eq(
    lamp_color("{\"ok\": false, \"count\": 3, \"fails\": 2}"),
    0xFFE04040,
  )
}

///|
test "图标尺寸与字节数" {
  let icon = render_icon(22, 0xFF3FBF5F)
  assert_eq(icon.width, 22)
  assert_eq(icon.height, 22)
  assert_eq(icon.argb.length(), 22 * 22 * 4)
  let big = render_icon(44, 0xFF3FBF5F)
  assert_eq(big.argb.length(), 44 * 44 * 4)
}

///|
test "灯的位置是灯色、屏幕边框是前景色、角落透明" {
  let lamp = 0xFF3FBF5F
  assert_eq(icon_color(17, 16, lamp), lamp)
  assert_eq(icon_color(2, 3, lamp), 0xFFD8D8D8)
  assert_eq(icon_color(0, 0, lamp), 0)
  assert_eq(icon_color(21, 0, lamp), 0)
}

///|
/// 改写配置时必须保留用户自己写的东西。
///
/// 原来是整文件重写（只留三行），用户手写的注释和 allow 名单
/// 会在一次点击里全没。allow 名单是真有用的配置，不是垃圾。
test "rewrite_flags 保留注释和 allow 名单" {
  let old = "# 我的注释\nallow_lan = true\nallow_public = false\nallow = 10.0.0.5, 192.168.1.7\n"
  let out = rewrite_flags(Some(old), false, true, false)
  assert_true(out.contains("# 我的注释"))
  assert_true(out.contains("allow = 10.0.0.5, 192.168.1.7"))
  assert_true(out.contains("allow_lan = false"))
  assert_true(out.contains("allow_public = true"))
  // 旧的两个值不能残留
  assert_false(out.contains("allow_lan = true"))
  assert_false(out.contains("allow_public = false"))
}

///|
test "rewrite_flags 在空配置上补出三行" {
  let out = rewrite_flags(None, true, false, false)
  assert_true(out.contains("allow_lan = true"))
  assert_true(out.contains("allow_public = false"))
  assert_true(out.contains("allow_cgnat = false"))
}

///|
test "rewrite_flags 能改 allow_cgnat，并保留旧的取值" {
  let old = "allow_lan = true\nallow_cgnat = false\n"
  let out = rewrite_flags(Some(old), true, false, true)
  assert_true(out.contains("allow_cgnat = true"))
  assert_false(out.contains("allow_cgnat = false"))
  // 再改回去
  let back = rewrite_flags(Some(out), true, false, false)
  assert_true(back.contains("allow_cgnat = false"))
}

///|
test "rewrite_flags 不动未知键" {
  let old = "allow_lan = true\nallow = 10.1.2.3\nfuture_key = whatever\n"
  let out = rewrite_flags(Some(old), true, true, false)
  assert_true(out.contains("allow = 10.1.2.3"))
  assert_true(out.contains("future_key = whatever"))
  assert_true(out.contains("allow_public = true"))
}

///|
test "rewrite_flags 容忍键名和等号之间有空格" {
  let out = rewrite_flags(Some("allow_lan=true\n"), false, false, false)
  assert_true(out.contains("allow_lan = false"))
  // 只有一行 allow_lan，不该重复追加
  let count = out.split("\n").filter(fn(l) { l.contains("allow_lan") }).count()
  assert_eq(count, 1)
}

///|
test "rewrite_flags 不把 allow 前缀的未知键当成 allow_lan" {
  // `allow_local` 这种键不该被误改成 allow_lan
  let out = rewrite_flags(Some("allow_local = yes\n"), true, false, false)
  assert_true(out.contains("allow_local = yes"))
}
