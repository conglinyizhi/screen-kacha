///|
/// MCP 服务端：对外只暴露「取一张当前屏幕」和「看采集状态」两个工具。
///
/// 走的是 2026-07-28 的无状态协议：没有 initialize 握手，每个请求自己在
/// `params._meta` 里带 protocolVersion。所以对外只有
/// `handle_request(body) -> body` 这一件事，不需要长连接，也不需要 SSE。
pub fn build_mcp(
  store : Store,
  port : Int32,
  access : Access,
) -> @mcp.MCPServer raise {
  let server = @mcp.MCPServer::MCPServer("screen-kacha", "0.1.0").with_instructions(
    "本机屏幕的 HTTP 快照服务。snapshot 返回一张当前屏幕的 JPEG；health 返回采集状态。",
  )
  let server = server.tool(
    "snapshot",
    "取一张当前屏幕的截图，返回 JPEG 图片",
    Json::object({ "type": "object" }),
    async fn(_ctx, _args) {
      // 和 HTTP 那条路一样：先按最小间隔取帧，再拿最新的一帧
      store.ensure_request(1500L)
      match store.bytes() {
        None =>
          Ok(
            @mcp.ToolResult::error(
              "还没有抓到帧，过一秒再试；原因看 health 工具或 /health",
            ),
          )
        Some(bytes) =>
          Ok(
            @mcp.ToolResult::success([
              @mcp.ContentBlock::image(
                @util.b64_encode(bytes),
                mime_type="image/jpeg",
              ),
            ]),
          )
      }
    },
  )
  server.tool(
    "health",
    "采集状态：帧龄、耗时、失败次数、取帧来源、访问策略",
    Json::object({ "type": "object" }),
    fn(_ctx, _args) {
      Ok(@mcp.ToolResult::text(health_json(store, port, access)))
    },
  )
}

///|
/// MCP 端点：接一个 JSON-RPC 请求体，回一个 JSON-RPC 响应体。
///
/// 协议版本由客户端在 `params._meta` 里声明，这里不校验（SDK 会校验）。
pub async fn mcp_response(server : @mcp.MCPServer, body : String) -> String {
  server.handle_request(body)
}
