///|
/// 鼠标指针叠加：从 `cursor.pos` 读坐标，在帧上画一个箭头。
///
/// 坐标由 `screenstream-cursor` 进程写（KWin 脚本用 callDBus 喂给它）。
/// 这里只读文件，拿不到就不画 —— 缺了不该让整个请求失败。
///
/// 参数只有三个值：
///
/// - 不带 `cursor`：默认，当前是不画
/// - `0`：不画
/// - `1`：半透明白箭头带黑边，能看见底下的东西
/// - `2`：把箭头覆盖的像素反色，深浅背景都清楚，但会盖住内容

///|
/// 箭头素材的像素尺寸。负片要按这个尺寸裁剪底下的像素，
/// 所以它必须和 `cursor-mask.png` 一致，改素材时一起改。
const CURSOR_W : Int32 = 29

///|
const CURSOR_H : Int32 = 40

///|
pub enum CursorStyle {
  Soft
  Neg
}

///|
/// 解析 `?cursor=` 的值。返回 None 表示这次不画。
pub fn parse_cursor(v : String?) -> CursorStyle? {
  match v {
    // 不带参数：保持默认（当前就是不画）。以后默认要改就改这里一处。
    None => None
    Some(raw) =>
      match raw.trim().to_owned() {
        "1" => Some(Soft)
        "2" => Some(Neg)
        // "0" 和任何写错的值都不画 —— 写错了还悄悄画上去最坑
        _ => None
      }
  }
}

///|
/// 读坐标文件。内容是 `x y`，两个十进制数。
///
/// 读不到、格式不对、负数都返回 None。负数是 KWin 在多屏边界外报的值，
/// 画出来没意义。
pub async fn read_cursor_pos(path : String) -> (Int32, Int32)? {
  let exists = @fs.exists(path) catch { _ => false }
  if !exists {
    return None
  }
  let text = try {
    let f = @fs.open(path, mode=ReadOnly)
    let b = f.read_all().binary()
    f.close()
    @utf8.decode_lossy(b)
  } catch {
    _ => return None
  }
  let nums : Array[Int32] = []
  let mut cur = -1
  for i = 0; i <= text.length(); i = i + 1 {
    let is_digit = if i < text.length() {
      let c = text[i].to_int()
      c >= 48 && c <= 57
    } else {
      false
    }
    if is_digit {
      let d = text[i].to_int() - 48
      if cur < 0 {
        cur = d
      } else {
        cur = cur * 10 + d
      }
    } else if cur >= 0 {
      nums.push(cur)
      cur = -1
    }
  }
  if nums.length() < 2 {
    return None
  }
  Some((nums[0], nums[1]))
}

///|
/// 光标叠加用的 magick 参数。`src` 和 `out` 由调用方给。
///
/// Soft：直接把箭头贴上去。
/// Neg：先把光标那一小块反色，再用箭头的 alpha 当蒙版贴回来 ——
/// 这样只有箭头形状内的像素被反色，形状外原样保留。
pub fn cursor_args(
  style : CursorStyle,
  src : String,
  out : String,
  x : Int32,
  y : Int32,
  arrow : String,
  mask : String,
  width : Int32?,
) -> Array[String] {
  let args : Array[String] = [src]
  match style {
    Soft => {
      args.push(arrow)
      args.push("-geometry")
      args.push("+\{x}+\{y}")
      args.push("-compose")
      args.push("over")
      args.push("-composite")
    }
    Neg => {
      // \( +clone -crop WxH+X+Y -negate \( mask \) -compose CopyOpacity -composite \)
      args.push("(")
      args.push("+clone")
      args.push("-crop")
      args.push("\{CURSOR_W}x\{CURSOR_H}+\{x}+\{y}")
      args.push("+repage")
      args.push("-negate")
      args.push("(")
      args.push(mask)
      args.push(")")
      args.push("-compose")
      args.push("CopyOpacity")
      args.push("-composite")
      args.push(")")
      args.push("-geometry")
      args.push("+\{x}+\{y}")
      args.push("-compose")
      args.push("over")
      args.push("-composite")
    }
  }
  if width is Some(w) {
    args.push("-resize")
    args.push("\{w}x")
  }
  args.push("-quality")
  args.push("82")
  args.push(out)
  args
}
