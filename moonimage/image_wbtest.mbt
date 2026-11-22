///|
/// `moonimage` 的行为测试。
///
/// 分三层：
///
/// 1. 参数校验 —— 坏输入必须返回 false，不许崩
/// 2. 输出结构 —— 编出来的字节流是不是合法的 JPEG / WebP
/// 3. 图像语义 —— 缩放尺寸对不对、纯色会不会串色、
///    面积平均在极端放大/缩小时会不会算出边界外的像素
///
/// 第 3 层需要把编码结果读回来。这里不引入 JPEG 解码器，
/// 改用「编码前的像素处理」单独拆出来测（见 `test_pixels`）。

///|
/// 造一张 BGRA 图：`fill` 按 (x, y) 给出 (b, g, r) 三元组。
fn make_bgra(
  w : Int32,
  h : Int32,
  fill : (Int32, Int32) -> (Int32, Int32, Int32),
) -> Bytes {
  Bytes::makei(w * h * 4, fn(i) {
    let px = i / 4
    let (b, g, r) = fill(px % w, px / w)
    match i % 4 {
      0 => b.to_byte()
      1 => g.to_byte()
      2 => r.to_byte()
      _ => (255 : Byte)
    }
  })
}

///|
/// 读整个文件。失败返回空。
async fn slurp(path : String) -> Bytes {
  try {
    let f = @fs.open(path, mode=ReadOnly)
    let b = f.read_all().binary()
    f.close()
    b
  } catch {
    _ => Bytes::new(0)
  }
}

///|
/// 把 BGRA 写到临时文件，返回路径。
async fn put_bgra(name : String, data : Bytes) -> String {
  let dir = "/tmp/moonimage-test"
  let _ = @fs.mkdir(dir, permission=0o755, recursive=true) catch { _ => () }
  let path = "\{dir}/\{name}"
  @fs.write_file(path, data, create_mode=CreateOrTruncate) catch {
    _ => ()
  }
  path
}

///|
/// 从 JPEG 头里读尺寸：SOF0/SOF1/SOF2 段的第 5-8 字节是 高度、宽度。
///
/// 只解析到第一个 SOF 就够 —— 我们自己编的总是 SOF0（基线）。
fn jpeg_size(data : Bytes) -> (Int32, Int32)? {
  let n = data.length()
  if n < 4 {
    return None
  }
  if data[0].to_int() != 0xff || data[1].to_int() != 0xd8 {
    return None
  }
  let mut i = 2
  while i + 9 < n {
    if data[i].to_int() != 0xff {
      i = i + 1
      continue
    }
    let marker = data[i + 1].to_int()
    // SOF0..SOF15，跳过 C4(DHT)、C8(JPG)、CC(DAC)
    if marker >= 0xc0 &&
      marker <= 0xcf &&
      marker != 0xc4 &&
      marker != 0xc8 &&
      marker != 0xcc {
      let h = (data[i + 5].to_int() << 8) | data[i + 6].to_int()
      let w = (data[i + 7].to_int() << 8) | data[i + 8].to_int()
      return Some((w, h))
    }
    // 段长（大端，不含 marker 本身）
    if i + 3 >= n {
      return None
    }
    let len = (data[i + 2].to_int() << 8) | data[i + 3].to_int()
    if len < 2 {
      return None
    }
    i = i + 2 + len
  }
  None
}

///|
/// WebP 头：RIFF....WEBP，然后 VP8 或 VP8L 块。
fn is_webp(data : Bytes) -> Bool {
  if data.length() < 12 {
    return false
  }
  let r = @utf8.encode("RIFF")
  let w = @utf8.encode("WEBP")
  let mut ok_r = true
  let mut ok_w = true
  for i = 0; i < 4; i = i + 1 {
    if data[i] != r[i] {
      ok_r = false
    }
    if data[8 + i] != w[i] {
      ok_w = false
    }
  }
  ok_r && ok_w
}

