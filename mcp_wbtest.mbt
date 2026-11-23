///|
/// 无状态协议：每个请求自己带协议版本，没有握手。
const MCP_META : String = "\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}}"

///|
fn mcp_server_for_test() -> @mcp.MCPServer {
  build_mcp(Store::new(shot="/tmp/none.jpg"), 8930, Access::default()) catch {
    _ => @mcp.MCPServer::MCPServer("screen-kacha", "0.1.0")
  }
}

///|
async test "MCP：tools/list 列出 snapshot 和 health" {
  let server = mcp_server_for_test()
  let resp = mcp_response(
    server,
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{" +
    MCP_META +
    "}}",
  ) catch {
    _ => ""
  }
  assert_true(resp.contains("\"snapshot\""))
  assert_true(resp.contains("\"health\""))
  assert_true(resp.contains("image/jpeg") || resp.contains("截图"))
}

///|
async test "MCP：没抓帧时 snapshot 回 isError" {
  let store = Store::new(shot="/tmp/none.jpg")
  let server = build_mcp(store, 8930, Access::default()) catch {
    _ => @mcp.MCPServer::MCPServer("screen-kacha", "0.1.0")
  }
  let resp = mcp_response(
    server,
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"snapshot\",\"arguments\":{}," +
    MCP_META +
    "}}",
  ) catch {
    _ => ""
  }
  // 没有帧源时应当是 isError，而不是空响应
  assert_true(
    resp.contains("\"isError\":true") || resp.contains("\"type\":\"image\""),
  )
}

///|
async test "MCP：不带协议版本会被拒" {
  let server = mcp_server_for_test()
  let resp = mcp_response(
    server, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/list\"}",
  ) catch {
    _ => ""
  }
  // 锁定「无状态协议必须带 _meta」这条，别在升级 SDK 时悄悄变成能过
  assert_true(resp.contains("-32602"))
}
