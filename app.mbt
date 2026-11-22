///|
fn is_digit(c : UInt16) -> Bool {
  c >= 48 && c <= 57
}

///|
fn digit_of(c : UInt16) -> Int32 {
  c.to_int() - 48
}

///|
/// 整数部分最多几位。输出是毫秒，六位够到 999999 秒。
const AGE_INT_DIGITS : Int32 = 6

///|
/// 小数部分最多几位。输出精度到毫秒，三位之后没有意义。
const AGE_FRAC_DIGITS : Int32 = 3

///|
/// 解析查询参数里的秒数，支持整数和小数，返回毫秒。
///
/// 位数必须封顶。不封的话 `0.` 后面跟 64 个 0 会让 `frac_scale` 乘过
/// Int64 回绕成 0（10^64 正好是 2^64 的整数倍），最后一步除零，
/// 进程直接 SIGFPE 死掉。一个 GET 就能打崩服务，所以这里挡两道：
/// 先看总长度，再看分段位数。
fn parse_seconds_ms(s : StringView) -> Int64? {
  // 六位整数 + 小数点 + 三位小数
  if s.length() == 0 || s.length() > AGE_INT_DIGITS + 1 + AGE_FRAC_DIGITS {
    return None
  }
  let mut int_part = 0L
  let mut frac = 0L
  let mut frac_scale = 1L
  let mut int_digits = 0
  let mut frac_digits = 0
  let mut seen_dot = false
  for i in 0..<s.length() {
    let c = s[i]
    if c == 46 {
      if seen_dot {
        return None
      }
      seen_dot = true
      continue
    }
    guard is_digit(c) else { return None }
    let d = digit_of(c).to_int64()
    if seen_dot {
      // 多写的小数位直接拒绝，不悄悄截断：写错了还照着跑最坑
      guard frac_digits < AGE_FRAC_DIGITS else { return None }
      frac_digits = frac_digits + 1
      frac_scale = frac_scale * 10L
      frac = frac * 10L + d
    } else {
      guard int_digits < AGE_INT_DIGITS else { return None }
      int_digits = int_digits + 1
      int_part = int_part * 10L + d
    }
  }
  Some(int_part * 1000L + frac * 1000L / frac_scale)
}

///|
/// 查询参数里的整数宽度，非法返回 None。
fn parse_width(s : StringView) -> Int32? {
  if s.length() == 0 || s.length() > 5 {
    return None
  }
  let mut n = 0
  for i in 0..<s.length() {
    let c = s[i]
    guard is_digit(c) else { return None }
    n = n * 10 + digit_of(c)
  }
  Some(n)
}

///|
/// 解析 snapshot.jpg / snapshot-1280.jpg / snapshot-1280.webp
fn parse_snapshot(name : StringView) -> (Int32?, String)? {
  let (stem, fmt) = if name.has_suffix(".jpg") {
    (name[:name.length() - 4], "jpg")
  } else if name.has_suffix(".webp") {
    (name[:name.length() - 5], "webp")
  } else {
    return None
  }
  guard stem.has_prefix("snapshot") else { return None }
  let rest = stem[8:]
  if rest.length() == 0 {
    return Some((None, fmt))
  }
  guard rest[0] == '-' else { return None }
  let digits = rest[1:]
  guard digits.length() > 0 && digits.length() <= 5 else { return None }
  let mut w = 0
  for i in 0..<digits.length() {
    let c = digits[i]
    guard is_digit(c) else { return None }
    w = w * 10 + digit_of(c)
  }
  Some((Some(w), fmt))
}

///|
fn clamp_width(w : Int32?) -> Int32? {
  match w {
    None => None
    Some(v) => Some(if v < 160 { 160 } else if v > 3840 { 3840 } else { v })
  }
}

///|
fn make_res(
  code : @crescent.StatusCode,
  ctype : String,
  body : Bytes,
) -> @crescent.HttpResponse {
  @crescent.HttpResponse::HttpResponse(
    status_code=code,
    headers={ "Content-Type": ctype, "Cache-Control": "no-store" },
    raw_body=body,
  )
}