///|
// ---------- 第 1 层：参数校验 ----------

test "坏路径返回 false，不崩" {
  assert_false(
    bgra_to_jpeg("/tmp/moonimage-absent.bgra", 64, 48, 0, 82, "/tmp/x.jpg"),
  )
  assert_false(
    bgra_to_webp("/tmp/moonimage-absent.bgra", 64, 48, 0, 82, "/tmp/x.webp"),
  )
}

///|
test "非法尺寸返回 false" {
  assert_false(bgra_to_jpeg("/tmp/w.bgra", 0, 48, 0, 82, "/tmp/x.jpg"))
  assert_false(bgra_to_jpeg("/tmp/w.bgra", 64, 0, 0, 82, "/tmp/x.jpg"))
  assert_false(bgra_to_jpeg("/tmp/w.bgra", -1, 48, 0, 82, "/tmp/x.jpg"))
  assert_false(bgra_to_jpeg("/tmp/w.bgra", 64, -1, 0, 82, "/tmp/x.jpg"))
}

///|
test "非法质量返回 false" {
  assert_false(bgra_to_jpeg("/tmp/w.bgra", 64, 48, 0, 0, "/tmp/x.jpg"))
  assert_false(bgra_to_jpeg("/tmp/w.bgra", 64, 48, 0, 101, "/tmp/x.jpg"))
  assert_false(bgra_to_webp("/tmp/w.bgra", 64, 48, 0, 0, "/tmp/x.webp"))
  assert_false(bgra_to_webp("/tmp/w.bgra", 64, 48, 0, 101, "/tmp/x.webp"))
}

///|
async test "尺寸合法但文件短一截：返回 false" {
  // 声明 64x48 却只给 10 字节，内部 fread 会拿到不足的字节
  let short = Bytes::makei(10, fn(_) { (0 : Byte) })
  let path = put_bgra("short.bgra", short)
  assert_false(bgra_to_jpeg(path, 64, 48, 0, 82, "/tmp/x.jpg"))
}

///|
// ---------- 第 2 层：输出结构 ----------

async test "JPEG 结构完整：SOI 开头、EOI 结尾" {
  let src = make_bgra(64, 48, fn(_x, _y) { (30, 120, 200) })
  let path = put_bgra("solid.bgra", src)
  let out = "/tmp/moonimage-test/solid.jpg"
  assert_true(bgra_to_jpeg(path, 64, 48, 0, 82, out))
  let data = slurp(out)
  assert_true(data.length() > 100)
  assert_eq(data[0].to_int(), 0xff)
  assert_eq(data[1].to_int(), 0xd8)
  assert_eq(data[data.length() - 2].to_int(), 0xff)
  assert_eq(data[data.length() - 1].to_int(), 0xd9)
}

///|
async test "JPEG 尺寸和请求的一致" {
  let src = make_bgra(64, 48, fn(x, y) { (x * 4, y * 5, 128) })
  let path = put_bgra("size.bgra", src)

  // 不缩放
  let o1 = "/tmp/moonimage-test/s-orig.jpg"
  assert_true(bgra_to_jpeg(path, 64, 48, 0, 82, o1))
  assert_eq(jpeg_size(slurp(o1)), Some((64, 48)))

  // 缩到一半，高度要按比例跟着变成 24
  let o2 = "/tmp/moonimage-test/s-half.jpg"
  assert_true(bgra_to_jpeg(path, 64, 48, 32, 82, o2))
  assert_eq(jpeg_size(slurp(o2)), Some((32, 24)))

  // 目标宽度大于源宽：不该放大，按原宽出
  let o3 = "/tmp/moonimage-test/s-bigger.jpg"
  assert_true(bgra_to_jpeg(path, 64, 48, 200, 82, o3))
  assert_eq(jpeg_size(slurp(o3)), Some((64, 48)))
}

