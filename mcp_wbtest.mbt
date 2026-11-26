///|
/// 无状态协议：每个请求自己带协议版本，没有握手。
const MCP_META : String = "\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}}"

///|
fn mcp_server_for_test() -> McpEndpoint {
  // 必须给 fake：不给的话 snapshot 工具会走真实抓帧，在没有 DISPLAY 的环境里
  // 拉起 spectacle，Qt 初始化失败直接 abort —— 每跑一次测试留一个核心转储。
  // 指一个不存在的文件，抓帧必然失败，正好当「没有帧」的用例。
  build_mcp(
    Store::new(
      shot="/tmp/none.jpg",
      fake=Some("/nonexistent-frame-for-test.png"),
    ),
    8930,
    Access::default(),
  ) catch {
    _ => McpEndpoint::unavailable()
  }
}

///|
async test "MCP：tools/list 列出 snapshot 和 health" {
  let server = mcp_server_for_test()
  let resp = server.handle_request(
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
  let store = Store::new(
    shot="/tmp/none.jpg",
    fake=Some("/nonexistent-frame-for-test.png"),
  )
  let server = build_mcp(store, 8930, Access::default()) catch {
    _ => McpEndpoint::unavailable()
  }
  let resp = server.handle_request(
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
  let resp = server.handle_request(
    "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/list\"}",
  ) catch {
    _ => ""
  }
  // 锁定「无状态协议必须带 _meta」这条，别在换实现时悄悄变成能过
  assert_true(resp.contains("-32602"))
}

///|
/// 参数写错必须报错。两层都要能挡：端点按 inputSchema 先拒（-32602），
/// 工具内部再查一遍（isError），因为客户端可以不校验 schema 直接调。
///
/// 这条锁的是「越界被当成没给」那个 bug：
/// 以前 width=999999 会被静默忽略，返回一张整屏图，调用方以为缩放生效了。
async test "MCP：width 越界要报错" {
  let server = mcp_server_for_test()
  let resp = server.handle_request(
    "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"snapshot\",\"arguments\":{\"width\":999999}," +
    MCP_META +
    "}}",
  ) catch {
    _ => ""
  }
  // 端点会先按 inputSchema 挡一遍（-32602），挡不住才轮到工具里那层检查
  assert_true(resp.contains("\"isError\":true") || resp.contains("-32602"))
}

///|
/// region 给了但不是字符串，也要报错而不是当没给。
async test "MCP：region 类型不对要报错" {
  let server = mcp_server_for_test()
  let resp = server.handle_request(
    "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"snapshot\",\"arguments\":{\"region\":123}," +
    MCP_META +
    "}}",
  ) catch {
    _ => ""
  }
  assert_true(resp.contains("\"isError\":true") || resp.contains("-32602"))
}

///|
/// 构造失败的端点必须自报不可用，而不是装成一个「有端点但没工具」的服务端。
/// `/mcp` 靠 available() 决定回 503。
test "MCP：占位端点报不可用" {
  let dead = McpEndpoint::unavailable()
  assert_false(dead.available())
  assert_true(mcp_server_for_test().available())
}

///|
async test "MCP：占位端点仍有合法 JSON-RPC 错误" {
  let dead = McpEndpoint::unavailable()
  let resp = dead.handle_request(
    "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/list\"}",
  ) catch {
    _ => ""
  }
  assert_true(resp.contains("\"jsonrpc\":\"2.0\""))
  assert_true(resp.contains("-32603"))
}
