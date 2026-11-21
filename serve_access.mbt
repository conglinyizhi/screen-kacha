///|
/// 带访问控制的监听循环。
///
/// crescent 的 serve_on 在 accept 之后就把地址丢了，拿不到对端 IP，
/// 所以这里自己收连接：先看地址放不放行，再交给 App::dispatch。
///
/// 每条连接处理一个请求就关（不做 keep-alive）：本服务的客户端要么是
/// curl、要么是每隔一会儿来一张图的脚本，省下连接复用的复杂度。
pub async fn serve_with_access(
  app : @crescent.App,
  server : @http.Server,
  access : Access,
  max_conns : Int32,
) -> Unit {
  let gate = @async.Semaphore(if max_conns > 0 { max_conns } else { 256 })
  @async.with_task_group(group => {
    for ;; {
      let (conn, addr) = server.accept() catch { _ => break }
      let peer = addr.to_string()
      if !access.allows(peer) {
        eprintln("拒绝 \{peer}：不在允许范围内")
        // 先把请求读掉再回 403：连接状态机要求手里有请求才能发响应，
        // 直接写会被当协议错误，客户端只看到连接被重置。
        let _ = Some(conn.read_request()) catch { _ => None }
        let _ = Some(
          conn.send_response(403, "Forbidden", extra_headers={
            "Content-Type": "text/plain; charset=utf-8",
            "Connection": "close",
          }),
        ) catch {
          _ => None
        }
        let _ = Some(conn.write("这个服务只对本机开放\n")) catch {
          _ => None
        }
        let _ = Some(conn.end_response()) catch { _ => None }
        conn.close()
        continue
      }
      group.spawn_bg(no_wait=true, allow_failure=true, () => {
        gate.acquire()
        defer gate.release()
        handle_one(app, conn)
      })
    }
  })
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
/// 读一个请求、分发给 app、把结果写回去。
async fn handle_one(app : @crescent.App, conn : @http.ServerConnection) -> Unit {
  let request = conn.read_request() catch {
    _ => {
      conn.close()
      return
    }
  }
  let verb = verb_of(request.meth)
  let path = request.path
  let headers = request.headers
  // 本服务的接口都是 GET，不读请求体
  let body : Bytes = Bytes::makei(0, fn(_) { 0 })
  let (status, res_headers, payload) = app.dispatch(verb, path, headers, body) catch {
    _ => {
      conn.close()
      return
    }
  }
  let hdrs : Map[String, String] = Map([])
  res_headers.each((k, v) => hdrs.set(k, v))
  hdrs.set("Connection", "close")
  let _ = Some(
    conn.send_response(status.to_int(), status.to_string(), extra_headers=hdrs),
  ) catch {
    _ => None
  }
  let _ = Some(conn.write(payload)) catch { _ => None }
  let _ = Some(conn.end_response()) catch { _ => None }
  conn.close()
}