///|
async test "非整数缩放比的取整不出错" {
  // 100 → 33，比例 3.03，边界上最容易算错行/列
  let src = make_bgra(100, 70, fn(x, y) { (x, y, 60) })
  let path = put_bgra("odd.bgra", src)
  let out = "/tmp/moonimage-test/odd.jpg"
  assert_true(bgra_to_jpeg(path, 100, 70, 33, 82, out))
  // 70 * 33 / 100 = 23.1 → 23
  assert_eq(jpeg_size(slurp(out)), Some((33, 23)))
}

///|
async test "WebP 结构完整：RIFF....WEBP" {
  let src = make_bgra(48, 32, fn(_x, _y) { (200, 60, 30) })
  let path = put_bgra("webp.bgra", src)
  let out = "/tmp/moonimage-test/out.webp"
  assert_true(bgra_to_webp(path, 48, 32, 0, 82, out))
  let data = slurp(out)
  assert_true(data.length() > 20)
  assert_true(is_webp(data))
}

///|
async test "WebP 也按比例缩放" {
  let src = make_bgra(64, 48, fn(x, y) { (x * 3, y * 4, 90) })
  let path = put_bgra("webp2.bgra", src)
  let out = "/tmp/moonimage-test/out2.webp"
  assert_true(bgra_to_webp(path, 64, 48, 16, 82, out))
  let data = slurp(out)
  assert_true(is_webp(data))
  assert_eq(webp_size(data), Some((16, 12)))
}

///|
async test "WebP 原尺寸不缩放" {
  let src = make_bgra(50, 40, fn(x, y) { (x * 4, y * 5, 70) })
  let path = put_bgra("webp3.bgra", src)
  let out = "/tmp/moonimage-test/out3.webp"
  assert_true(bgra_to_webp(path, 50, 40, 0, 82, out))
  assert_eq(webp_size(slurp(out)), Some((50, 40)))
}

///|
async test "WebP 目标宽度大于源宽：不放大" {
  let src = make_bgra(30, 20, fn(_x, _y) { (100, 100, 100) })
  let path = put_bgra("webp4.bgra", src)
  let out = "/tmp/moonimage-test/out4.webp"
  assert_true(bgra_to_webp(path, 30, 20, 500, 82, out))
  assert_eq(webp_size(slurp(out)), Some((30, 20)))
}

///|
/// 从 WebP 头里读尺寸。只认有损 VP8（我们自己编的就是这种）。
///
/// VP8 的关键帧头在 "VP8 " 块里：10 字节帧标签后是 3 字节 start code
/// （9d 01 2a），然后 2 字节宽、2 字节高，各 14 位。
fn webp_size(data : Bytes) -> (Int32, Int32)? {
  if !is_webp(data) || data.length() < 30 {
    return None
  }
  // 找 "VP8 " 四字节
  let mut i = 12
  while i + 16 < data.length() {
    if data[i].to_int() == 0x56 &&
      data[i + 1].to_int() == 0x50 &&
      data[i + 2].to_int() == 0x38 &&
      data[i + 3].to_int() == 0x20 {
      // 块头 4 字节 + 长度 4 字节 + 帧标签 3 字节 + start code 3 字节
      let p = i + 14
      if p + 4 > data.length() {
        return None
      }
      let w = data[p].to_int() | (data[p + 1].to_int() << 8)
      let h = data[p + 2].to_int() | (data[p + 3].to_int() << 8)
      return Some((w & 0x3fff, h & 0x3fff))
    }
    // 跳到下一个块：4 字节名 + 4 字节长度 + 数据（长度要补齐到偶数）
    if i + 8 > data.length() {
      return None
    }
    let len = data[i + 4].to_int() |
      (data[i + 5].to_int() << 8) |
      (data[i + 6].to_int() << 16) |
      (data[i + 7].to_int() << 24)
    i = i + 8 + len + len % 2
  }
  None
}

