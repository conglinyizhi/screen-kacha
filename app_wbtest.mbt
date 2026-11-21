///|
/// 断言响应头等于期望值，缺头直接失败。
fn expect_header(
  headers : Map[String, String],
  name : String,
  want : String,
) -> Unit raise {
  match headers.get(name) {
    Some(v) => assert_eq(v, want)
    None => {
      println("缺少响应头 \{name}")
      assert_true(false)
    }
  }
}

///|
test "make_res 带上状态、类型与 no-store" {
  let res = make_res(@crescent.StatusCode::OK, "text/plain", b"hi")
  assert_true(res.status_code is @crescent.StatusCode::OK)
  expect_header(res.headers, "Content-Type", "text/plain")
  expect_header(res.headers, "Cache-Control", "no-store")
  assert_eq(@utf8.decode(res.raw_body), "hi")
}

///|
test "404 文案包含路径与 skill.md 指路" {
  let text = not_found_text("/a/b")
  assert_true(text.contains("/a/b"))
  assert_true(text.contains("/skill.md"))
}

///|
test "not_found 返回 404 与 text/plain" {
  let res = not_found("/x")
  assert_true(res.status_code is @crescent.StatusCode::NotFound)
  expect_header(res.headers, "Content-Type", "text/plain; charset=utf-8")
  assert_true(@utf8.decode(res.raw_body).contains("/x"))
}

///|
test "Store 初始状态为空" {
  let store = Store::new(shot="/tmp/none.jpg")
  assert_true(store.bytes() is None)
  assert_eq(store.age_ms(), -1L)
  assert_eq(store.count(), 0)
  assert_eq(store.fails(), 0)
  assert_eq(store.err(), "")
  assert_eq(store.shot(), "/tmp/none.jpg")
}

///|
test "next_tmp 带时间戳和 pid，不撞名" {
  let store = Store::new(shot="/tmp/none.jpg")
  let a = store.next_tmp("jpg")
  let b = store.next_tmp("webp")
  // 同一进程内两次调用不能撞
  assert_true(a != b)
  // 扩展名对
  assert_true(a.has_suffix(".jpg"))
  assert_true(b.has_suffix(".webp"))
  // 前缀对，中间是时间戳-pid-序号这种结构化名字
  assert_true(a.has_prefix("/tmp/screenstream-mb-"))
  // 不能再是纯序号那套（那种重启就撞名）
  assert_false(a == "/tmp/screenstream-mb-1.jpg")
}

///|
test "health 初始状态字段齐全" {
  let store = Store::new(shot="/tmp/none.jpg")
  let res = handle_health(store, 18940)
  let body = @utf8.decode(res.raw_body)
  assert_true(body.contains("\"ok\": false"))
  assert_true(body.contains("\"count\": 0"))
  assert_true(body.contains("\"port\": 18940"))
  assert_true(body.contains("\"frame_age_ms\": -1"))
  expect_header(res.headers, "Content-Type", "application/json")
}

///|
/// 根路径按 Accept 分叉：浏览器拿到页面，其它拿到 llms.txt 原文。
/// 这里两种请求都走一遍，锁住「agent 不该看到 HTML」这条。
async test "路由：首页按 Accept 分叉" {
  let app = build_app(Store::new(shot="/tmp/none.jpg"), 8930)

  // 浏览器
  let (code, headers, body) = app.dispatch(
    "GET",
    "/",
    { "accept": "text/html,application/xhtml+xml,*/*;q=0.8" },
    b"",
  )
  assert_true(code is @crescent.StatusCode::OK)
  expect_header(headers, "Content-Type", "text/html; charset=utf-8")
  assert_true(@utf8.decode(body).contains("<!doctype html>"))

  // curl / agent：不带 Accept
  let (code2, headers2, body2) = app.dispatch("GET", "/", {}, b"")
  assert_true(code2 is @crescent.StatusCode::OK)
  expect_header(headers2, "Content-Type", "text/plain; charset=utf-8")
  let text = @utf8.decode(body2)
  assert_true(text.contains("/snapshot.jpg"))
  assert_false(text.contains("<html"))

  // /human.html 永远给页面，不管 Accept
  let (code3, headers3, _) = app.dispatch("GET", "/human.html", {}, b"")
  assert_true(code3 is @crescent.StatusCode::OK)
  expect_header(headers3, "Content-Type", "text/html; charset=utf-8")
}

///|
async test "路由：health 返回 JSON" {
  let app = build_app(Store::new(shot="/tmp/none.jpg"), 8930)
  let (code, headers, body) = app.dispatch("GET", "/health", {}, b"")
  assert_true(code is @crescent.StatusCode::OK)
  expect_header(headers, "Content-Type", "application/json")
  assert_true(@utf8.decode(body).contains("\"ok\""))
}

///|
async test "路由：skill.md 返回 markdown" {
  let app = build_app(Store::new(shot="/tmp/none.jpg"), 8930)
  let (code, headers, body) = app.dispatch("GET", "/skill.md", {}, b"")
  assert_true(code is @crescent.StatusCode::OK)
  expect_header(headers, "Content-Type", "text/markdown; charset=utf-8")
  assert_true(@utf8.decode(body).length() > 0)
}

