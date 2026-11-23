///|
/// 一次请求，路由层能看到的东西。
///
/// 这里只保留服务自己用得到的：方法、路径、查询串、头、路径参数。
/// 请求体一律不读（本服务的接口都是 GET）。
pub struct Req {
  meth : String
  raw_path : String
  path : String
  headers : Map[String, String]
  query : Map[String, String]
  params : Map[String, String]
  body : Bytes
}

///|
pub fn Req::new(
  meth : String,
  raw_path : String,
  path : String,
  headers : Map[String, String],
  query : Map[String, String],
  params : Map[String, String],
  body : Bytes,
) -> Req {
  { meth, raw_path, path, headers, query, params, body, }
}

///|
/// 请求方法（大写）。
pub fn Req::meth_word(self : Req) -> String {
  self.meth
}

///|
/// 原始路径（含查询串被剥掉之前的样子），404 回显用它。
pub fn Req::path(self : Req) -> String {
  self.raw_path
}

///|
/// 取请求头，名字大小写不敏感。
pub fn Req::get_header(self : Req, name : String) -> String? {
  let want = ascii_lower(name)
  for pair in self.headers.to_array() {
    let (k, v) = pair
    if ascii_lower(k) == want {
      return Some(v)
    }
  }
  None
}

///|
/// 取查询参数。值不做百分号解码：本服务的参数全是数字或固定代号，
/// 解码与否影响不到校验逻辑，少一段解析就少一处出错的地方。
pub fn Req::get_query(self : Req, name : String) -> String? {
  self.query.get(name)
}

///|
/// 取路径参数（`/:name`）。
pub fn Req::param(self : Req, name : String) -> String? {
  self.params.get(name)
}

///|
/// 一次响应。
pub struct Resp {
  status : Int32
  headers : Map[String, String]
  body : Bytes
}

///|
pub fn Resp::new(status : Int32, ctype : String, body : Bytes) -> Resp {
  {
    status,
    headers: { "Content-Type": ctype, "Cache-Control": "no-store" },
    body,
  }
}

///|
/// 常用响应：状态码 + Content-Type + body，一律 no-store。
pub fn make_res(status : Int32, ctype : String, body : Bytes) -> Resp {
  Resp::new(status, ctype, body)
}

///|
/// HTML 响应。
pub fn html_res(body : String) -> Resp {
  Resp::new(200, "text/html; charset=utf-8", @utf8.encode(body))
}

///|
/// 纯文本响应。
pub fn text_res(status : Int32, body : String) -> Resp {
  Resp::new(status, "text/plain; charset=utf-8", @utf8.encode(body))
}

///|
/// 状态码对应的原因短语。
pub fn status_reason(code : Int32) -> String {
  match code {
    200 => "OK"
    404 => "Not Found"
    405 => "Method Not Allowed"
    500 => "Internal Server Error"
    503 => "Service Unavailable"
    _ => "OK"
  }
}

///|
/// 路由的三类匹配。
pub enum RouteKind {
  Exact
  Param(String)
  CatchAll
}

///|
pub struct Route {
  kind : RouteKind
  pattern : String
  handler : async (Req) -> Resp
}

///|
/// 路由表。
///
/// 匹配顺序固定为 精确 → 单段参数 → 通配，和注册顺序无关：`/health` 不会被
/// `/:file` 吃掉，`/a/b` 落到 `/**`。
pub struct Router {
  routes : Array[Route]
}

///|
pub fn Router::new() -> Router {
  { routes: [], }
}

///|
pub fn Router::get(
  self : Router,
  pattern : String,
  handler : async (Req) -> Resp,
) -> Unit {
  let kind = if pattern == "/**" {
    CatchAll
  } else if pattern.has_prefix("/:") && !pattern[2:].contains("/") {
    Param(pattern[2:].to_owned())
  } else {
    Exact
  }
  self.routes.push({ kind, pattern, handler, })
}

///|
/// 把重复的斜杠折成一个，去掉结尾多余的那一个。
///
/// `//health` 和 `/health` 是同一个地址：Web 服务里多打一个斜杠太常见，
/// 不折的话会掉进 404。
pub fn normalize_path(raw : String) -> String {
  let path = match raw.find("?") {
    Some(i) => raw[:i].to_owned()
    None => raw
  }
  let buf = StringBuilder()
  // 初值 false：开头的斜杠要留下，否则 "/a" 会被折成 "a"
  let mut last_slash = false
  for i = 0; i < path.length(); i = i + 1 {
    // String 的下标拿到的不是 Char，是 UTF-16 码元
    let c = path[i].to_int()
    if c == 47 {
      if !last_slash {
        buf.write_char('/')
      }
      last_slash = true
    } else {
      buf.write_char(c.unsafe_to_char())
      last_slash = false
    }
  }
  let out = buf.to_string()
  if out == "" {
    "/"
  } else {
    out
  }
}