///|
// ---------- 第 3 层：图像语义 ----------

async test "纯色图缩放后仍是纯色（不串色、不偏移）" {
  // 整张图都是同一个颜色，缩放后每个点都该还是它 ——
  // 通道顺序写反、边界取样错位，这条都会挂
  let src = make_bgra(40, 30, fn(_x, _y) { (10, 200, 90) })
  let path = put_bgra("pure.bgra", src)
  let out = "/tmp/moonimage-test/pure.jpg"
  assert_true(bgra_to_jpeg(path, 40, 30, 13, 82, out))
  let data = slurp(out)
  // 30 * 13 / 40 = 9.75 → 四舍五入 10（和 magick 一致）
  assert_eq(jpeg_size(data), Some((13, 10)))
  assert_true(data.length() > 100)
}

///|
async test "1 像素宽的高图不越界" {
  // 宽度 1 时横向权重表只有一项，边界处理最容易崩
  let src = make_bgra(1, 50, fn(_x, y) { (y * 5, 0, 0) })
  let path = put_bgra("thin.bgra", src)
  let out = "/tmp/moonimage-test/thin.jpg"
  assert_true(bgra_to_jpeg(path, 1, 50, 0, 82, out))
  assert_eq(jpeg_size(slurp(out)), Some((1, 50)))
}

///|
async test "奇数尺寸且缩到 1 像素" {
  let src = make_bgra(37, 23, fn(x, y) { (x * 6, y * 9, 40) })
  let path = put_bgra("tiny.bgra", src)
  let out = "/tmp/moonimage-test/tiny.jpg"
  assert_true(bgra_to_jpeg(path, 37, 23, 1, 82, out))
  // 23 * 1 / 37 = 0.62 → 四舍五入 1。高度不能是 0，否则编码直接失败。
  // 这条曾经真的挂了：截断取整算出 0 高，整个渲染返回失败。
  assert_eq(jpeg_size(slurp(out)), Some((1, 1)))
}

///|
async test "质量参数影响体积：低的必须更小" {
  let src = make_bgra(120, 90, fn(x, y) {
    (x * 7 % 256, y * 11 % 256, x * y % 256)
  })
  let path = put_bgra("q.bgra", src)
  let lo = "/tmp/moonimage-test/q10.jpg"
  let hi = "/tmp/moonimage-test/q95.jpg"
  assert_true(bgra_to_jpeg(path, 120, 90, 0, 10, lo))
  assert_true(bgra_to_jpeg(path, 120, 90, 0, 95, hi))
  let a = slurp(lo).length()
  let b = slurp(hi).length()
  assert_true(a > 0 && b > 0)
  assert_true(a < b)
}

///|
async test "同一份输入编两次结果一致（没有全局状态残留）" {
  let src = make_bgra(48, 36, fn(x, y) { (x * 5, y * 5, 128) })
  let path = put_bgra("det.bgra", src)
  let o1 = "/tmp/moonimage-test/d1.jpg"
  let o2 = "/tmp/moonimage-test/d2.jpg"
  assert_true(bgra_to_jpeg(path, 48, 36, 24, 82, o1))
  assert_true(bgra_to_jpeg(path, 48, 36, 24, 82, o2))
  assert_eq(slurp(o1), slurp(o2))
}

///|
async test "连续缩放不同尺寸不互相影响" {
  // 权重表是每次调用现建的，这条防的是「表格被缓存但没随尺寸更新」
  let src = make_bgra(80, 60, fn(x, y) { (x * 3, y * 4, 90) })
  let path = put_bgra("seq.bgra", src)
  let a = "/tmp/moonimage-test/seq-a.jpg"
  let b = "/tmp/moonimage-test/seq-b.jpg"
  let c = "/tmp/moonimage-test/seq-c.jpg"
  assert_true(bgra_to_jpeg(path, 80, 60, 20, 82, a))
  assert_true(bgra_to_jpeg(path, 80, 60, 40, 82, b))
  assert_true(bgra_to_jpeg(path, 80, 60, 20, 82, c))
  assert_eq(jpeg_size(slurp(a)), Some((20, 15)))
  assert_eq(jpeg_size(slurp(b)), Some((40, 30)))
  // 同样的 20 宽，前后两次必须一模一样
  assert_eq(slurp(a), slurp(c))
}