///|
async test "路由：未知路径走 404 引导" {
  let app = build_app(Store::new(shot="/tmp/none.jpg"), 8930)
  let (code, headers, body) = app.dispatch("GET", "/nope", {}, b"")
  assert_true(code is @crescent.StatusCode::NotFound)
  expect_header(headers, "Content-Type", "text/plain; charset=utf-8")
  assert_true(@utf8.decode(body).contains("/skill.md"))
}

///|
async test "路由：多段未知路径也走 404" {
  let app = build_app(Store::new(shot="/tmp/none.jpg"), 8930)
  let (code, _, _) = app.dispatch("GET", "/a/b/c", {}, b"")
  assert_true(code is @crescent.StatusCode::NotFound)
}

///|
async test "路由：非法快照名不触发采集，直接 404" {
  let app = build_app(Store::new(shot="/tmp/none.jpg"), 8930)
  for path in ["/snapshot.png", "/snapshot-abc.jpg", "/snapshotx.jpg"] {
    let (code, _, _) = app.dispatch("GET", path, {}, b"")
    assert_true(code is @crescent.StatusCode::NotFound)
  }
}

///|
test "render_plan：不需要 magick 时直通" {
  assert_true(render_plan(None, "jpg", true) is RenderPlan::Passthrough)
  assert_true(render_plan(None, "jpg", false) is RenderPlan::Passthrough)
}

///|
test "render_plan：缺 magick 时降级而不是报错" {
  assert_true(render_plan(Some(1280), "jpg", false) is RenderPlan::Downgrade)
  assert_true(render_plan(None, "webp", false) is RenderPlan::Downgrade)
}

///|
test "render_plan：有 magick 时正常渲染" {
  assert_true(render_plan(Some(1280), "jpg", true) is RenderPlan::Render)
  assert_true(render_plan(None, "webp", true) is RenderPlan::Render)
}

///|
async test "find_magick：按顺序取第一个存在的" {
  match find_magick(["/nonexistent-a", "/bin/sh", "/bin/ls"]) {
    Some(p) => assert_eq(p, "/bin/sh")
    None => assert_true(false)
  }
  match find_magick(["/nonexistent-a", "/nonexistent-b"]) {
    Some(_) => assert_true(false)
    None => assert_true(true)
  }
}

///|
async test "record_ok 与 record_fail 正确累计" {
  let store = Store::new(shot="/tmp/none.jpg")
  store.record_fail("spectacle 退出码 1")
  assert_eq(store.fails(), 1)
  assert_eq(store.count(), 0)
  assert_eq(store.err(), "spectacle 退出码 1")
  store.record_ok(b"abc", 42L)
  assert_eq(store.count(), 1)
  assert_eq(store.cap_ms(), 42L)
  assert_eq(store.err(), "")
  assert_eq(store.bytes(), Some(b"abc"))
  assert_true(store.age_ms() >= 0L)
}

///|
test "health 里带 magick 标志" {
  let with_magick = Store::new(
    shot="/tmp/none.jpg",
    magick=Some("/usr/bin/magick"),
  )
  let without = Store::new(shot="/tmp/none.jpg")
  assert_true(
    @utf8.decode(handle_health(with_magick, 1).raw_body).contains(
      "\"magick\": true",
    ),
  )
  assert_true(
    @utf8.decode(handle_health(without, 1).raw_body).contains(
      "\"magick\": false",
    ),
  )
}

///|
async test "缺 magick 时缩放请求退回原图，并带标记头" {
  let store = Store::new(shot="/tmp/none.jpg")
  store.record_ok(b"ORIGINAL", 1L)
  let res = build_image_response(store, b"ORIGINAL", Some(640), "jpg", None)
  assert_true(res.status_code is @crescent.StatusCode::OK)
  expect_header(res.headers, "Content-Type", "image/jpeg")
  expect_header(res.headers, "X-Screenstream-Fallback", "no-magick")
  assert_eq(res.raw_body, b"ORIGINAL")
}

///|
async test "缺 magick 时 WebP 请求同样退回 JPEG" {
  let store = Store::new(shot="/tmp/none.jpg")
  let res = build_image_response(store, b"RAW", None, "webp", None)
  expect_header(res.headers, "Content-Type", "image/jpeg")
  expect_header(res.headers, "X-Screenstream-Fallback", "no-magick")
  assert_eq(res.raw_body, b"RAW")
}

///|
async test "不需要换算时直通原字节，不带降级头" {
  let store = Store::new(shot="/tmp/none.jpg", magick=Some("/usr/bin/magick"))
  let res = build_image_response(store, b"RAW", None, "jpg", None)
  assert_true(res.status_code is @crescent.StatusCode::OK)
  expect_header(res.headers, "Content-Type", "image/jpeg")
  match res.headers.get("X-Screenstream-Fallback") {
    Some(_) => assert_true(false)
    None => assert_true(true)
  }
  assert_eq(res.raw_body, b"RAW")
}

///|
test "wants_html 按 Accept 判断是不是浏览器" {
  // 浏览器
  assert_true(
    wants_html(
      Some("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"),
    ),
  )
  assert_true(wants_html(Some("TEXT/HTML")))
  // curl 默认、agent 常见、完全不带头
  assert_false(wants_html(Some("*/*")))
  assert_false(wants_html(Some("application/json")))
  assert_false(wants_html(None))
}

///|
test "ascii_lower 只动字母" {
  assert_eq(ascii_lower("TEXT/HTML"), "text/html")
  assert_eq(ascii_lower("aBc-123"), "abc-123")
  assert_eq(ascii_lower(""), "")
}
