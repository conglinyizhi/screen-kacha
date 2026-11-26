///|
/// 单条连接各阶段的超时（毫秒）。
///
/// 对齐 crescent `serve_on` 默认的 15 秒：读请求和跑 handler 各一个。
/// 拒绝路径用短超时，因为正常客户端连上就会立刻发请求，
/// 两秒还没动静的多半是扫描器或者坏连接，不值得占着槽位等。
const READ_TIMEOUT_MS : Int32 = 15000

///|
const HANDLER_TIMEOUT_MS : Int32 = 15000

///|
const WRITE_TIMEOUT_MS : Int32 = 15000

///|
const REJECT_TIMEOUT_MS : Int32 = 2000

///|
/// MCP 请求体上限。一个 JSON-RPC 调用通常几百字节，1 MiB 已经很宽松。
const MCP_MAX_BODY : Int32 = 1048576

///|
/// accept 连续失败到这个次数就认定监听坏了，需要死掉等重启。
///
/// 阈值给足：瞬时错误（对端中途跑掉、信号打断）连着来几次很正常，
/// 攒到 100 次、每次退避 20ms，意味着已经持续两秒完全接不到连接。
const ACCEPT_MAX_CONSEC_FAILS : Int32 = 100

///|
/// accept 失败后的退避。EMFILE 要等 fd 还回来，空转会烧 CPU。
const ACCEPT_RETRY_SLEEP_MS : Int32 = 20

///|
/// 连续失败到这个次数就放弃，交给 systemd 重启。
pub fn accept_gave_up(consecutive : Int32) -> Bool {
  consecutive >= ACCEPT_MAX_CONSEC_FAILS
}

///|
/// 拒绝路径上每一段的超时。
///
/// 两段都要用短的：会走到拒绝的客户端本来就不该占着槽位。原来写响应那一段
/// 借用的是 `WRITE_TIMEOUT_MS`（15 秒），跟上面注释说的「拒绝路径用短超时」
/// 正好相反，一个不读响应的来源能白占槽位 15 秒。
pub fn reject_timeout_ms() -> Int32 {
  REJECT_TIMEOUT_MS
}

///|
/// 拒绝路径的并发上限。
///
/// 取主上限的一小部分：拒绝只是读一下请求、回一句 403、关掉，不需要那么多槽位，
/// 大头要留给真正要服务的请求。至少给 4 个，免得上限很小时算成 0 直接卡死。
pub fn reject_slots(max_conns : Int32) -> Int32 {
  let eighth = max_conns / 8
  if eighth < 4 {
    4
  } else {
    eighth
  }
}

///|
/// 以非零码立刻结束进程。
extern "c" fn exit_now(code : Int32) -> Unit = "moonbit_screen_kacha_exit"

///|
/// 给别的包用的版本（本包内部的 extern 不对外）。
pub fn exit_process(code : Int32) -> Unit {
  exit_now(code)
}

