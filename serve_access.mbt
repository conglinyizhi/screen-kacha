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
  app : @crescent.App,
  server : @http.Server,
  access : Access,
  max_conns : Int32,
) -> Unit {
  let limit = if max_conns > 0 { max_conns } else { 256 }
  let gate = @async.Semaphore(limit)
  @async.with_task_group(group => {
    for ;; {
      let (conn, addr) = server.accept() catch { _ => break }
      let peer = addr.to_string()
      if !access.allows(peer) {
        // 拒绝也要 spawn：读请求可能永远等不到数据，
        // 在循环里等会把整个服务卡死，这不只是慢，是可用性问题。
        group.spawn_bg(no_wait=true, allow_failure=true, () => {
          reject(conn, peer)
        })
        continue
      }
      // 放行的连接占一个槽位；满了就停在 accept 上形成背压
      gate.acquire()
      group.spawn_bg(no_wait=true, allow_failure=true, () => {
        defer gate.release()
        handle_one(app, conn)
      })
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
      @async.with_timeout_opt(REJECT_TIMEOUT_MS, () => conn.read_request()) {
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
      @async.with_timeout_opt(WRITE_TIMEOUT_MS, () => {
        conn.send_response(403, "Forbidden", extra_headers=hdrs)
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
/// 读一个请求、分发给 app、把结果写回去。三段各有超时。
async fn handle_one(app : @crescent.App, conn : @http.ServerConnection) -> Unit {
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
  let headers = request.headers
  // 本服务的接口都是 GET，不读请求体
  let body : Bytes = Bytes::makei(0, fn(_) { 0 })
  // 超时只包 dispatch（handler 已经算完、payload 已经序列化），
  // 不包写响应：写一半被掐会留下截断的报文，比回 504 更糟。
  let result = @async.with_timeout_opt(HANDLER_TIMEOUT_MS, () => {
    app.dispatch(verb, path, headers, body)
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
        conn.send_response(504, "Gateway Timeout", extra_headers=hdrs)
        conn.write("处理超时了，稍后重试\n")
        conn.end_response()
      }) catch {
        _ => None
      }
      conn.close()
    }
    Some((status, res_headers, payload)) => {
      let hdrs : Map[String, String] = Map([])
      res_headers.each((k, v) => hdrs.set(k, v))
      hdrs.set("Connection", "close")
      // 写响应也有超时：客户端不读就会阻塞在 socket 缓冲上，
      // 一直占着槽位等于把并发上限一点点吃光。
      let _ : Unit? = @async.with_timeout_opt(WRITE_TIMEOUT_MS, () => {
        conn.send_response(
          status.to_int(),
          status.to_string(),
          extra_headers=hdrs,
        )
        conn.write(payload)
        conn.end_response()
      }) catch {
        _ => None
      }
      conn.close()
    }
  }
}
