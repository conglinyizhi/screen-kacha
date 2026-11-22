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
fn not_found(path : String) -> Resp {
  make_res(404, "text/plain; charset=utf-8", @utf8.encode(not_found_text(path)))
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
/// C 侧光标合成的返回码翻译成人话。码值见 `moonbit_image_cursor`。
fn cursor_code_text(code : Int32) -> String {
  if code == 1 {
    "原始帧尺寸非法"
  } else if code == 2 {
    "源画面解码失败"
  } else if code == 3 {
    "缩放缓冲分配失败"
  } else if code == 4 {
    "输出文件建不出来"
  } else if code == 5 {
    "WebP 编码失败"
  } else if code == 6 {
    "写盘不完整"
  } else if code == 7 {
    "光标素材 PNG 读不出来"
  } else {
    "未知错误"
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
  "{\"ok\": \{ok}, \"stalled\": \{stalled}, \"frame_age_ms\": \{store.age_ms()}, \"cap_ms\": \{store.cap_ms()}, \"count\": \{store.count()}, \"fails\": \{store.fails()}, \"fails_consecutive\": \{store.consec_fails()}, \"err\": \"\{json_escape_text(store.err())}\", \"port\": \{port}, \"idle_ms\": \{store.idle_ms()}, \"source\": \"\{json_escape_text(store.source())}\", \"access\": \"\{json_escape_text(access.describe())}\", \"cursor_fails\": \{store.cursor_fails()}, \"cursor_err\": \"\{json_escape_text(store.cursor_err())}\"}"
}

///|
fn handle_health(store : Store, port : Int32, access : Access) -> Resp {
  make_res(
    200,
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
  // 读完就删。
  //
  // 原来是「读完不管，靠 next_tmp 的环形滚动兜底」，而环上只留 10 个、
  // 并发上限却是 64：一批请求同时进来，最早的那些文件会被后面的人删掉，
  // 而它们可能正被读。现在读回只有这一个入口，就地删最干净。
  if !ok {
    // 编码器失败时可能已经建了个空文件，顺手清掉
    @fs.remove(out) catch {
      _ => ()
    }
    return None
  }
  let got = try {
    let f = @fs.open(out, mode=ReadOnly)
    let b = f.read_all().binary()
    f.close()
    Some(b)
  } catch {
    _ => None
  }
  @fs.remove(out) catch {
    _ => ()
  }
  got
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
) -> Resp {
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
        // 素材走 data_dir，不再依赖进程当前目录
        let ov_path = store.data_path(ov)
        let mk_path = if mk == "" { "" } else { store.data_path(mk) }
        let out = store.next_tmp(fmt)
        // 要返回码，不能只要 Bool：失败的时候得知道是哪一步坏的
        let code = @image.cursor_overlay_code(
          src,
          is_raw,
          src_w,
          src_h,
          ov_path,
          mk_path,
          cx,
          cy,
          dst_w,
          JPEG_QUALITY,
          webp,
          out,
        )
        match read_result(out, code == 0) {
          Some(b) => {
            store.note_cursor_ok()
            return make_res(200, ctype, b)
          }
          // 合成失败不能静默：调用方拿到的还是 200 的普通截图，
          // 从外面分不出「没开跟踪」和「开了但坏了」。
          None => store.note_cursor_fail(cursor_code_text(code))
        }
      }
      None => ()
    }
  }
  // 原始尺寸直出，什么都不用做
  if !need_work {
    return make_res(200, ctype, data)
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
    Some(b) => make_res(200, ctype, b)
    None =>
      make_res(
        500,
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
) -> Resp {
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
      store.ensure_request(max_age)
      match store.bytes() {
        None =>
          make_res(
            503,
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
async fn handle_skill(store : Store, port : Int32) -> Resp {
  handle_text_file(
    store, "skill.md", "text/markdown; charset=utf-8", fallback_skill, port,
  )
}

///|
pub fn build_router(store : Store, port : Int32, access : Access) -> Router {
  let router = Router::new()
  // 根路径分叉：浏览器给人看的页面，其它（curl、agent）直接给 llms.txt 原文。
  //
  // 判断用 Accept 而不是 User-Agent：浏览器一定会带 text/html，curl 默认是
  // `*/*`，agent 通常什么都不带。User-Agent 谁都能改，而且 agent 的名字
  // 五花八门，靠它分类只会漏。
  //
  // 也不做 meta refresh 跳转：那样 agent 拿到的仍是 HTML 原文，
  // `<meta>`、`<style>`、脚本会一起进它的 context。分叉在服务端做，
  // 两边各拿到干净的东西。
  router.get("/", async fn(ev) {
    if wants_html(ev.get_header("accept")) {
      // 浏览器：给外壳。界面本体在 /for_human_use_browser.js 里，
      // 由那段脚本插到 #for_llm 前面。不执行 JS 的客户端只看到文本。
      make_res(200, "text/html; charset=utf-8", @utf8.encode(index_shell))
    } else {
      handle_text_file(
        store, "llms.txt", "text/plain; charset=utf-8", fallback_llms, port,
      )
    }
  })
  router.get("/for_human_use_browser.js", async fn(_ev) {
    handle_human_js(store, port)
  })
  // 老链接还认：和 / 给同一个外壳
  router.get("/human.html", fn(_ev) {
    make_res(200, "text/html; charset=utf-8", @utf8.encode(index_shell))
  })
  // 健康状态。`/health.json` 是别名：别的端点全带后缀（/snapshot.jpg、
  // /skill.md），agent 容易顺手多敲一个 .json，这里认下来，省一次 404 往返。
  for path in ["/health", "/health.json"] {
    router.get(path, fn(_ev) { handle_health(store, port, access) })
  }
  // 出错兜底页：只认代号，正文从固定表里查
  router.get("/ui/err", fn(ev) {
    let code = match ev.get_query("code") {
      Some(c) => c
      None => ""
    }
    html_res(err_page(code))
  })
  router.get("/skill.md", async fn(_ev) { handle_skill(store, port) })
  router.get("/error.md", async fn(_ev) {
    handle_text_file(
      store, "error.md", "text/markdown; charset=utf-8", fallback_error, port,
    )
  })
  router.get("/robots.txt", async fn(_ev) {
    handle_text_file(
      store, "robots.txt", "text/plain; charset=utf-8", fallback_robots, port,
    )
  })
  router.get("/llms.txt", async fn(_ev) {
    handle_text_file(
      store, "llms.txt", "text/plain; charset=utf-8", fallback_llms, port,
    )
  })
  router.get("/:file", async fn(ev) {
    match ev.param("file") {
      Some(name) =>
        handle_snapshot(
          store,
          name,
          ev.get_query("w"),
          ev.get_query("age"),
          ev.get_query("cursor"),
        )
      None => not_found("/")
    }
  })
  router.get("/**", fn(ev) { not_found(ev.path()) })
  router
}