///|
fn not_found(path : String) -> @crescent.HttpResponse {
  make_res(
    @crescent.StatusCode::NotFound,
    "text/plain; charset=utf-8",
    @utf8.encode(not_found_text(path)),
  )
}

///|

///|
/// 把一个字符串转成能安全放进 JSON 双引号里的形式。
///
/// 直接往模板里拼不行：错误信息里可能带引号，`allow` 名单里也可能有，
/// 一进 `/health` 整个 JSON 就断了。实测 `allow = 10.0.0.1"x` 时 python 的
/// `json.load` 直接报 `Expecting ',' delimiter`，而托盘正是靠字符串匹配读
/// 这个 JSON 的，坏了它也跟着判断错。
///
/// 按 UTF-8 字节走：ASCII 里需要转义的换掉，多字节序列原样透传，
/// 这样代理对（emoji 之类）不会被拆坏。
fn json_escape_text(s : String) -> String {
  let src = @utf8.encode(s)
  let out : Array[Byte] = []
  for i in 0..<src.length() {
    let b = src[i].to_int()
    if b == 0x22 {
      out.push((92 : Byte))
      out.push((34 : Byte))
    } else if b == 0x5C {
      out.push((92 : Byte))
      out.push((92 : Byte))
    } else if b == 0x0A {
      out.push((92 : Byte))
      out.push((110 : Byte))
    } else if b == 0x0D {
      out.push((92 : Byte))
      out.push((114 : Byte))
    } else if b == 0x09 {
      out.push((92 : Byte))
      out.push((116 : Byte))
    } else if b < 0x20 {
      // 其余控制字符走 \u00XX
      out.push((92 : Byte))
      out.push((117 : Byte))
      out.push((48 : Byte))
      out.push((48 : Byte))
      out.push(hex_digit_of(b / 16))
      out.push(hex_digit_of(b % 16))
    } else {
      out.push(src[i])
    }
  }
  @utf8.decode_lossy(Bytes::from_array(out))
}

///|
fn hex_digit_of(n : Int32) -> Byte {
  if n < 10 {
    (48 + n).to_byte()
  } else {
    (87 + n).to_byte()
  }
}

///|
/// `/health` 的响应正文。抽成纯函数，好直接测转义。
fn health_json(store : Store, port : Int32, access : Access) -> String {
  // ok 要同时看三件事：有帧、最近一次采集没失败、帧还在更新。
  //
  // 只看前两个是不够的：泵线程要是整个卡死，就不会有任何一次采集失败，
  // err 一直是空的，ok 会一直说 true，而画面停在几分钟前。
  let stalled = store.is_stalled()
  let ok = match store.bytes() {
    Some(_) => store.err() == "" && !stalled
    None => false
  }
  "{\"ok\": \{ok}, \"stalled\": \{stalled}, \"frame_age_ms\": \{store.age_ms()}, \"cap_ms\": \{store.cap_ms()}, \"count\": \{store.count()}, \"fails\": \{store.fails()}, \"fails_consecutive\": \{store.consec_fails()}, \"err\": \"\{json_escape_text(store.err())}\", \"port\": \{port}, \"idle_ms\": \{store.idle_ms()}, \"source\": \"\{json_escape_text(store.source())}\", \"access\": \"\{json_escape_text(access.describe())}\"}"
}

///|
fn handle_health(
  store : Store,
  port : Int32,
  access : Access,
) -> @crescent.HttpResponse {
  make_res(
    @crescent.StatusCode::OK,
    "application/json",
    @utf8.encode(health_json(store, port, access)),
  )
}

///|
/// JPEG / WebP 编码质量。
///
/// 82 是这套图上的折中：再低文字边缘开始发糊，agent 截图认字会吃力；
/// 再高单帧体积涨得快，而这张图是拿来看屏幕状态的，不追求观赏画质。
const JPEG_QUALITY : Int32 = 82