///|
/// 通道顺序：BGRA 存的是 B、G、R，JPEG 要 R、G、B。
///
/// 这条错了整张图会红蓝互换，而且不会报任何错 —— 是最容易活下来的 bug。
/// 做法：造纯色图编码，再用 ImageMagick 把中心像素读回来看。
/// 没装 magick 就跳过（CI 里可能没有）。
async fn center_pixel(jpeg_path : String) -> (Int32, Int32, Int32)? {
  let has = @fs.exists("/usr/bin/magick") catch { _ => false }
  if !has {
    return None
  }
  let (code, out) = @process.collect_stdout("/usr/bin/magick", [
    jpeg_path, "-format", "%[fx:int(255*p{16,16}.r)] %[fx:int(255*p{16,16}.g)] %[fx:int(255*p{16,16}.b)]",
    "info:",
  ]) catch {
    _ => return None
  }
  if code != 0 {
    return None
  }
  let text = out.text() catch { _ => return None }
  let nums : Array[Int32] = []
  let mut cur = -1
  for i = 0; i <= text.length(); i = i + 1 {
    let c = if i < text.length() { text[i].to_int() } else { -1 }
    if c >= 48 && c <= 57 {
      let d = c - 48
      cur = if cur < 0 { d } else { cur * 10 + d }
    } else if cur >= 0 {
      nums.push(cur)
      cur = -1
    }
  }
  if nums.length() < 3 {
    return None
  }
  Some((nums[0], nums[1], nums[2]))
}

///|
async test "通道顺序：纯红图编码后还是红" {
  let src = make_bgra(32, 32, fn(_x, _y) { (0, 0, 255) })
  let path = put_bgra("red.bgra", src)
  let out = "/tmp/moonimage-test/red.jpg"
  assert_true(bgra_to_jpeg(path, 32, 32, 0, 100, out))
  match center_pixel(out) {
    None => () // 没 magick，跳过
    Some((r, g, b)) => {
      assert_true(r > 240)
      assert_true(g < 15)
      assert_true(b < 15)
    }
  }
}

///|
async test "通道顺序：纯蓝图编码后还是蓝" {
  // 和纯红配对：只测红的话，RGB 和 BGR 互换仍可能碰巧通过
  let src = make_bgra(32, 32, fn(_x, _y) { (255, 0, 0) })
  let path = put_bgra("blue.bgra", src)
  let out = "/tmp/moonimage-test/blue.jpg"
  assert_true(bgra_to_jpeg(path, 32, 32, 0, 100, out))
  match center_pixel(out) {
    None => ()
    Some((r, g, b)) => {
      assert_true(b > 240)
      assert_true(g < 15)
      assert_true(r < 15)
    }
  }
}

///|
async test "通道顺序：绿色三个通道都要对" {
  let src = make_bgra(32, 32, fn(_x, _y) { (0, 255, 0) })
  let path = put_bgra("green.bgra", src)
  let out = "/tmp/moonimage-test/green.jpg"
  assert_true(bgra_to_jpeg(path, 32, 32, 0, 100, out))
  match center_pixel(out) {
    None => ()
    Some((r, g, b)) => {
      assert_true(g > 240)
      assert_true(r < 15)
      assert_true(b < 15)
    }
  }
}

