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
test "next_tmp 依次递增" {
  let store = Store::new(shot="/tmp/none.jpg")
  assert_eq(store.next_tmp("jpg"), "/tmp/screenstream-mb-1.jpg")
  assert_eq(store.next_tmp("webp"), "/tmp/screenstream-mb-2.webp")
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
async test "路由：首页返回 HTML" {
  let app = build_app(Store::new(shot="/tmp/none.jpg"), 8930)
  let (code, headers, body) = app.dispatch("GET", "/", {}, b"")
  assert_true(code is @crescent.StatusCode::OK)
  expect_header(headers, "Content-Type", "text/html; charset=utf-8")
  assert_true(@utf8.decode(body).contains("<!doctype html>"))
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
