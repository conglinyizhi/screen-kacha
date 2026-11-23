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
/// C 侧实现，见 `image_shim.c` 的 `moonbit_image_cursor`。
#borrow(src_path, overlay_png, mask_png, out_path)
extern "c" fn cursor_overlay_raw(
  src_path : Bytes,
  src_is_bgra : Int32,
  src_w : Int32,
  src_h : Int32,
  overlay_png : Bytes,
  mask_png : Bytes,
  x : Int32,
  y : Int32,
  dst_w : Int32,
  quality : Int32,
  webp : Int32,
  out_path : Bytes,
) -> Int32 = "moonbit_image_cursor"

///|
/// C 侧实现，见 `image_shim.c` 的 `moonbit_image_jpeg_to_file`。
#borrow(src_path, out_path)
extern "c" fn jpeg_to_file_raw(
  src_path : Bytes,
  dst_w : Int32,
  quality : Int32,
  webp : Int32,
  out_path : Bytes,
) -> Int32 = "moonbit_image_jpeg_to_file"

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
  bgra_to_jpeg_raw(@util.cstr(src), w, h, dst_w, quality, @util.cstr(out)) == 0
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
  bgra_to_webp_raw(@util.cstr(src), w, h, dst_w, quality, @util.cstr(out)) == 0
}

///|
/// 帧 → 画光标 → 缩放 → 编码，一步到位。
///
/// 取代原来那条 ImageMagick 命令。`src_is_raw` 为 true 时 `src` 是 BGRA
/// 原始帧（用 `src_w`/`src_h`），false 时是已经抓好的 JPEG。
///
/// 半透明模式传 `overlay`、`mask` 留空；负片反过来。`x`/`y` 可以超出画面，
/// 越界的部分会被裁掉。失败返回 false，不抛异常。
pub fn cursor_overlay(
  src : String,
  src_is_raw : Bool,
  src_w : Int32,
  src_h : Int32,
  overlay : String,
  mask : String,
  x : Int32,
  y : Int32,
  dst_w : Int32,
  quality : Int32,
  webp : Bool,
  out : String,
) -> Bool {
  let raw_flag : Int32 = if src_is_raw { 1 } else { 0 }
  let webp_flag : Int32 = if webp { 1 } else { 0 }
  cursor_overlay_raw(
    @util.cstr(src),
    raw_flag,
    src_w,
    src_h,
    @util.cstr(overlay),
    @util.cstr(mask),
    x,
    y,
    dst_w,
    quality,
    webp_flag,
    @util.cstr(out),
  ) ==
  0
}

///|
/// JPEG 文件 → 缩放 → JPEG 或 WebP。只有拿不到原始 BGRA 时才需要，
/// 走 PipeWire 时用 `bgra_to_jpeg` / `bgra_to_webp` 更省一次解码。
#borrow(src, out)
pub fn jpeg_to_file(
  src : String,
  dst_w : Int32,
  quality : Int32,
  webp : Bool,
  out : String,
) -> Bool {
  let webp_flag : Int32 = if webp { 1 } else { 0 }
  jpeg_to_file_raw(@util.cstr(src), dst_w, quality, webp_flag, @util.cstr(out)) ==
  0
}

///|
/// C 侧裁剪入口，见 `image_shim.c` 的 `moonbit_image_region`。
#borrow(src, out)
extern "c" fn image_region_raw(
  src : Bytes,
  src_is_raw : Int32,
  src_w : Int32,
  src_h : Int32,
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  dst_w : Int32,
  quality : Int32,
  webp : Int32,
  out : Bytes,
) -> Int32 = "moonbit_image_region"

///|
/// 按归一化矩形（0..1）裁一块，再缩放编码。
///
/// 矩形由调用方先校验过一遍（`parse_region`），C 侧仍然会再查一次：
/// 这个参数一路来自 HTTP 查询串和 MCP 参数，不能只靠上游把关。
#borrow(src, out)
pub fn image_region(
  src : String,
  src_is_raw : Bool,
  src_w : Int32,
  src_h : Int32,
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  dst_w : Int32,
  quality : Int32,
  webp : Bool,
  out : String,
) -> Bool {
  let webp_flag : Int32 = if webp { 1 } else { 0 }
  let raw_flag : Int32 = if src_is_raw { 1 } else { 0 }
  image_region_raw(
    @util.cstr(src), raw_flag, src_w, src_h, x, y, w, h, dst_w, quality,
    webp_flag, @util.cstr(out),
  ) ==
  0
}

///|
/// 同 `image_region`，返回 C 侧的错误码。只给测试和排查用。
#borrow(src, out)
pub fn image_region_code(
  src : String,
  src_is_raw : Bool,
  src_w : Int32,
  src_h : Int32,
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  dst_w : Int32,
  quality : Int32,
  webp : Bool,
  out : String,
) -> Int32 {
  let webp_flag : Int32 = if webp { 1 } else { 0 }
  let raw_flag : Int32 = if src_is_raw { 1 } else { 0 }
  image_region_raw(
    @util.cstr(src), raw_flag, src_w, src_h, x, y, w, h, dst_w, quality,
    webp_flag, @util.cstr(out),
  )
}

///|
/// 图片尺寸。读不出来返回 None。
///
/// C 侧只读 JPEG 头，不整张解码 —— `/health` 会被频繁调用。
pub fn image_dims(path : String) -> (Int32, Int32)? {
  let packed = image_dims_raw(@util.cstr(path))
  if packed < 0L {
    return None
  }
  let w = (packed >> 32).to_int()
  let h = (packed & 0xFFFFFFFFL).to_int()
  if w <= 0 || h <= 0 {
    None
  } else {
    Some((w, h))
  }
}

///|
/// C 侧尺寸查询，返回 (w << 32) | h，失败 -1。
#borrow(path)
extern "c" fn image_dims_raw(path : Bytes) -> Int64 = "moonbit_image_dims"

///|
/// 同 `cursor_overlay`，但把 C 侧的返回码原样交出来。只给测试和排查用：
/// 1 尺寸非法，2 帧读不出来/解不开，7 素材 PNG 读不出来，其余见 encode_bgra。
pub fn cursor_overlay_code(
  src : String,
  src_is_raw : Bool,
  src_w : Int32,
  src_h : Int32,
  overlay : String,
  mask : String,
  x : Int32,
  y : Int32,
  dst_w : Int32,
  quality : Int32,
  webp : Bool,
  out : String,
) -> Int32 {
  cursor_overlay_raw(
    @util.cstr(src),
    if src_is_raw {
      1
    } else {
      0
    },
    src_w,
    src_h,
    @util.cstr(overlay),
    @util.cstr(mask),
    x,
    y,
    dst_w,
    quality,
    if webp {
      1
    } else {
      0
    },
    @util.cstr(out),
  )
}
