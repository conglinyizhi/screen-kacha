///|
/// 一块归一化矩形：四个分量都按边长比例算，范围 0..1。
///
/// 用比例而不是像素，是因为调用方（agent）通常不知道屏幕分辨率；
/// 视觉模型给出的框本来也是归一化的。
pub struct Region {
  x : Double
  y : Double
  w : Double
  h : Double
}

///|
/// 数值比较的容差。`0.1 + 0.9` 在浮点下不总等于 1，卡太死会把合法输入拒掉。
const REGION_EPS : Double = 1.0e-9

///|
/// 解析一块矩形：`x,y,w,h`，四个分量都支持两种写法。
///
/// - `0.1`  小数，按边长比例
/// - `10%`  百分号，等价于 0.1
///
/// 不接受像素：`1` 到底是 1 像素还是整屏，这种歧义迟早会咬人。
/// 任何一处不合法就整体拒绝，不做「尽量猜」—— 猜错的矩形裁出来图是错的，
/// 比返回一个明确的错误更糟。
pub fn parse_region(s : String) -> Region? {
  let sv : StringView = s
  // 先卡长度和段数：后面的逐字符解析不能跑在任意长的输入上
  if sv.length() == 0 || sv.length() > 64 {
    return None
  }
  let parts : Array[StringView] = sv.split(",").collect()
  if parts.length() != 4 {
    return None
  }
  let x = parse_region_part(parts[0])
  let y = parse_region_part(parts[1])
  let w = parse_region_part(parts[2])
  let h = parse_region_part(parts[3])
  match (x, y, w, h) {
    (Some(x), Some(y), Some(w), Some(h)) => {
      if x < 0.0 || x > 1.0 || y < 0.0 || y > 1.0 {
        return None
      }
      if w <= 0.0 || w > 1.0 || h <= 0.0 || h > 1.0 {
        return None
      }
      // 越界的框整体拒绝，不在这里悄悄夹紧：夹紧等于改了用户要的区域
      if x + w > 1.0 + REGION_EPS || y + h > 1.0 + REGION_EPS {
        return None
      }
      Some({ x, y, w, h })
    }
    _ => None
  }
}

///|
/// 解析一个分量：`0.5` 或 `50%`。空串、负数、非有限值、多余字符都返回 None。
fn parse_region_part(raw : StringView) -> Double? {
  // 允许前后空格：从查询串里抠出来时容易残留
  let t = raw.trim()
  if t.length() == 0 || t.length() > 16 {
    return None
  }
  let percent = t.has_suffix("%")
  let body = if percent { t[:t.length() - 1] } else { t }
  if body.length() == 0 {
    return None
  }
  let d = try {
    Some(@string.parse_double(body))
  } catch {
    _ => None
  }
  match d {
    None => None
    Some(d) =>
      // NaN / Inf 一律挡掉：后面要拿它做乘法和取整
      if d.is_nan() || d.is_inf() || d < 0.0 {
        None
      } else {
        Some(if percent { d / 100.0 } else { d })
      }
  }
}

///|
/// 输出宽度的上限。再大没有意义，而且会让编码那边分配很大一块内存。
const DST_W_MAX : Int32 = 4096

///|
/// 解析 `?w=` / MCP 的 `width`：只接受十进制正整数，超出范围或带杂物就拒绝。
pub fn parse_dst_w(raw : String) -> Int32? {
  let sv : StringView = raw
  if sv.length() == 0 || sv.length() > 5 {
    return None
  }
  let mut i = 0
  let mut v : Int32 = 0
  while i < sv.length() {
    let c = sv[i].to_int()
    if c < 48 || c > 57 {
      return None
    }
    v = v * 10 + (c - 48)
    if v > DST_W_MAX {
      return None
    }
    i = i + 1
  }
  if v < 1 {
    return None
  }
  Some(v)
}
