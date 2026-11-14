///|
fn is_digit(c : UInt16) -> Bool {
  c >= 48 && c <= 57
}

///|
fn digit_of(c : UInt16) -> Int {
  c.to_int() - 48
}

///|
/// 解析 snapshot.jpg / snapshot-1280.jpg / snapshot-1280.webp
fn parse_snapshot(name : StringView) -> (Int?, String)? {
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
fn clamp_width(w : Int?) -> Int? {
  match w {
    None => None
    Some(v) => Some(if v < 160 { 160 } else if v > 3840 { 3840 } else { v })
  }
}

///|
fn make_res(code : @crescent.StatusCode, ctype : String, body : Bytes) -> @crescent.HttpResponse {
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
fn handle_health(store : Store, port : Int32) -> @crescent.HttpResponse {
  let ok = match store.bytes() {
    Some(_) => store.err() == ""
    None => false
  }
  let json = "{\"ok\": \{ok}, \"frame_age_ms\": \{store.age_ms()}, \"cap_ms\": \{store.cap_ms()}, \"count\": \{store.count()}, \"fails\": \{store.fails()}, \"err\": \"\{store.err()}\", \"port\": \{port}}"
  make_res(@crescent.StatusCode::OK, "application/json", @utf8.encode(json))
}

///|
async fn handle_snapshot(store : Store, name : StringView) -> @crescent.HttpResponse {
  match parse_snapshot(name) {
    None => not_found("/\{name}")
    Some((w, fmt)) => {
      store.ensure(400L)
      match store.bytes() {
        None =>
          make_res(
            @crescent.StatusCode::ServiceUnavailable,
            "application/json",
            @utf8.encode("{\"error\":\"还没有可用帧\"}"),
          )
        Some(data) => {
          let width = clamp_width(w)
          let ctype = if fmt == "webp" { "image/webp" } else { "image/jpeg" }
          if width is None && fmt == "jpg" {
            make_res(@crescent.StatusCode::OK, ctype, data)
          } else {
            let out = store.next_tmp(fmt)
            match render_file(store.shot(), out, width) {
              Some(b) => make_res(@crescent.StatusCode::OK, ctype, b)
              None =>
                make_res(
                  @crescent.StatusCode::InternalServerError,
                  "application/json",
                  @utf8.encode("{\"error\":\"图像转换失败\"}"),
                )
            }
          }
        }
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
  make_res(@crescent.StatusCode::OK, "text/markdown; charset=utf-8", @utf8.encode(text))
}

///|
pub fn build_app(store : Store, port : Int32) -> @crescent.App {
  let app = @crescent.App()
  app.get("/", async fn(_ev) {
    make_res(
      @crescent.StatusCode::OK,
      "text/html; charset=utf-8",
      @utf8.encode(page_html),
    ).to_responder()
  })
  app.get("/health", async fn(_ev) { handle_health(store, port).to_responder() })
  app.get("/skill.md", async fn(_ev) { handle_skill().to_responder() })
  app.get("/:file", async fn(ev) {
    match ev.param("file") {
      Some(name) => handle_snapshot(store, name).to_responder()
      None => not_found("/").to_responder()
    }
  })
  app.get("/**", async fn(ev) { not_found(ev.req.path()).to_responder() })
  app
}
