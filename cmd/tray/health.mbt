///|
/// `/health` 里跟托盘判灯有关的那几个字段。
///
/// 只挑托盘用得上的：整份响应还有 fails、port、access、screen_w 这些，
/// 托盘一个都不看。收成这个结构以后，判定函数只吃标量，单测直接造数据，
/// 不用起服务、不用碰网络。
struct Health {
  /// 有帧、最近一次采集没失败、帧还在更新
  ok : Bool
  /// 看门狗判定流已经停了
  stalled : Bool
  /// 累计抓到多少帧
  count : Int32
  /// `pipewire` / `spectacle` / `fake`
  source : String
  /// `enum pw_stream_state` 的整数值，3 才是 streaming
  stream_state : Int32
  /// 帧有多旧；一帧都没抓到时服务报 -1
  frame_age_ms : Int32
  /// 最近一次采集花了多久
  cap_ms : Int32
  /// 最近一次失败或回退的原因，正常时是空串
  err : String
}

///|
/// 判定结果：图标名和悬停文案。
///
/// 两样一起给，是因为它们必须同源 —— 以前只算图标、把说明丢掉，
/// 结果灯是黄的却说不清为什么黄。
struct TrayState {
  icon : String
  title : String
}

///|
/// `enum pw_stream_state` 里的 streaming。
///
/// 取值和服务端 `source.mbt` 的 `STREAM_STATE_STREAMING` 一致（-1 错误、
/// 0 未连接、1 连接中、2 暂停、3 streaming），但这个包不链接根包
/// （理由见 `config_key` 那条注释），只能各留一份，改的时候要一起改。
const STREAM_STATE_STREAMING : Int32 = 3

///|
/// 从 JSON 对象里取布尔值。键不存在或类型不对就用默认值。
fn json_bool(obj : Map[String, @json.Json], key : String, dflt : Bool) -> Bool {
  match obj.get(key) {
    Some(@json.Json::True) => true
    Some(@json.Json::False) => false
    _ => dflt
  }
}

///|
/// 从 JSON 对象里取整数。服务端这些字段都是整数，浮点按截断取整。
fn json_int(obj : Map[String, @json.Json], key : String, dflt : Int32) -> Int32 {
  match obj.get(key) {
    Some(@json.Json::Number(n, ..)) => n.to_int()
    _ => dflt
  }
}

///|
/// 从 JSON 对象里取字符串。
fn json_str(
  obj : Map[String, @json.Json],
  key : String,
  dflt : String,
) -> String {
  match obj.get(key) {
    Some(@json.Json::String(s)) => s
    _ => dflt
  }
}

///|
/// 解析 `/health` 的正文。
///
/// 空串（curl 连不上时 `capture` 给的就是空串）、畸形 JSON、顶层不是对象，
/// 三种都返回 None —— 对托盘来说它们是一回事：没拿到能读的状态。
///
/// 以前这里是对正文做子串匹配（`body.contains("\"ok\": true")`），
/// 换个间距就认不出、`err` 里带同样的字样就误判。解析之后，
/// 「哪个字段是什么值」由 JSON 语法决定，不再靠猜。
fn parse_health(body : String) -> Health? {
  let parsed = @json.parse(body) catch { _ => return None }
  match parsed {
    @json.Json::Object(obj) =>
      Some({
        ok: json_bool(obj, "ok", false),
        stalled: json_bool(obj, "stalled", false),
        count: json_int(obj, "count", 0),
        source: json_str(obj, "source", ""),
        stream_state: json_int(obj, "stream_state", 0),
        frame_age_ms: json_int(obj, "frame_age_ms", -1),
        cap_ms: json_int(obj, "cap_ms", 0),
        err: json_str(obj, "err", ""),
      })
    _ => None
  }
}

///|
/// 「帧龄 7ms · 采集 25ms」。帧龄是负的（还没抓到过帧）就直说没有帧，
/// 不把 -1ms 这种服务端内部哨兵值摆到悬停提示里。
fn timing_text(h : Health) -> String {
  if h.frame_age_ms < 0 {
    "还没有帧"
  } else {
    "帧龄 \{h.frame_age_ms}ms · 采集 \{h.cap_ms}ms"
  }
}

///|
/// 按 `/health` 的字段判灯。纯函数：不看时间、不碰设备、不发请求。
///
/// 分支顺序就是优先级，命中就返回：
/// 1. 解析不了 → 灰（服务没响应）
/// 2. 采集失败或流已停 → 红，带上 `err` 的原因
/// 3. 退回 spectacle → 黄（快路径丢了，画面还在）
/// 4. 一帧还没抓到 → 黄
/// 5. pipewire 却不在 streaming → 黄（宽限期内 ok 仍是 true，别报绿）
/// 6. 其余 → 绿
///
/// 第 3 条是这次的重点：回退到 spectacle 时 `ok` 仍然是 true，
/// 旧代码据此亮绿灯，「快路径丢了」这件事在托盘上完全看不见。
fn judge_health(h : Health?) -> TrayState {
  let h = match h {
    Some(x) => x
    None =>
      return {
        icon: "screen-kacha-dead",
        title: "screen-kacha · 服务没响应",
      }
  }
  // 画面停在旧帧上，比「慢了一点」严重得多，所以排在最前面。
  if !h.ok || h.stalled {
    let title = if h.err.trim() == "" {
      "screen-kacha · 采集失败"
    } else {
      "screen-kacha · 采集失败：\{h.err}"
    }
    return { icon: "screen-kacha-down", title, }
  }
  if h.source == "spectacle" {
    let title = if h.err.trim() == "" {
      "screen-kacha · 已退回 spectacle · \{timing_text(h)}"
    } else {
      "screen-kacha · 已退回 spectacle：\{h.err} · \{timing_text(h)}"
    }
    return { icon: "screen-kacha-warn", title, }
  }
  // 一帧都没有时帧龄是 -1，`timing_text` 会说「还没有帧」，
  // 但这时候真正要说的原因是「刚起来，还没开始抓」。
  if h.count == 0 {
    return {
      icon: "screen-kacha-warn",
      title: "screen-kacha · 已启动，还没抓到帧",
    }
  }
  // 只看 source 不够：流掉出 streaming 之后，看门狗要等满宽限期才判死，
  // 这几秒里 ok 还是 true。状态它不是 streaming，就不是快路径。
  if h.source == "pipewire" && h.stream_state != STREAM_STATE_STREAMING {
    return {
      icon: "screen-kacha-warn",
      title: "screen-kacha · pipewire 未在 streaming（状态 \{h.stream_state}）· \{timing_text(h)}",
    }
  }
  {
    icon: "screen-kacha-ok",
    title: "screen-kacha · \{h.source} · \{timing_text(h)}",
  }
}
