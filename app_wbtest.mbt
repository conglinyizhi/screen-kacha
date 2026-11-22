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
  // 落在 Store 自己的目录里，文件名是时间戳-pid-序号这种结构化名字
  assert_true(a.has_prefix("/tmp/screenstream-mb/out-"))
  // 不能再是纯序号那套（那种重启就撞名）
  assert_false(a == "/tmp/screenstream-mb/out-1.jpg")
}

///|
/// 临时输出读完就删，不攒着。
///
/// 原来是「读完不管，靠 next_tmp 的环形滚动删最旧的」，而环上只留 10 个、
/// 并发上限却是 64：一批请求同时进来，最早的文件会被后面的人删掉，
/// 而它们可能正被读。现在读回只有一个入口，读完就地删。
async test "临时输出读完就删" {
  // 每个测试用自己的目录。
  //
  // MoonBit 的测试是并发跑的，而两个测试各自 new 一个 Store，seq 都从 1 开始、
  // 进程号相同、时间戳可能落在同一毫秒 —— 路径会撞在一起，一个测试把另一个
  // 正在用的文件删掉。（这个坑在光标那组测试里踩过一次。）
  let dir = "/tmp/ssmb-tmp-del-a"
  let store = Store::new(shot="/tmp/none.jpg", tmp_dir=dir)
  @fs.mkdir(dir, permission=0o700, recursive=true) catch {
    _ => ()
  }
  // 造一个文件当编码器产物
  let out = store.next_tmp("jpg")
  @fs.write_file(out, b"payload", create_mode=CreateOrTruncate) catch {
    _ => ()
  }
  assert_true(@fs.exists(out) catch { _ => false })
  let got = read_result(out, true)
  assert_eq(got, Some(b"payload"))
  // 读完就没了
  assert_false(@fs.exists(out) catch { _ => true })
}

