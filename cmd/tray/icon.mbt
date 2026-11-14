///|
/// 状态灯颜色（ARGB）：绿=正常，黄=还没抓过，红=采集失败，灰=服务没响应。
fn lamp_color(health : String) -> Int32 {
  if health.length() == 0 {
    return 0xFF808080
  }
  if health.contains("\"ok\": true") {
    return 0xFF3FBF5F
  }
  if health.contains("\"count\": 0") {
    return 0xFFE0B020
  }
  0xFFE04040
}

///|
/// 22×22 网格上的一像素：显示器外框、支架、底座，右下角一个状态灯。
fn icon_color(x : Int32, y : Int32, lamp : Int32) -> Int32 {
  let fg = 0xFFD8D8D8
  // 状态灯：圆心 (17,16)，半径 3.2
  let dx = x * 10 - 170
  let dy = y * 10 - 160
  if dx * dx + dy * dy <= 1024 {
    return lamp
  }
  // 显示器外框
  if x >= 2 && x <= 19 && y >= 3 && y <= 14 {
    if x == 2 || x == 19 || y == 3 || y == 14 {
      return fg
    }
  }
  // 支架与底座
  if x >= 10 && x <= 11 && y >= 15 && y <= 16 {
    return fg
  }
  if x >= 7 && x <= 14 && y == 17 {
    return fg
  }
  0
}

///|
/// 按 22 网格放大到 size×size，输出 ARGB 字节流。
pub fn render_icon(size : Int32, lamp : Int32) -> @sni.PixelIcon {
  let s = if size >= 22 { size / 22 } else { 1 }
  let buf : Array[Byte] = []
  for py in 0..<size {
    for px in 0..<size {
      let c = icon_color(px / s, py / s, lamp)
      buf.push(((c >> 24) & 0xFF).to_byte())
      buf.push(((c >> 16) & 0xFF).to_byte())
      buf.push(((c >> 8) & 0xFF).to_byte())
      buf.push((c & 0xFF).to_byte())
    }
  }
  @sni.PixelIcon::make(size, size, Bytes::from_array(buf))
}

///|
/// 22 与 44 两个尺寸，KDE 按面板缩放自己挑。
pub fn icons_for(health : String) -> Array[@sni.PixelIcon] {
  let lamp = lamp_color(health)
  [render_icon(22, lamp), render_icon(44, lamp)]
}
