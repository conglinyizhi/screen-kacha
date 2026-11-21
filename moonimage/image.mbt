///|
/// 图像编解码：把 BGRA 原始帧缩放后编成 JPEG / WebP。
///
/// 只做我们实际用到的两件事，不做通用图像处理。
/// C 部分在 `image_shim.c`，依赖 libjpeg（BSD/IJG）和 libwebp（BSD-3）。

///|
/// BGRA 文件 → JPEG 文件。
///
/// `dst_w` 传 0 或大于等于源宽表示不缩放。`quality` 取 1–100。
/// 返回 true 表示成功。失败不抛异常，调用方自己决定怎么记错。
#borrow(bgra_path, out_path)
extern "c" fn bgra_to_jpeg_raw(
  bgra_path : Bytes,
  w : Int32,
  h : Int32,
  dst_w : Int32,
  quality : Int32,
  out_path : Bytes,
) -> Int32 = "moonbit_image_bgra_to_jpeg"

///|
#borrow(bgra_path, out_path)
extern "c" fn bgra_to_webp_raw(
  bgra_path : Bytes,
  w : Int32,
  h : Int32,
  dst_w : Int32,
  quality : Int32,
  out_path : Bytes,
) -> Int32 = "moonbit_image_bgra_to_webp"

///|
/// MoonBit 字符串 → 带结尾 0 的 C 字符串。
fn cstr(s : String) -> Bytes {
  let src = @utf8.encode(s)
  let n = src.length()
  Bytes::makei(n + 1, fn(i) { if i < n { src[i] } else { 0 } })
}

///|
/// 把 BGRA 原始帧写成 JPEG。
///
/// - `src`：BGRA 文件路径（宽 × 高 × 4 字节，A 忽略）
/// - `dst_w`：目标宽度，0 表示不缩放
pub fn bgra_to_jpeg(
  src : String,
  w : Int32,
  h : Int32,
  dst_w : Int32,
  quality : Int32,
  out : String,
) -> Bool {
  bgra_to_jpeg_raw(cstr(src), w, h, dst_w, quality, cstr(out)) == 0
}

///|
/// 把 BGRA 原始帧写成 WebP。参数含义同 `bgra_to_jpeg`。
pub fn bgra_to_webp(
  src : String,
  w : Int32,
  h : Int32,
  dst_w : Int32,
  quality : Int32,
  out : String,
) -> Bool {
  bgra_to_webp_raw(cstr(src), w, h, dst_w, quality, cstr(out)) == 0
}