///|
/// 带访问控制的监听循环。
///
/// crescent 的 `serve_on` 在 accept 之后就把地址丢了，拿不到对端 IP，
/// 所以这里自己收连接：先看地址放不放行，再交给 `App::dispatch`。
///
/// 每条连接处理一个请求就关（不做 keep-alive）：本服务的客户端要么是
/// curl、要么是每隔一会儿来一张图的脚本，省下连接复用的复杂度。
///
/// ## 为什么每一段都要有超时
///
/// 这个循环是**同步等待**的：`accept` 之后如果直接在当前栈上读请求，
/// 一个连上却不发数据的客户端就能把整个服务卡死（accept 循环停住，
/// 后面所有连接都进不来）。所以：
///
/// - accept 之后立刻 `spawn` 出去，绝不在循环里做 IO
/// - 读请求、跑 handler、写响应各有超时
/// - 并发上限用信号量在 accept 后立刻 `acquire`，满了就停在原地，
///   由内核的 listen backlog 兜住新连接（跟 `serve_on` 的做法一致）
pub async fn serve_with_access(
  router : Router,
  mcp : McpEndpoint,
  server : @http.Server,
  access : Access,
  max_conns : Int32,
) -> Unit {
  let limit = if max_conns > 0 { max_conns } else { 256 }
  let gate = @async.Semaphore(limit)
  // 拒绝路径也要限流。
  //
  // 原来拒绝分支直接 spawn，一个槽位都不占：一个不被允许的地址开上千个空闲
  // 连接，每个都攥着一个 fd，撑到 EMFILE 之后正常连接也建不起来。
  // 用独立的小信号量而不是共用 gate：共用的话，一阵未授权连接就能把正常
  // 客户端的槽位吃光，等于借着"拒绝"把服务打死。
  let reject_gate = @async.Semaphore(reject_slots(limit))
  @async.with_task_group(group => {
    let mut accept_errs = 0
    for ;; {
      // accept 出错不要 break。
      //
      // 原来写的是 `catch { _ => break }`：EMFILE（fd 用光）、ECONNABORTED
      // （对端在握手途中跑了）、EINTR 全都当成「正常收工」，循环退出、
      // 进程以 0 结束，而单元写的是 Restart=on-failure —— systemd 不会拉起，
      // 服务就这么静默消失，日志里只有启动那两行。
      let accepted = Some(server.accept()) catch {
        err => {
          accept_errs = accept_errs + 1
          if accept_gave_up(accept_errs) {
            eprintln(
              "accept 连续失败 \{accept_errs} 次，监听已经不可用：\{err}",
            )
            // 非零退出，让 systemd 按 Restart= 重新拉起
            exit_now(1)
          }
          // 退一步再试：EMFILE 这类等 fd 还回来就能恢复，
          // 立刻重试只会在错误上空转烧 CPU
          @async.sleep(ACCEPT_RETRY_SLEEP_MS)
          None
        }
      }
      match accepted {
        None => continue
        Some((conn, addr)) => {
          accept_errs = 0
          let peer = addr.to_string()
          if !access.allows(peer) {
            // 拒绝也要 spawn：读请求可能永远等不到数据，
            // 在循环里等会把整个服务卡死，这不只是慢，是可用性问题。
            // 拿不到槽位就停在 accept 上：新连接留在内核 backlog 里，
            // 不占进程的 fd
            reject_gate.acquire()
            group.spawn_bg(no_wait=true, allow_failure=true, () => {
              defer reject_gate.release()
              reject(conn, peer)
            })
            continue
          }
          // 放行的连接占一个槽位；满了就停在 accept 上形成背压
          gate.acquire()
          group.spawn_bg(no_wait=true, allow_failure=true, () => {
            defer gate.release()
            handle_one(router, mcp, conn)
          })
        }
      }
    }
  })
}

///|
/// 回 403 并关连接。全程有超时，读不到请求就直接关。
async fn reject(conn : @http.ServerConnection, peer : String) -> Unit {
  eprintln("拒绝 \{peer}：不在允许范围内")
  // 先把请求读掉再回 403：连接状态机要求手里有请求才能发响应，
  // 直接写会被当成协议错误，客户端只看到连接被重置。
  let got = try {
    match
      @async.with_timeout_opt(reject_timeout_ms(), () => conn.read_request()) {
      Some(_) => true
      None => false
    }
  } catch {
    _ => false
  }
  if !got {
    // 连请求都没读全，别试着写响应了
    conn.close()
    return
  }
  let hdrs : Map[String, String] = Map([])
  hdrs.set("Content-Type", "text/plain; charset=utf-8")
  hdrs.set("Connection", "close")
  let _ = try {
    match
      @async.with_timeout_opt(reject_timeout_ms(), () => {
        conn.send_response(
          403,
          "Forbidden",
          extra_headers=headers_to_http(hdrs),
        )
        conn.write("这个服务只对本机开放\n")
        conn.end_response()
      }) {
      Some(_) => true
      None => false
    }
  } catch {
    _ => false
  }
  conn.close()
}

///|
/// 把请求方法翻成大写的 HTTP 动词，crescent 的 dispatch 按这个匹配路由。
fn verb_of(m : @http.RequestMethod) -> String {
  match m {
    Get => "GET"
    Head => "HEAD"
    Post => "POST"
    Put => "PUT"
    Delete => "DELETE"
    Connect => "CONNECT"
    Options => "OPTIONS"
    Trace => "TRACE"
    Patch => "PATCH"
  }
}

///|
/// `@http` 的 header 键是大小写不敏感的包装类型，我们内部用普通字符串。
///
/// 只在进出的边界上转一次：路由、日志、测试都在普通 `Map[String, String]` 上做，
/// 不用到处处理这个包装。
fn headers_from_http(
  h : Map[@http.CaseInsensitiveString, String],
) -> Map[String, String] {
  let out : Map[String, String] = Map([])
  h.each((k, v) => out.set(k.to_string(), v))
  out
}

