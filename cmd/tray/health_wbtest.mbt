///|
/// 正常：pipewire 在 streaming、帧是新的 → 绿灯，悬停文案带来源和耗时。
test "健康判定：pipewire 正常亮绿灯" {
  let body = "{\"ok\": true, \"stalled\": false, \"frame_age_ms\": 7, \"cap_ms\": 25, \"count\": 42, \"fails\": 0, \"err\": \"\", \"port\": 8930, \"source\": \"pipewire\", \"access\": \"仅本机\", \"stream_state\": 3, \"target_node\": 78}"
  let st = judge_health(parse_health(body))
  assert_eq(st.icon, "screen-kacha-ok")
  assert_eq(st.title, "screen-kacha · pipewire · 帧龄 7ms · 采集 25ms")
}

///|
/// 回退到 spectacle：画面还在（ok 仍是 true），但快路径丢了 → 黄灯。
///
/// 这是这次要修的主症状：旧代码只看 ok，这种状态亮的是绿灯。
test "健康判定：退回 spectacle 亮黄灯并带上回退原因" {
  let body = "{\"ok\": true, \"stalled\": false, \"frame_age_ms\": 120, \"cap_ms\": 650, \"count\": 8, \"err\": \"流 6123ms 没有新帧，已退回 spectacle\", \"source\": \"spectacle\", \"stream_state\": 0}"
  let st = judge_health(parse_health(body))
  assert_eq(st.icon, "screen-kacha-warn")
  assert_eq(
    st.title,
    "screen-kacha · 已退回 spectacle：流 6123ms 没有新帧，已退回 spectacle · 帧龄 120ms · 采集 650ms",
  )
}

///|
/// 退回 spectacle 但没有原因（err 是空串）时，别在文案里留个空冒号。
test "健康判定：退回 spectacle 没有原因时不留空冒号" {
  let body = "{\"ok\": true, \"stalled\": false, \"frame_age_ms\": 120, \"cap_ms\": 650, \"count\": 8, \"err\": \"\", \"source\": \"spectacle\", \"stream_state\": 0}"
  let st = judge_health(parse_health(body))
  assert_eq(st.icon, "screen-kacha-warn")
  assert_eq(
    st.title,
    "screen-kacha · 已退回 spectacle · 帧龄 120ms · 采集 650ms",
  )
}

///|
/// ok 为假 → 红灯，err 里的原因要带出来。
test "健康判定：ok 为假亮红灯并带上 err" {
  let body = "{\"ok\": false, \"stalled\": false, \"frame_age_ms\": 900, \"cap_ms\": 0, \"count\": 12, \"err\": \"spectacle 退出码 1\", \"source\": \"spectacle\", \"stream_state\": 0}"
  let st = judge_health(parse_health(body))
  assert_eq(st.icon, "screen-kacha-down")
  assert_eq(st.title, "screen-kacha · 采集失败：spectacle 退出码 1")
}

///|
/// ok 为假但没有任何说明：只说「采集失败」，不留空冒号。
test "健康判定：采集失败没有 err 时只说采集失败" {
  let body = "{\"ok\": false, \"stalled\": false, \"frame_age_ms\": -1, \"cap_ms\": 0, \"count\": 0, \"err\": \"\", \"source\": \"pipewire\", \"stream_state\": 1}"
  let st = judge_health(parse_health(body))
  assert_eq(st.icon, "screen-kacha-down")
  assert_eq(st.title, "screen-kacha · 采集失败")
}

///|
/// stalled 为真 → 红灯。ok 可能是 true（帧还在缓存里），灯不能跟着绿。
test "健康判定：stalled 为真亮红灯" {
  let body = "{\"ok\": true, \"stalled\": true, \"frame_age_ms\": 9100, \"cap_ms\": 30, \"count\": 300, \"err\": \"流状态 2 不是 streaming 已经 6100ms（宽限 3000ms）\", \"source\": \"pipewire\", \"stream_state\": 2}"
  let st = judge_health(parse_health(body))
  assert_eq(st.icon, "screen-kacha-down")
  assert_eq(
    st.title,
    "screen-kacha · 采集失败：流状态 2 不是 streaming 已经 6100ms（宽限 3000ms）",
  )
}

///|
/// 刚起来的服务：一帧都还没抓到 → 黄灯。
test "健康判定：还没抓到帧亮黄灯" {
  // 帧缓存已经有一份、ok 也成立，但计数还是 0：这种组合只有刚起来、
  // 还没真正抓过帧的时候才出现。
  let body = "{\"ok\": true, \"stalled\": false, \"frame_age_ms\": -1, \"cap_ms\": 0, \"count\": 0, \"err\": \"\", \"source\": \"pipewire\", \"stream_state\": 3}"
  let st = judge_health(parse_health(body))
  assert_eq(st.icon, "screen-kacha-warn")
  assert_eq(st.title, "screen-kacha · 已启动，还没抓到帧")
}

///|
/// 连不上：curl 没拿到任何东西 → 灰灯。
test "健康判定：空响应亮灰灯" {
  let st = judge_health(parse_health(""))
  assert_eq(st.icon, "screen-kacha-dead")
  assert_eq(st.title, "screen-kacha · 服务没响应")
}

///|
/// 正文是畸形 JSON（被截断的响应、代理塞进来的错误页）→ 灰灯，
/// 不能因为里面恰好有 `"ok": true` 就亮绿。
test "健康判定：畸形 JSON 当没响应" {
  let st = judge_health(parse_health("{\"ok\": true, \"count\": 4"))
  assert_eq(st.icon, "screen-kacha-dead")
  assert_eq(st.title, "screen-kacha · 服务没响应")
}

