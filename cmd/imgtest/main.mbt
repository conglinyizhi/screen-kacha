///|
/// 对比工具：同一张 BGRA，分别用 moonimage 和 magick 转 JPEG，报告耗时与体积。
///
/// 只给开发和 CI 用，不装进用户目录。

///|
async fn main {
  let args = @env.args()
  if args.length() < 5 {
    println("用法: imgtest <bgra> <宽> <高> <输出目录>")
    return
  }
  let src = args[1]
  let w = @util.parse_int(args[2], 0)
  let h = @util.parse_int(args[3], 0)
  let dir = args[4]

  for dst_w in [0, 640, 1280] {
    let tag = if dst_w == 0 { "orig" } else { "\{dst_w}" }
    let ours = "\{dir}/ours-\{tag}.jpg"
    let theirs = "\{dir}/magick-\{tag}.jpg"

    let t0 = @env.now()
    let ok = @image.bgra_to_jpeg(src, w, h, dst_w, 82, ours)
    let ms_ours = @env.now() - t0

    let spec = if dst_w == 0 { "\{w}x\{h}" } else { "\{dst_w}x" }
    let code = @process.run("/usr/bin/magick", [
      "-size",
      "\{w}x\{h}",
      "-depth",
      "8",
      "bgra:" + src,
      "-resize",
      spec,
      "-quality",
      "82",
      theirs,
    ]) catch {
      _ => 1
    }
    let _ = code

    if !ok {
      println("\{tag}: moonimage 失败")
      continue
    }
    let a = size_of(ours) catch { _ => 0L }
    let b = size_of(theirs) catch { _ => 0L }
    println("\{tag}: moonimage \{ms_ours}ms \{a}B   magick \{b}B")
  }
}

///|
async fn size_of(path : String) -> Int64 {
  try {
    let f = @fs.open(path, mode=ReadOnly)
    let b = f.read_all().binary()
    f.close()
    b.length().to_int64()
  } catch {
    _ => 0L
  }
}
