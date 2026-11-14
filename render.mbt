///|
/// 一次渲染请求该怎么处理。
pub enum RenderPlan {
  /// 原样返回，不必调外部程序
  Passthrough
  /// 需要缩放或转格式，但机器上没有 ImageMagick，退回原图
  Downgrade
  /// 调用 ImageMagick
  Render
}

///|
/// 纯决策：要不要调 magick、缺依赖时怎么退。
pub fn render_plan(
  width : Int32?,
  fmt : String,
  has_magick : Bool,
) -> RenderPlan {
  let needs_magick = match width {
    Some(_) => true
    None => fmt != "jpg"
  }
  if !needs_magick {
    return Passthrough
  }
  if !has_magick {
    return Downgrade
  }
  Render
}

///|
/// 按顺序找第一个存在的候选可执行文件。
pub async fn find_magick(candidates : Array[String]) -> String? {
  for path in candidates {
    if @fs.exists(path) {
      return Some(path)
    }
  }
  None
}

///|
/// ImageMagick 7 是 magick，6 是 convert，GraphicsMagick 是 gm。
pub fn default_magick_candidates() -> Array[String] {
  [
    "/usr/bin/magick", "/usr/local/bin/magick", "/bin/magick", "/usr/bin/convert",
    "/usr/local/bin/convert", "/usr/bin/gm",
  ]
}

///|
pub async fn detect_magick() -> String? {
  find_magick(default_magick_candidates())
}

///|
/// 调 magick 缩放并转格式：输入是已经抓好的帧文件，输出写临时文件再读回。
/// async 0.20.3 没有 shell 包，所以不走 stdin/stdout 管道。
pub async fn render_file(
  magick : String,
  src : String,
  out : String,
  width : Int32?,
) -> Bytes? {
  let args : Array[String] = [src]
  if width is Some(w) {
    args.push("-resize")
    args.push("\{w}x")
  }
  args.push("-quality")
  args.push("82")
  args.push(out)
  let code = @process.run(magick, args) catch { _ => return None }
  if code != 0 {
    return None
  }
  try {
    let f = @fs.open(out, mode=ReadOnly)
    let b = f.read_all().binary()
    f.close()
    Some(b)
  } catch {
    _ => None
  }
}