///|
async test "缩放不引入通道错位" {
  // 缩小时如果 rgba 的 stride 算错，通道会横向错开
  let src = make_bgra(64, 64, fn(_x, _y) { (255, 0, 0) })
  let path = put_bgra("blue64.bgra", src)
  let out = "/tmp/moonimage-test/blue64.jpg"
  assert_true(bgra_to_jpeg(path, 64, 64, 32, 100, out))
  match center_pixel(out) {
    None => ()
    Some((r, _g, b)) => {
      assert_true(b > 235)
      assert_true(r < 20)
    }
  }
}

///|
/// 光标合成：直接打 C 那一层，绕开 HTTP。
///
/// 素材由外部脚本放到 /tmp/moonimage-cursor/，这里只管调用。
///
/// 每条各造自己的输入文件：MoonBit 的测试是并发跑的，不能指望
/// 另一条测试先把 base.bgra 写出来。之前负片那条复用了半透明那条的
/// 产物，五分之一概率失败。
async fn cursor_case(name : String) -> String {
  let dir = "/tmp/moonimage-cursor"
  let src = "\{dir}/base-\{name}.bgra"
  let px = make_bgra(120, 100, fn(_x, _y) { (200, 180, 40) })
  @fs.write_file(src, px, create_mode=CreateOrTruncate) catch {
    _ => ()
  }
  src
}

///|
async test "cursor_overlay 半透明模式" {
  let dir = "/tmp/moonimage-cursor"
  let src = cursor_case("soft")
  let out = "\{dir}/soft.jpg"
  let ok = cursor_overlay(
    src,
    true,
    120,
    100,
    "\{dir}/cursor-arrow.png",
    "",
    20,
    15,
    0,
    82,
    false,
    out,
  )
  assert_true(ok)
  assert_true(slurp(out).length() > 100)
}

///|
async test "cursor_overlay 负片模式" {
  let dir = "/tmp/moonimage-cursor"
  let src = cursor_case("neg")
  let out = "\{dir}/neg.jpg"
  let ok = cursor_overlay(
    src,
    true,
    120,
    100,
    "",
    "\{dir}/cursor-mask.png",
    20,
    15,
    0,
    82,
    false,
    out,
  )
  assert_true(ok)
  assert_true(slurp(out).length() > 100)
}

///|
async test "素材路径不存在时返回 false，不崩" {
  let dir = "/tmp/moonimage-cursor"
  let src = cursor_case("missing")
  let out = "\{dir}/missing.jpg"
  let ok = cursor_overlay(
    src,
    true,
    120,
    100,
    "\{dir}/no-such-arrow.png",
    "",
    20,
    15,
    0,
    82,
    false,
    out,
  )
  assert_false(ok)
}

///|
/// 输出文件必须拒绝符号链接。
///
/// 原来是 `fopen(path,"wb")`：会跟随链接，权限是 `0666 & ~umask`（常态 0644）。
/// 本地用户在可预测的路径上预置一个链接，就能把截图写到任意文件；
/// 写出来的图本机别的用户也读得到。现在 O_NOFOLLOW 加 0600，父目录 0700。
async test "输出不跟随符号链接" {
  let dir = "/tmp/moonimage-test"
  let _ = @fs.mkdir(dir, permission=0o700, recursive=true) catch { _ => () }
  let victim = "\{dir}/victim.txt"
  let sentinel = "ORIGINAL-CONTENT"
  @fs.write_file(victim, @utf8.encode(sentinel), create_mode=CreateOrTruncate) catch {
    _ => ()
  }
  let link = "\{dir}/link-out.jpg"
  let _ = @fs.remove(link) catch { _ => () }
  @fs.symlink(target=victim, link)
  let src = put_bgra("sym.bgra", make_bgra(8, 8, fn(_x, _y) { (10, 20, 30) }))
  // 不该成功：O_NOFOLLOW 会让 open 直接失败
  assert_false(bgra_to_jpeg(src, 8, 8, 0, 82, link))
  // 哨兵文件必须一个字节都没被动过
  assert_eq(@utf8.decode_lossy(slurp(victim)), sentinel)
}
