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

///|
test "percent_decode：合法转义和保守回退" {
  assert_eq(percent_decode("0.1%20"), "0.1 ")
  assert_eq(percent_decode("%2C"), ",")
  assert_eq(percent_decode("a+b"), "a b")
  // 不合法就原样保留，不猜
  assert_eq(percent_decode("%zz"), "%zz")
  assert_eq(percent_decode("%2"), "%2")
  assert_eq(percent_decode("100%"), "100%")
}

///|
test "查询串会做一次百分号解码" {
  let q = parse_query("/x?a=1%202&b=50%25")
  assert_eq(q.get("a"), Some("1 2"))
  assert_eq(q.get("b"), Some("50%"))
}