///|
/// 反过来：把我们的 header 交给 `send_response`。
fn headers_to_http(
  h : Map[String, String],
) -> Map[@http.CaseInsensitiveString, String] {
  let out : Map[@http.CaseInsensitiveString, String] = Map([])
  h.each((k, v) => out.set(@http.CaseInsensitiveString(k), v))
  out
}

///|
/// 按名字取 header，大小写不敏感。
fn header_lookup(headers : Map[String, String], name : String) -> String? {
  let want = ascii_lower(name)
  for pair in headers.to_array() {
    let (k, v) = pair
    if ascii_lower(k) == want {
      return Some(v)
    }
  }
  None
}

///|
/// Host 头只接受 IP 字面量和 localhost。
///
/// 不校验的话有个现成的攻击面：浏览器里的恶意页面随便找个域名解析到这台机器
/// （DNS rebinding），就能同源读走整屏截图。浏览器发来的 Host 是那个域名，
/// 而 IP 字面量访问（本机 127.0.0.1、局域网 192.168.x.x）不会被这种手法利用。
///
/// 局域网里用主机名访问的同学需要改用 IP；这条取舍写进 README。
pub fn host_allowed(host : String) -> Bool {
  let h = ascii_lower(host.trim().to_owned())
  if h == "" {
    // HTTP/1.0 可以没有 Host
    return true
  }
  let name = if h.has_prefix("[") {
    // IPv6 字面量：[::1]:8930
    match h.find("]") {
      Some(i) => h[:i + 1].to_owned()
      None => h
    }
  } else {
    match h.find(":") {
      Some(i) => h[:i].to_owned()
      None => h
    }
  }
  if name == "localhost" {
    return true
  }
  if name.has_prefix("[") {
    return true
  }
  // IPv4 字面量：只有数字和点，且带点
  let mut i = 0
  let mut numeric = true
  while i < name.length() {
    let c = name[i].to_int()
    if !(c >= 48 && c <= 57) && c != 46 {
      numeric = false
      break
    }
    i = i + 1
  }
  numeric && name.contains(".")
}

///|
/// 读一个请求、分发给 app、把结果写回去。三段各有超时。
async fn handle_one(
  router : Router,
  mcp : McpEndpoint,
  conn : @http.ServerConnection,
) -> Unit {
  let request = try {
    match @async.with_timeout_opt(READ_TIMEOUT_MS, () => conn.read_request()) {
      Some(r) => Some(r)
      None => None
    }
  } catch {
    _ => None
  }
  let request = match request {
    None => {
      // 读超时或读坏了：没什么可回的，直接关
      conn.close()
      return
    }
    Some(r) => r
  }
  let verb = verb_of(request.meth)
  let path = request.path
  let headers = headers_from_http(request.headers)
  // DNS rebinding 挡在分发之前：Host 是域名就拒，IP 字面量放行
  match header_lookup(headers, "host") {
    Some(h) =>
      if !host_allowed(h) {
        let bad_hdrs : Map[String, String] = Map([])
        bad_hdrs.set("Content-Type", "text/plain; charset=utf-8")
        bad_hdrs.set("Connection", "close")
        let _ : Unit? = @async.with_timeout_opt(REJECT_TIMEOUT_MS, () => {
          conn.send_response(
            403,
            "Forbidden",
            extra_headers=headers_to_http(bad_hdrs),
          )
          conn.write("Host 只接受 IP 和 localhost（防 DNS rebinding）\n")
          conn.end_response()
        }) catch {
          _ => None
        }
        conn.close()
        return
      }
    None => ()
  }
  // 本服务的接口都是 GET，不读请求体
  // MCP 端点：全服务唯一接受 POST 的路径。
  //
  // 放在路由之前，是因为 Router 只认 GET/HEAD，而 MCP 要读请求体 ——
  // 这套读法（先看 Content-Length 再 read_all）只有这一条路用得上。
  if verb == "POST" && normalize_path(path) == "/mcp" {
    handle_mcp(mcp, conn, headers)
    return
  }
  let body : Bytes = Bytes::makei(0, fn(_) { 0 })
  // 超时只包 dispatch（handler 已经算完、payload 已经序列化），
  // 不包写响应：写一半被掐会留下截断的报文，比回 504 更糟。
  let result = @async.with_timeout_opt(HANDLER_TIMEOUT_MS, () => {
    router.dispatch(verb, path, headers, body)
  }) catch {
    _ => None
  }
  match result {
    None => {
      // handler 超时：回 504，让客户端知道是服务端慢，不是路径错
      let hdrs : Map[String, String] = Map([])
      hdrs.set("Content-Type", "text/plain; charset=utf-8")
      hdrs.set("Connection", "close")
      let _ : Unit? = @async.with_timeout_opt(WRITE_TIMEOUT_MS, () => {
        conn.send_response(
          504,
          "Gateway Timeout",
          extra_headers=headers_to_http(hdrs),
        )
        conn.write("处理超时了，稍后重试\n")
        conn.end_response()
      }) catch {
        _ => None
      }
      conn.close()
    }
    Some(resp) => {
      let hdrs : Map[String, String] = Map([])
      resp.headers.each((k, v) => hdrs.set(k, v))
      hdrs.set("Connection", "close")
      // HEAD 不能带 body。
      //
      // 底层 http 的 `send_response` 是按 Content-Length 等 body 的：
      // 头里写着 N 字节、
      // 实际一个字节都不写，`end_response` 会抛 IncorrectBodyLength，
      // 连接直接断掉，客户端只看到「Empty reply from server」。
      // 健康检查、curl -I、反代探活全都走 HEAD，这就是「服务挂了」的假信号。
      //
      // 所以这里把 Content-Length 显式改成 0：HEAD 回的是「这次没有 body」，
      // 客户端拿不到真实长度（真要长度得发 GET），但连接是干净的。
      let is_head = verb == "HEAD"
      if is_head {
        hdrs.set("Content-Length", "0")
      }
      // 写响应也有超时：客户端不读就会阻塞在 socket 缓冲上，
      // 一直占着槽位等于把并发上限一点点吃光。
      let _ : Unit? = @async.with_timeout_opt(WRITE_TIMEOUT_MS, () => {
        conn.send_response(
          resp.status,
          status_reason(resp.status),
          extra_headers=headers_to_http(hdrs),
        )
        if !is_head {
          conn.write(resp.body)
        }
        conn.end_response()
      }) catch {
        // 客户端中途断开是常态（扫描器、超时挂断），这里不刷日志；
        // HEAD 那条 IncorrectBodyLength 由冒烟的 HEAD 断言守住。
        _ => None
      }
      conn.close()
    }
  }
}