///|
/// 编码失败时也要把可能建了一半的文件清掉。
async test "编码失败时清掉半成品" {
  let dir = "/tmp/ssmb-tmp-del-b"
  let store = Store::new(shot="/tmp/none.jpg", tmp_dir=dir)
  @fs.mkdir(dir, permission=0o700, recursive=true) catch {
    _ => ()
  }
  let out = store.next_tmp("jpg")
  @fs.write_file(out, b"half", create_mode=CreateOrTruncate) catch {
    _ => ()
  }
  assert_true(read_result(out, false) is None)
  assert_false(@fs.exists(out) catch { _ => true })
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

///|
/// 拒绝路径上的超时必须用短的那个。
///
/// 原来写响应借的是 `WRITE_TIMEOUT_MS`（15 秒），跟注释说的「拒绝路径用短超时」
/// 相反：一个不读响应的来源能白占槽位 15 秒。这条锁住「拒绝永远用短超时」。
test "拒绝路径用的是短超时" {
  assert_true(reject_timeout_ms() < WRITE_TIMEOUT_MS)
  assert_eq(reject_timeout_ms(), REJECT_TIMEOUT_MS)
}

///|
/// 临时输出落在 Store 自己的目录里，不再散在 /tmp 根下。
///
/// 原来直接写 `/tmp/screenstream-mb-<时间>-<pid>-<序号>.jpg`：目录谁都能读、
/// 名字可预测，截图还是 0644，本机别的用户能直接看到屏幕内容。
test "临时输出落在私有目录里" {
  let store = Store::new(shot="/tmp/none.jpg", tmp_dir="/tmp/ssmb-test-tmp")
  let p = store.next_tmp("jpg")
  assert_true(p.has_prefix("/tmp/ssmb-test-tmp/"))
  assert_false(p.has_prefix("/tmp/screenstream-mb-"))
}

///|
/// JSON 里的引号必须成对：扫一遍，看完还停在「字符串内部」就算坏了。
///
/// 这不是完整的 JSON 解析器，但正好能抓住拼字符串漏转义这类错误：
/// 值里冒出一个没转义的引号，后面的引号就全错位，结尾一定停在字符串里。
fn json_quotes_balanced(s : String) -> Bool {
  let n = s.length()
  let mut i = 0
  let mut in_str = false
  while i < n {
    let c = s[i].to_int()
    if in_str && c == 92 {
      // 反斜杠转义：跳过下一个字符
      i = i + 2
      continue
    }
    if c == 34 {
      in_str = !in_str
    }
    i = i + 1
  }
  !in_str
}

///|
/// `/health` 的值里有引号、换行、控制字符时，正文仍然是合法 JSON。
///
/// 原来是手拼字符串，`allow` 名单里带一个引号就把整个 JSON 拼断了：
/// 实测 `allow = 10.0.0.1"x` 时 python 的 `json.load` 直接报
/// `Expecting ',' delimiter`。托盘又靠字符串匹配读这个 JSON，坏了它也瞎。
test "health 的 JSON 对引号和换行做转义" {
  // 转义本身
  assert_eq(json_escape_text("a\"b"), "a\\\"b")
  assert_eq(json_escape_text("a\\b"), "a\\\\b")
  assert_eq(json_escape_text("a\nb"), "a\\nb")
  assert_eq(json_escape_text("a\tb"), "a\\tb")
  assert_eq(json_escape_text("a\rb"), "a\\rb")
  // 控制字符走 \u00XX
  assert_eq(json_escape_text("\u{01}"), "\\u0001")
  // 多字节原样透传，别被拆坏
  assert_eq(json_escape_text("中文"), "中文")
  assert_eq(json_escape_text("🙂"), "🙂")

  // 端到端：错误信息带引号和换行，access 名单带引号
  let store = Store::new(shot="/tmp/none.jpg")
  store.record_fail("boom \"quoted\"\nsecond line")
  let access = parse_access("allow_lan = true\nallow = 10.0.0.1\"x")
  let json = health_json(store, 8930, access)
  assert_true(json_quotes_balanced(json))
  // 原文里的引号必须变成转义形式
  assert_true(json.contains("\\\"quoted\\\""))
  assert_true(json.contains("10.0.0.1\\\"x"))
  // 不能有裸换行进正文
  assert_false(json.contains("\n"))
}

///|
/// 累计失败只增不减，连续失败成功一次就清零。
///
/// 只有一个只增不减的计数器时，`/health` 看不出「现在是不是还在坏」：
/// 跑一天几千次成功也会留着历史失败数。
test "连续失败会清零，累计失败只增不减" {
  let store = Store::new(shot="/tmp/none.jpg")
  store.record_fail("坏了一次")
  store.record_fail("又坏一次")
  assert_eq(store.fails(), 2)
  assert_eq(store.consec_fails(), 2)
  store.record_ok(b"ok", 5L)
  assert_eq(store.fails(), 2)
  assert_eq(store.consec_fails(), 0)
  store.record_fail("再来")
  assert_eq(store.fails(), 3)
  assert_eq(store.consec_fails(), 1)
}

///|
/// 泵停了但没有采集错误时，也要能看出帧不再更新。
///
/// 只看 `err` 是看不出来的：线程整个卡死就没有任何一次采集失败。
test "帧不更新要能看出来，没人用的时候不算" {
  // 有人在取图（idle 小），帧却十分钟没动：停摆
  assert_true(frame_is_stalled(600000L, 100L, 500))
  // 刚取过图，帧是新的：正常
  assert_false(frame_is_stalled(300L, 100L, 500))
  // 没人取图，泵按设计放慢，帧旧是应该的
  assert_false(frame_is_stalled(600000L, 1L << 40, 500))
  // 一帧都还没有：那是「还没抓到」，不是「停摆」
  assert_false(frame_is_stalled(-1L, 100L, 500))
  // 边界：阈值是 pump*10 + 5000 = 10000
  assert_false(frame_is_stalled(9999L, 100L, 500))
  assert_true(frame_is_stalled(10001L, 100L, 500))
}

///|
/// 失败日志要降频：错误内容变了立刻记，同一个错误按倍数少量记。
test "失败日志降频，错误变了立刻记" {
  assert_true(should_log_failure(1, true))
  assert_false(should_log_failure(2, false))
  assert_false(should_log_failure(29, false))
  assert_true(should_log_failure(30, false))
  assert_true(should_log_failure(60, false))
  assert_false(should_log_failure(31, false))
}

///|
/// 光标合成失败要能看见：计数、原因，成功一次就清零。
///
/// 失败原来是完全静默的：素材打不开或者贴图失败，调用方拿到的仍是 200 的
/// 普通截图，托盘的开关还显示「已开启」。
test "光标合成失败会被记下来，成功一次就清零" {
  let store = Store::new(shot="/tmp/none.jpg")
  assert_eq(store.cursor_fails(), 0)
  store.note_cursor_fail("光标素材 PNG 读不出来")
  assert_eq(store.cursor_fails(), 1)
  assert_eq(store.cursor_err(), "光标素材 PNG 读不出来")
  store.note_cursor_fail("输出文件建不出来")
  assert_eq(store.cursor_fails(), 2)
  assert_eq(store.cursor_err(), "输出文件建不出来")
  store.note_cursor_ok()
  assert_eq(store.cursor_fails(), 0)
  assert_eq(store.cursor_err(), "")
}

///|
/// 素材和文档的路径跟着 data_dir 走，绝对路径不动。
///
/// 原来直接用相对文件名，只有进程工作目录正好是安装目录时才找得到。
test "data_path 按 data_dir 拼，绝对路径原样" {
  let with_dir = Store::new(shot="/tmp/none.jpg", data_dir="/opt/ss")
  assert_eq(with_dir.data_path("cursor-arrow.png"), "/opt/ss/cursor-arrow.png")
  assert_eq(with_dir.data_path("/abs/x.png"), "/abs/x.png")
  let plain = Store::new(shot="/tmp/none.jpg")
  assert_eq(plain.data_path("cursor-arrow.png"), "cursor-arrow.png")
}

///|
/// 缺文档只报第一次，别让 agent 的反复轮询把 journal 冲掉。
test "缺文档只报第一次" {
  let store = Store::new(shot="/tmp/none.jpg")
  assert_true(store.note_missing_doc("llms.txt"))
  assert_false(store.note_missing_doc("llms.txt"))
  assert_true(store.note_missing_doc("skill.md"))
}

///|
/// 光标返回码要翻成人话，别只丢一个数字。
test "光标返回码有对应文案" {
  assert_eq(cursor_code_text(7), "光标素材 PNG 读不出来")
  assert_eq(cursor_code_text(2), "源画面解码失败")
  assert_true(cursor_code_text(99).contains("未知"))
}

///|
/// /health 里能查到光标为什么没画出来。
test "health 暴露光标失败计数" {
  let store = Store::new(shot="/tmp/none.jpg")
  store.note_cursor_fail("光标素材 PNG 读不出来")
  let json = health_json(store, 8930, Access::default())
  assert_true(json.contains("\"cursor_fails\": 1"))
  assert_true(json.contains("光标素材 PNG 读不出来"))
  assert_true(json_quotes_balanced(json))
}

///|
/// 停一个没启动的流是空操作，不能崩、不能改状态。
///
/// 重连路径现在会先 disconnect() 再 connect()（会话过期后要真的重来），
/// 所以「没启动时停止」会被经常调到。
test "停一个没启动的 PipeWire 流是空操作" {
  let pw = @pipewire.PipeWire::new()
  assert_false(pw.started())
  pw.disconnect()
  assert_false(pw.started())
  // 再来一次也还是空操作
  pw.disconnect()
  assert_false(pw.started())
}
