///|
/// `dispatch` 按大写动词匹配路由，这里翻错了全部请求都会变成 405，
/// 而 405 在冒烟里只表现为「状态码不对」，不容易一眼看出根因。
test "verb_of 翻成大写 HTTP 动词" {
  assert_eq(verb_of(Get), "GET")
  assert_eq(verb_of(Head), "HEAD")
  assert_eq(verb_of(Post), "POST")
  assert_eq(verb_of(Put), "PUT")
  assert_eq(verb_of(Delete), "DELETE")
  assert_eq(verb_of(Connect), "CONNECT")
  assert_eq(verb_of(Options), "OPTIONS")
  assert_eq(verb_of(Trace), "TRACE")
  assert_eq(verb_of(Patch), "PATCH")
}

///|
/// 超时值本身没有对错，但配错了会很难查：读超时太长 = 慢客户端拖死服务，
/// handler 超时太短 = 正常的慢采集被当失败。这里只锁住「读不短于 handler、
/// 拒绝路径明显更短」这两条关系，防止以后随手改出反直觉的组合。
test "超时常量的关系是合理的" {
  assert_true(READ_TIMEOUT_MS >= HANDLER_TIMEOUT_MS)
  assert_true(REJECT_TIMEOUT_MS < READ_TIMEOUT_MS)
  assert_true(WRITE_TIMEOUT_MS > 0)
}