///|
/// 发一个 JSON 响应然后关连接。
async fn send_json(
  conn : @http.ServerConnection,
  status : Int32,
  body : String,
) -> Unit {
  let hdrs : Map[String, String] = Map([])
  hdrs.set("Content-Type", "application/json; charset=utf-8")
  hdrs.set("Connection", "close")
  let _ : Unit? = @async.with_timeout_opt(WRITE_TIMEOUT_MS, () => {
    conn.send_response(
      status,
      status_reason(status),
      extra_headers=headers_to_http(hdrs),
    )
    conn.write(@utf8.encode(body))
    conn.end_response()
  }) catch {
    _ => None
  }
  conn.close()
}

///|
/// 处理一次 MCP 调用。
///
/// 无状态协议：一次 POST 一个 JSON-RPC，回一个 JSON。没有 SSE、不保持连接，
/// 所以和其余接口共用同一套超时与连接生命周期。
async fn handle_mcp(
  mcp : McpEndpoint,
  conn : @http.ServerConnection,
  headers : Map[String, String],
) -> Unit {
  // 端点没构造出来就别假装在线。以前这里退化成「在线但一个工具都没有」，
  // 调用方只能看到空的 tools/list，会以为是自己工具名配错了。
  if !mcp.available() {
    send_json(conn, 503, "{\"error\":\"MCP 不可用\"}")
    return
  }
  let len = match header_lookup(headers, "content-length") {
    Some(v) => @util.parse_int(v, -1)
    None => -1
  }
  if len < 0 {
    send_json(conn, 411, "{\"error\":\"需要 Content-Length\"}")
    return
  }
  if len > MCP_MAX_BODY {
    send_json(conn, 413, "{\"error\":\"请求体太大\"}")
    return
  }
  let body = Some(conn.read_all().binary()) catch { _ => None }
  let body = match body {
    None => {
      send_json(conn, 400, "{\"error\":\"请求体读不出来\"}")
      return
    }
    Some(b) => b
  }
  let resp = Some(mcp.handle_request(@utf8.decode_lossy(body))) catch {
    e => {
      eprintln("MCP 处理失败：\{e}")
      None
    }
  }
  match resp {
    Some(r) => send_json(conn, 200, r)
    None => send_json(conn, 500, "{\"error\":\"MCP 处理失败\"}")
  }
}
