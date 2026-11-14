///|
/// 调 magick 缩放并转格式：输入是已经抓好的帧文件，输出写临时文件再读回。
/// async 0.20.3 没有 shell 包，所以不走 stdin/stdout 管道。
pub async fn render_file(src : String, out : String, width : Int32?) -> Bytes? {
  let args : Array[String] = [src]
  if width is Some(w) {
    args.push("-resize")
    args.push("\{w}x")
  }
  args.push("-quality")
  args.push("82")
  args.push(out)
  let code = @process.run("/usr/bin/magick", args) catch { _ => return None }
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