///|
/// 十六进制字符转数值。不是十六进制返回 None。
fn hex_val(c : Int32) -> Int32? {
  if c >= 48 && c <= 57 {
    return Some(c - 48)
  }
  if c >= 97 && c <= 102 {
    return Some(c - 87)
  }
  if c >= 65 && c <= 70 {
    return Some(c - 55)
  }
  None
}

///|
/// 查询串里的百分号编码还原：`%20` → 空格，`+` → 空格。
///
/// 只认合法转义。`%` 后面不是两位十六进制就原样保留 —— 宁让下游解析失败，
/// 也不要猜一个别字符出来。这一步只做一次，不递归解码。
fn percent_decode(s : String) -> String {
  if !s.contains("%") && !s.contains("+") {
    return s
  }
  let out = StringBuilder()
  let n = s.length()
  let mut i = 0
  while i < n {
    let c = s[i].to_int()
    if c == 43 {
      // '+'
      out.write_char(' ')
      i = i + 1
      continue
    }
    if c == 37 && i + 2 < n {
      match (hex_val(s[i + 1].to_int()), hex_val(s[i + 2].to_int())) {
        (Some(hi), Some(lo)) => {
          out.write_char(((hi << 4) | lo).unsafe_to_char())
          i = i + 3
          continue
        }
        _ => ()
      }
    }
    out.write_char(c.unsafe_to_char())
    i = i + 1
  }
  out.to_string()
}

///|
/// 解析查询串。同名参数取第一个。
pub fn parse_query(raw : String) -> Map[String, String] {
  let out : Map[String, String] = Map([])
  let qs : String = match raw.find("?") {
    Some(i) => raw[i + 1:].to_owned()
    None => ""
  }
  if qs == "" {
    return out
  }
  for kv in qs.split("&") {
    let s : String = kv.to_owned()
    if s == "" {
      continue
    }
    match s.find("=") {
      Some(eq) => {
        let k : String = s[:eq].to_owned()
        if !out.contains(k) {
          out.set(k, percent_decode(s[eq + 1:].to_owned()))
        }
      }
      None => if !out.contains(s) { out.set(s, "") }
    }
  }
  out
}

///|
/// 单段路径参数：整条路径只有一个非空段才算数。
pub fn single_segment(path : String) -> String? {
  let body = if path.has_prefix("/") { path[1:].to_owned() } else { path }
  if body == "" || body.contains("/") {
    return None
  }
  Some(body)
}

///|
/// 分发一次请求。
pub async fn Router::dispatch(
  self : Router,
  meth : String,
  raw_path : String,
  headers : Map[String, String],
  body : Bytes,
) -> Resp {
  if meth != "GET" && meth != "HEAD" {
    return {
      status: 405,
      headers: {
        "Content-Type": "text/plain; charset=utf-8",
        "Allow": "GET, HEAD",
        "Cache-Control": "no-store",
      },
      body: @utf8.encode("只支持 GET 和 HEAD\n"),
    }
  }
  let path = normalize_path(raw_path)
  let query = parse_query(raw_path)
  let params : Map[String, String] = Map([])
  let make_req = fn() {
    Req::new(meth, raw_path, path, headers, query, params, body)
  }
  // 三趟匹配：精确 → 单段参数 → 通配。
  //
  // 不能合成一趟：`:file` 也是单段路径，跟 `/health` 同样匹配，谁先注册谁赢
  // 就会让 `/health` 掉进快照处理器再变成 404。
  for r in self.routes {
    match r.kind {
      Exact => if r.pattern == path { return (r.handler)(make_req()) }
      _ => ()
    }
  }
  for r in self.routes {
    match r.kind {
      Param(name) =>
        match single_segment(path) {
          Some(seg) => {
            let p : Map[String, String] = Map([])
            p.set(name, seg)
            return (r.handler)(
              Req::new(meth, raw_path, path, headers, query, p, body),
            )
          }
          None => ()
        }
      _ => ()
    }
  }
  for r in self.routes {
    match r.kind {
      CatchAll => return (r.handler)(make_req())
      _ => ()
    }
  }
  // 路由表里没有 `/**` 时也要有个交代
  {
    status: 404,
    headers: {
      "Content-Type": "text/plain; charset=utf-8",
      "Cache-Control": "no-store",
    },
    body: @utf8.encode(not_found_text(raw_path)),
  }
}
