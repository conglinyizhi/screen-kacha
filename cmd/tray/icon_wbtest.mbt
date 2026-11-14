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