///|
/// 编码器把结果写在临时文件里，这里读回内存。
///
/// `ok` 是编码器自己的返回值：它已经失败了就别再去开文件，省一次必然失败的读。
async fn read_result(out : String, ok : Bool) -> Bytes? {
  if !ok {
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

///|
/// 按请求参数构造图像响应。单独抽出来，好在不跑 spectacle 的前提下测降级分支。
///
/// 三种来源（贴光标的帧、原始帧重编码、已抓到的 JPEG 重编码）结果都落在同一个
/// 临时文件里，读回方式也一样，所以统一走 `read_result`。早先每个分支各抄一份
/// 「建文件、编码、开文件、读回、返回」，三份模板改一处漏两处。
async fn build_image_response(
  store : Store,
  data : Bytes,
  width : Int32?,
  fmt : String,
  cursor : Cursor?,
) -> @crescent.HttpResponse {
  let ctype = if fmt == "webp" { "image/webp" } else { "image/jpeg" }
  let webp = fmt == "webp"
  // 尺寸写 0 表示保持原尺寸，编码器认这个约定
  let dst_w = match width {
    Some(w) => w
    None => 0
  }
  // 不缩放又不要 webp 时，抓到的字节可以直接返回
  let need_work = match width {
    Some(_) => true
    None => fmt != "jpg"
  }
  // 有 PipeWire 原始帧就直接在 BGRA 上动，省掉「编码成 JPEG 再解码回来」
  // 这一来一回；只有退回 spectacle 或假帧源、手上只有 JPEG 时才多解一次。
  let (src, is_raw, src_w, src_h) = match store.pw_raw() {
    Some((raw, w, h)) => (raw, true, w, h)
    None => (store.shot(), false, 0, 0)
  }
  // 要在图上画光标。合成在 C 里做，不再调 ImageMagick。
  //
  // 这一步和 need_work 无关：不缩放也得先把指针贴上。
  // 坐标拿不到（跟踪没开）算正常情况，安静退回普通截图。
  if cursor is Some(cur) {
    match read_cursor_pos(store.cursor_pos_path()) {
      Some((cx, cy)) => {
        let (arrow, mask) = cur.assets()
        // 半透明模式贴箭头，负片模式用蒙版做反色，两者互斥
        let (ov, mk) = match cur.style {
          Soft => (arrow, "")
          Neg => ("", mask)
        }
        let out = store.next_tmp(fmt)
        let ok = @image.cursor_overlay(
          src,
          is_raw,
          src_w,
          src_h,
          ov,
          mk,
          cx,
          cy,
          dst_w,
          JPEG_QUALITY,
          webp,
          out,
        )
        match read_result(out, ok) {
          Some(b) => return make_res(@crescent.StatusCode::OK, ctype, b)
          None => ()
        }
      }
      None => ()
    }
  }
  // 原始尺寸直出，什么都不用做
  if !need_work {
    return make_res(@crescent.StatusCode::OK, ctype, data)
  }
  // 走到这里必须重编码：有原始像素就在 BGRA 上做，否则解一次已抓到的 JPEG。
  let out = store.next_tmp(fmt)
  let ok = if is_raw {
    if webp {
      @image.bgra_to_webp(src, src_w, src_h, dst_w, JPEG_QUALITY, out)
    } else {
      @image.bgra_to_jpeg(src, src_w, src_h, dst_w, JPEG_QUALITY, out)
    }
  } else {
    @image.jpeg_to_file(src, dst_w, JPEG_QUALITY, webp, out)
  }
  match read_result(out, ok) {
    Some(b) => make_res(@crescent.StatusCode::OK, ctype, b)
    None =>
      make_res(
        @crescent.StatusCode::InternalServerError,
        "application/json",
        @utf8.encode("{\"error\":\"图像转换失败\"}"),
      )
  }
}

///|
async fn handle_snapshot(
  store : Store,
  name : StringView,
  query_w : String?,
  query_age : String?,
  query_cursor : String?,
) -> @crescent.HttpResponse {
  store.mark_request()
  match parse_snapshot(name) {
    None => not_found("/\{name}")
    Some((path_w, fmt)) => {
      let w = match query_w {
        Some(v) => parse_width(v)
        None => path_w
      }
      let raw_age = match query_age {
        Some(v) => parse_seconds_ms(v)
        None => Some(1500L)
      }
      let max_age = match raw_age {
        Some(ms) =>
          if ms < 50L {
            50L
          } else if ms > 60000L {
            60000L
          } else {
            ms
          }
        None => 1500L
      }
      store.ensure(max_age)
      match store.bytes() {
        None =>
          make_res(
            @crescent.StatusCode::ServiceUnavailable,
            "application/json",
            @utf8.encode("{\"error\":\"还没有可用帧\"}"),
          )
        Some(data) =>
          build_image_response(
            store,
            data,
            clamp_width(w),
            fmt,
            parse_cursor(query_cursor),
          )
      }
    }
  }
}

///|
async fn handle_skill() -> @crescent.HttpResponse {
  let text = try {
    let f = @fs.open("skill.md", mode=ReadOnly)
    let s = f.read_all().text()
    f.close()
    s
  } catch {
    _ => fallback_skill
  }
  make_res(
    @crescent.StatusCode::OK,
    "text/markdown; charset=utf-8",
    @utf8.encode(text),
  )
}

///|
pub fn build_app(store : Store, port : Int32, access : Access) -> @crescent.App {
  let app = @crescent.App()
  // 根路径分叉：浏览器给人看的页面，其它（curl、agent）直接给 llms.txt 原文。
  //
  // 判断用 Accept 而不是 User-Agent：浏览器一定会带 text/html，curl 默认是
  // `*/*`，agent 通常什么都不带。User-Agent 谁都能改，而且 agent 的名字
  // 五花八门，靠它分类只会漏。
  //
  // 也不做 meta refresh 跳转：那样 agent 拿到的仍是 HTML 原文，
  // `<meta>`、`<style>`、脚本会一起进它的 context。分叉在服务端做，
  // 两边各拿到干净的东西。
  app.get("/", async fn(ev) {
    if wants_html(ev.req.get_header("accept")) {
      // 浏览器：给外壳。界面本体在 /for_human_use_browser.js 里，
      // 由那段脚本插到 #for_llm 前面。不执行 JS 的客户端只看到文本。
      make_res(
        @crescent.StatusCode::OK,
        "text/html; charset=utf-8",
        @utf8.encode(index_shell),
      ).to_responder()
    } else {
      handle_text_file("llms.txt", "text/plain; charset=utf-8", fallback_llms).to_responder()
    }
  })
  app.get("/for_human_use_browser.js", async fn(_ev) {
    handle_human_js().to_responder()
  })
  // 老链接还认：和 / 给同一个外壳
  app.get("/human.html", fn(_ev) {
    make_res(
      @crescent.StatusCode::OK,
      "text/html; charset=utf-8",
      @utf8.encode(index_shell),
    ).to_responder()
  })
  // 健康状态。`/health.json` 是别名：别的端点全带后缀（/snapshot.jpg、
  // /skill.md），agent 容易顺手多敲一个 .json，这里认下来，省一次 404 往返。
  for path in ["/health", "/health.json"] {
    app.get(path, fn(_ev) { handle_health(store, port, access).to_responder() })
  }
  // 出错兜底页：只认代号，正文从固定表里查
  app.get("/ui/err", fn(ev) {
    let code = match ev.req.get_query("code") {
      Some(c) => c
      None => ""
    }
    @crescent.html(err_page(code))
  })
  app.get("/skill.md", async fn(_ev) { handle_skill().to_responder() })
  app.get("/error.md", async fn(_ev) {
    handle_text_file("error.md", "text/markdown; charset=utf-8", fallback_error).to_responder()
  })
  app.get("/robots.txt", async fn(_ev) {
    handle_text_file("robots.txt", "text/plain; charset=utf-8", fallback_robots).to_responder()
  })
  app.get("/llms.txt", async fn(_ev) {
    handle_text_file("llms.txt", "text/plain; charset=utf-8", fallback_llms).to_responder()
  })
  app.get("/:file", async fn(ev) {
    match ev.param("file") {
      Some(name) =>
        handle_snapshot(
          store,
          name,
          ev.req.get_query("w"),
          ev.req.get_query("age"),
          ev.req.get_query("cursor"),
        ).to_responder()
      None => not_found("/").to_responder()
    }
  })
  app.get("/**", fn(ev) { not_found(ev.req.path()).to_responder() })
  app
}
