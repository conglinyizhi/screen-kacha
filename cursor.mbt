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
pub enum CursorStyle {
  Soft
  Neg
}

///|
/// 一次绘制请求要用的光标：样式 + 用哪套素材。
///
/// 现在有两套素材，形状不同：新版无尾巴（`cursor-*.png`）、
/// 旧版带尾巴（`cursor-*-classic.png`）。
///
/// 尺寸由 C 侧从 PNG 头里读，代码里不再写死宽高，换素材不用改常量。
pub struct Cursor {
  style : CursorStyle
  classic : Bool
}

///|
/// 解析 `?cursor=` 的值。返回 None 表示这次不画。
pub fn parse_cursor(v : String?) -> Cursor? {
  match v {
    // 不带参数：保持默认（当前就是不画）。以后默认要改就改这里一处。
    None => None
    Some(raw) =>
      match raw.trim().to_owned() {
        "1" => Some({ style: Soft, classic: false, })
        "2" => Some({ style: Neg, classic: false, })
        "3" => Some({ style: Soft, classic: true, })
        "4" => Some({ style: Neg, classic: true, })
        // "0" 和任何写错的值都不画 —— 写错了还悄悄画上去最坑
        _ => None
      }
  }
}

///|
/// 这套光标用哪两个素材文件、以及素材的像素尺寸。
///
/// 返回 (箭头图, 蒙版图, 宽, 高)。负片分支拿蒙版去裁底下的像素，
/// 尺寸必须和素材严格一致，差一行就会错位。
pub fn Cursor::assets(self : Cursor) -> (String, String) {
  if self.classic {
    match self.style {
      Soft => ("cursor-arrow-classic.png", "cursor-mask-classic.png")
      Neg => ("cursor-mask-classic.png", "cursor-mask-classic.png")
    }
  } else {
    match self.style {
      Soft => ("cursor-arrow.png", "cursor-mask.png")
      Neg => ("cursor-mask.png", "cursor-mask.png")
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
  // 坐标文件太旧就当作没有。
  //
  // 助手进程自己有 tick 心跳会删过期文件，但那只在它活着的时候有效：
  // 被 SIGKILL、OOM、崩溃时文件会一直留着，主服务无条件相信它，
  // 箭头就定格在最后一次的位置，再也不动。这里补一道兜底。
  //
  // 3 秒：脚本是 200ms 一拍，助手 tick 是 500ms，
  // 3 秒足够宽松（不会因为短暂卡顿误判），又能及时让死掉的跟踪消失。
  let fresh = try {
    let (secs, _nanos) = @fs.mtime(path)
    let now = @async.now() / 1000L
    now - secs <= 3L
  } catch {
    // stat 不了（文件刚被删）就当过期
    _ => false
  }
  if !fresh {
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
  parse_cursor_pos_text(text)
}

///|
/// 解析坐标文件的文本内容。抽成纯函数是为了能直接单测 ——
/// 这层逻辑踩过坑（负号被吃掉），不能再靠"看起来对"。
pub fn parse_cursor_pos_text(text : String) -> (Int32, Int32)? {
  // 负号必须单独处理。
  //
  // 之前把 `-` 当普通分隔符，`-300 400` 会解析成 (300, 400) ——
  // 箭头画到镜像位置，比不画更误导。而多屏时副屏在主屏左边/上边，
  // KWin 给的坐标必然是负数，这是常态不是异常。
  // 现在见到负号就整条拒绝：宁可这次不画，也不画错地方。
  if text.contains("-") {
    return None
  }
  // 只接受「数字 空白 数字」这种形状，别的一律拒绝。
  //
  // 之前只要非数字就当分隔符，`12x 34` 会被解析成 (12, 34) ——
  // 文件被写坏时不是报错，而是画到莫名其妙的地方。
  let nums : Array[Int32] = []
  let mut cur = -1
  let mut last_sep_ok = false
  for i = 0; i <= text.length(); i = i + 1 {
    // 走到字符串末尾：把手上这个数交出去就收工，别再往下判
    if i == text.length() {
      if cur >= 0 {
        nums.push(cur)
      }
      break
    }
    let c = text[i].to_int()
    if c >= 48 && c <= 57 {
      let d = c - 48
      cur = if cur < 0 {
        d
      } else if cur > 100000 {
        // 明显不可能是坐标，别再乘下去（防 Int32 溢出回绕成正数）
        return None
      } else {
        cur * 10 + d
      }
      last_sep_ok = false
    } else if c == 32 || c == 9 || c == 10 || c == 13 {
      if cur >= 0 {
        nums.push(cur)
        cur = -1
      }
      last_sep_ok = true
    } else {
      // 数字和数字（或开头）之间夹了非空白字符：内容不对
      return None
    }
  }
  let _ = last_sep_ok
  if nums.length() < 2 {
    return None
  }
  Some((nums[0], nums[1]))
}