///|
/// 顶层不是对象（数组、字符串、null）也不认。
test "健康判定：顶层不是对象当没响应" {
  for body in ["[]", "\"ok\"", "null", "42"] {
    let st = judge_health(parse_health(body))
    assert_eq(st.icon, "screen-kacha-dead")
    assert_eq(st.title, "screen-kacha · 服务没响应")
  }
}

///|
/// 回归：`err` 里带着 `"ok": true` 字样的失败响应必须判成失败。
///
/// 锁住「别再退回子串匹配」：只要判定靠的是在正文里找片段，
/// 这种正文就会被读成健康。
test "健康判定：err 里带 ok 字样仍然是采集失败" {
  let body = "{\"ok\": false, \"stalled\": false, \"frame_age_ms\": 4000, \"cap_ms\": 0, \"count\": 51, \"err\": \"上游返回 \\\"ok\\\": true 但这一帧是空的\", \"source\": \"pipewire\", \"stream_state\": 3}"
  let st = judge_health(parse_health(body))
  assert_eq(st.icon, "screen-kacha-down")
  assert_eq(
    st.title,
    "screen-kacha · 采集失败：上游返回 \"ok\": true 但这一帧是空的",
  )
}

///|
/// 回归加强：正文别处出现形如顶层字段的 `"ok": true`（这里是嵌套对象），
/// 顶层 `ok` 是 false，仍要判红。
///
/// 这条是真能抓住子串判定的：`contains("\"ok\": true")` 会命中内层那个。
/// 现在的 `/health` 不会嵌套，但判定按 JSON 结构走，不该被正文里任何
/// 「长得像字段」的文字带跑。
test "健康判定：别处的 ok 字段不能冒充顶层" {
  let body = "{\"ok\": false, \"echo\": {\"ok\": true}, \"stalled\": false, \"frame_age_ms\": 700, \"cap_ms\": 0, \"count\": 3, \"err\": \"编码器返回 5\", \"source\": \"pipewire\", \"stream_state\": 3}"
  let st = judge_health(parse_health(body))
  assert_eq(st.icon, "screen-kacha-down")
  assert_eq(st.title, "screen-kacha · 采集失败：编码器返回 5")
}

///|
/// 格式变了也要认：`"ok":true` 不带空格、键序打乱，解析照样成立。
///
/// 旧代码认的是 `"ok": true` 这个带固定空格的片段，服务端一改序列化
/// 方式就会把健康读成失败。
test "健康判定：不带空格的 JSON 也要认" {
  let body = "{\"source\":\"pipewire\",\"stream_state\":3,\"ok\":true,\"stalled\":false,\"count\":5,\"frame_age_ms\":12,\"cap_ms\":18,\"err\":\"\"}"
  let st = judge_health(parse_health(body))
  assert_eq(st.icon, "screen-kacha-ok")
  assert_eq(st.title, "screen-kacha · pipewire · 帧龄 12ms · 采集 18ms")
}

///|
/// 字段类型不对（`"ok": "true"` 是字符串）时按缺省值处理，判红。
///
/// 宁可错报一次失败，也不能把非布尔值当成真：那等于又回到「正文里有
/// true 就算正常」。
test "健康判定：字段类型不对不当作真" {
  let body = "{\"ok\": \"true\", \"stalled\": false, \"count\": 7, \"source\": \"pipewire\", \"stream_state\": 3, \"frame_age_ms\": 10, \"cap_ms\": 20, \"err\": \"\"}"
  let st = judge_health(parse_health(body))
  assert_eq(st.icon, "screen-kacha-down")
  assert_eq(st.title, "screen-kacha · 采集失败")
}

///|
/// 来源是 pipewire、但流没在 streaming：宽限期内 ok 还是 true，
/// 灯也得是黄的，不能报正常。
test "健康判定：pipewire 未 streaming 亮黄灯" {
  let body = "{\"ok\": true, \"stalled\": false, \"frame_age_ms\": 40, \"cap_ms\": 26, \"count\": 9, \"err\": \"\", \"source\": \"pipewire\", \"stream_state\": 2}"
  let st = judge_health(parse_health(body))
  assert_eq(st.icon, "screen-kacha-warn")
  assert_eq(
    st.title,
    "screen-kacha · pipewire 未在 streaming（状态 2）· 帧龄 40ms · 采集 26ms",
  )
}

///|
/// 退回 spectacle 但一帧都还没抓到：文案说「还没有帧」，
/// 不把服务端内部哨兵值 -1ms 摆给用户看。
test "健康判定：回退时还没帧不留 -1ms" {
  let body = "{\"ok\": true, \"stalled\": false, \"frame_age_ms\": -1, \"cap_ms\": 0, \"count\": 0, \"err\": \"\", \"source\": \"spectacle\", \"stream_state\": 0}"
  let st = judge_health(parse_health(body))
  assert_eq(st.icon, "screen-kacha-warn")
  assert_eq(st.title, "screen-kacha · 已退回 spectacle · 还没有帧")
}

///|
/// `fake` 来源（测试和冒烟脚本用）不是降级：只要 ok、有帧就亮绿灯，
/// 文案如实写来源。
test "健康判定：fake 来源不算降级" {
  let body = "{\"ok\": true, \"stalled\": false, \"frame_age_ms\": 3, \"cap_ms\": 1, \"count\": 100, \"err\": \"\", \"source\": \"fake\", \"stream_state\": 0}"
  let st = judge_health(parse_health(body))
  assert_eq(st.icon, "screen-kacha-ok")
  assert_eq(st.title, "screen-kacha · fake · 帧龄 3ms · 采集 1ms")
}
