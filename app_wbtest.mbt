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
/// 临时文件列表滚动：超过上限就丢最旧的，而不是无限涨。
///
/// 三个调用点都是「建文件 → 写 → 读 → 返回」，读完从不删，
/// 所以每次请求都会在 /tmp 留一个。没有这个滚动，请求一多就一直涨。
test "临时文件列表滚动，不超过上限" {
  let store = Store::new(shot="/tmp/none.jpg")
  let mut first = ""
  for i = 0; i < 40; i = i + 1 {
    let p = store.next_tmp("jpg")
    if i == 0 {
      first = p
    }
  }
  // 列表长度被压在上限以内
  assert_true(store.tmp_ring.length() <= 10)
  // 最早那个已经被滚出去了
  assert_false(store.tmp_ring.contains(first))
}

///|
/// 刚建的那个绝不能被自己的滚动删掉 —— 返回路径之后调用方还要往里写。
test "滚动不会删掉刚返回的路径" {
  let store = Store::new(shot="/tmp/none.jpg")
  for i = 0; i < 30; i = i + 1 {
    let p = store.next_tmp("jpg")
    assert_true(store.tmp_ring.contains(p))
  }
}

///|
test "health 初始状态字段齐全" {
  let store = Store::new(shot="/tmp/none.jpg")
  let res = handle_health(store, 18940, Access::default())
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
  let app = build_app(Store::new(shot="/tmp/none.jpg"), 8930, Access::default())

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
  let app = build_app(Store::new(shot="/tmp/none.jpg"), 8930, Access::default())
  let (code, headers, body) = app.dispatch("GET", "/health", {}, b"")
  assert_true(code is @crescent.StatusCode::OK)
  expect_header(headers, "Content-Type", "application/json")
  assert_true(@utf8.decode(body).contains("\"ok\""))
}

///|
async test "路由：skill.md 返回 markdown" {
  let app = build_app(Store::new(shot="/tmp/none.jpg"), 8930, Access::default())
  let (code, headers, body) = app.dispatch("GET", "/skill.md", {}, b"")
  assert_true(code is @crescent.StatusCode::OK)
  expect_header(headers, "Content-Type", "text/markdown; charset=utf-8")
  assert_true(@utf8.decode(body).length() > 0)
}

///|
async test "路由：未知路径走 404 引导" {
  let app = build_app(Store::new(shot="/tmp/none.jpg"), 8930, Access::default())
  let (code, headers, body) = app.dispatch("GET", "/nope", {}, b"")
  assert_true(code is @crescent.StatusCode::NotFound)
  expect_header(headers, "Content-Type", "text/plain; charset=utf-8")
  assert_true(@utf8.decode(body).contains("/skill.md"))
}

///|
async test "路由：多段未知路径也走 404" {
  let app = build_app(Store::new(shot="/tmp/none.jpg"), 8930, Access::default())
  let (code, _, _) = app.dispatch("GET", "/a/b/c", {}, b"")
  assert_true(code is @crescent.StatusCode::NotFound)
}

///|
async test "路由：非法快照名不触发采集，直接 404" {
  let app = build_app(Store::new(shot="/tmp/none.jpg"), 8930, Access::default())
  for path in ["/snapshot.png", "/snapshot-abc.jpg", "/snapshotx.jpg"] {
    let (code, _, _) = app.dispatch("GET", path, {}, b"")
    assert_true(code is @crescent.StatusCode::NotFound)
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
async test "不需要换算时直通原字节" {
  let store = Store::new(shot="/tmp/none.jpg")
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

///|
/// `age` 的解析必须有长度上限。
///
/// 没有上限时，`0.` 后面跟 64 个 0 会让 frac_scale 乘过 Int64 回绕成 0，
/// 最后那步 `frac * 1000 / frac_scale` 直接除零，进程 SIGFPE 死掉。
/// 一个 GET 就能把服务打崩，所以这条要锁死。
test "age 小数位数有上限，不会除零" {
  // 正常值先锁住，免得修过头
  assert_eq(parse_seconds_ms("5"), Some(5000L))
  assert_eq(parse_seconds_ms("0.05"), Some(50L))
  assert_eq(parse_seconds_ms("1.5"), Some(1500L))
  assert_eq(parse_seconds_ms(".5"), Some(500L))
  assert_eq(parse_seconds_ms("60."), Some(60000L))
  // 崩溃用例：64 个 0
  let long = StringBuilder()
  long.write_string("0.")
  for _ in 0..<64 {
    long.write_char('0')
  }
  assert_true(parse_seconds_ms(long.to_string().exact_view()) is None)
  // 刚刚超出上限的小数位数
  assert_true(parse_seconds_ms("0.1234567890") is None)
  // 整数部分同样不能无限长
  assert_true(parse_seconds_ms("1234567890") is None)
}

///|
/// 格式不对一律 None，不猜。
test "age 非法格式返回 None" {
  assert_true(parse_seconds_ms("") is None)
  assert_true(parse_seconds_ms("abc") is None)
  assert_true(parse_seconds_ms("1.2.3") is None)
  assert_true(parse_seconds_ms("-1") is None)
  assert_true(parse_seconds_ms("1 2") is None)
  assert_true(parse_seconds_ms("0x10") is None)
}

///|
/// 降级之后必须继续去申请，不能退出监督循环。
///
/// 原来的 `portal_bg` 第一次连上就 `return`，for 循环直接结束。之后会话过期、
/// KWin 重启让 `pw` 掉回 false，没有任何人再去申请，服务就永久停在 spectacle
/// 慢路径上，而 `/health` 只显示 `source=spectacle`，看着像「正常回退」。
/// 这条锁的是「降级 = 还要去要」这个判断，别让它再变成退出。
test "PipeWire 降级后仍然要去重新申请" {
  assert_true(portal_step(true) is Watch)
  assert_true(portal_step(false) is Reacquire)
}

///|
/// accept 出错要退避重试，只有连着失败很久才认输。
///
/// 原来是 `catch { _ => break }`：EMFILE / ECONNABORTED / EINTR 都被当成
/// 「正常收工」，循环直接退出，进程以 0 结束。单元写的是 Restart=on-failure，
/// systemd 不会拉起，服务静默消失。这条锁住「别一有错就认输」。
test "accept 连续失败要给够次数才放弃" {
  assert_false(accept_gave_up(0))
  assert_false(accept_gave_up(1))
  // 瞬时错误连着来几次很常见，不能在这时候就退出
  assert_false(accept_gave_up(10))
  assert_false(accept_gave_up(99))
  assert_true(accept_gave_up(100))
  assert_true(accept_gave_up(101))
}

///|
/// 拒绝路径的并发上限要有界，并且比主上限小。
///
/// 原来拒绝分支不占任何槽位，未授权地址开上千个空闲连接就能把 fd 吃光。
/// 这条锁住「拒绝也要限流」和「别把槽位全给拒绝、饿死正常请求」。
test "拒绝路径的并发上限有界" {
  assert_eq(reject_slots(64), 8)
  assert_eq(reject_slots(256), 32)
  // 上限很小时至少给 4 个，不能算成 0 把自己卡死
  assert_eq(reject_slots(8), 4)
  assert_eq(reject_slots(1), 4)
  // 永远小于主上限，给正常请求留大头
  assert_true(reject_slots(1000) < 1000)
}
