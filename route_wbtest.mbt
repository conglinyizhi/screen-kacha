///|
async test "router：精确匹配" {
  let r = Router::new()
  r.get("/a", fn(_req) { text_res(200, "a") })
  let res = r.dispatch("GET", "/a", {}, b"")
  assert_eq(res.status, 200)
  assert_eq(@utf8.decode(res.body), "a")
}

///|
async test "router：精确优先于单段参数" {
  let r = Router::new()
  r.get("/:file", fn(_req) { text_res(404, "param") })
  r.get("/health", fn(_req) { text_res(200, "health") })
  let res = r.dispatch("GET", "/health", {}, b"")
  assert_eq(res.status, 200)
}

///|
async test "router：重复斜杠被折掉" {
  let r = Router::new()
  r.get("/health", fn(_req) { text_res(200, "ok") })
  let res = r.dispatch("GET", "//health", {}, b"")
  assert_eq(res.status, 200)
}

///|
async test "router：非 GET/HEAD 走 405" {
  let r = Router::new()
  r.get("/a", fn(_req) { text_res(200, "a") })
  let res = r.dispatch("POST", "/a", {}, b"")
  assert_eq(res.status, 405)
}
