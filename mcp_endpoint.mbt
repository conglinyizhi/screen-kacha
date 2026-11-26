///|
/// MCP 端点的抽象层。
///
/// 上层只认这个文件里的四种东西：一段内容、一次工具结果、一条工具声明、
/// 端点本身。`@mcp` 只在这里出现 —— 换实现或者自己写一份时，删掉下半部分的
/// 适配代码即可，`mcp.mbt`、`serve_access.mbt` 和 `cmd/main` 都不用动。
///
/// 面只开这么宽：类型名、构造失败时的占位、是否可用、处理一个请求体。
/// 工具声明和适配细节都是本包私有，出去只会通过 `build_mcp` 返回的端点。

///|
/// 工具回给客户端的一段内容。
///
/// 只收工具栏得住的两类：文字和图片。MCP 的其余内容类型（音频、资源链接、
/// 内嵌资源）这个服务用不上，不跟着 SDK 一起暴露。
priv enum McpContent {
  Text(String)
  /// 图片走 base64，MCP 用它传二进制
  Image(String, mime_type~ : String)
}

///|
/// 一次工具调用的结果。
///
/// 协议层面的错误（JSON-RPC 不合规、方法不存在）不在这里，那些由端点自己回。
/// 这里只管「工具跑了，成功或失败」：失败也是结果，带 `is_error` 回去，
/// 让模型看见原因，而不是把整条连接断掉。
priv struct McpToolResult {
  content : Array[McpContent]
  is_error : Bool
}

///|
fn McpToolResult::text(text : String) -> McpToolResult {
  { content: [McpContent::Text(text)], is_error: false, }
}

///|
fn McpToolResult::image(b64 : String, mime_type~ : String) -> McpToolResult {
  { content: [McpContent::Image(b64, mime_type~)], is_error: false, }
}

///|
fn McpToolResult::error(message : String) -> McpToolResult {
  { content: [McpContent::Text(message)], is_error: true, }
}

///|
/// 一条工具声明：名字、说明、inputSchema，以及把参数变成结果的函数。
///
/// 参数是不可信的模型输入，校验写在工具里 —— 不做 schema 静态拦截的假设，
/// 客户端完全可以不校验就直接调。
priv struct McpTool {
  name : String
  description : String
  input_schema : Json
  handler : async (Json) -> McpToolResult
}

///|
fn McpTool::new(
  name : String,
  description : String,
  input_schema : Json,
  handler : async (Json) -> McpToolResult,
) -> McpTool {
  { name, description, input_schema, handler, }
}

///|
/// 一个 MCP 端点。
///
/// 构造失败时留一个占位端点：这时 `/mcp` 直接回 503，而不是起一个「在线但
/// 一个工具都没有」的服务端 —— 后者会让调用方以为是自己配错了工具名。
pub struct McpEndpoint {
  inner : @mcp.MCPServer?
}

///|
/// 构造失败时的占位端点。
pub fn McpEndpoint::unavailable() -> McpEndpoint {
  { inner: None, }
}

///|
/// 端点能不能接活。`/mcp` 拿它决定回 503 还是往下走。
pub fn McpEndpoint::available(self : McpEndpoint) -> Bool {
  self.inner is Some(_)
}

///|
/// 一个请求体进，一个响应体出。
///
/// 无状态协议：每个请求自己在 `params._meta` 里带协议版本，没有握手，
/// 所以这里不需要长连接、不需要 SSE，也不需要按连接保存任何东西。
pub async fn McpEndpoint::handle_request(
  self : McpEndpoint,
  body : String,
) -> String {
  match self.inner {
    Some(server) => server.handle_request(body)
    // 占位端点理论上不该走到这（`/mcp` 先查 available），真走到就给一条
    // 合法的 JSON-RPC 错误：id 无从得知，写 null 比编一个更诚实。
    None =>
      "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32603,\"message\":\"MCP 不可用\"}}"
  }
}

///|
/// 按工具声明拼出端点。
///
/// 名字重复、schema 不是合法 JSON Schema 这类问题由底层实现报出来，
/// 这里不另做一套校验 —— 两套校验迟早会不一致。
fn McpEndpoint::build(
  name : String,
  version : String,
  instructions~ : String,
  tools~ : Array[McpTool],
) -> McpEndpoint raise {
  let mut server = @mcp.MCPServer::MCPServer(name, version).with_instructions(
    instructions,
  )
  for tool in tools {
    server = server.tool(tool.name, tool.description, tool.input_schema, async fn(
      _ctx,
      args,
    ) {
      Ok(to_sdk_result((tool.handler)(args)))
    })
  }
  { inner: Some(server), }
}

///|
/// 自家结果翻成 SDK 的结果类型。**这是唯一一处把两边对上的地方。**
fn to_sdk_result(result : McpToolResult) -> @mcp.ToolResult {
  let blocks = result.content.map(fn(block) {
    match block {
      McpContent::Text(text) => @mcp.ContentBlock::text(text)
      McpContent::Image(b64, mime_type~) =>
        @mcp.ContentBlock::image(b64, mime_type~)
    }
  })
  if result.is_error {
    { ..@mcp.ToolResult::error(""), content: blocks, }
  } else {
    @mcp.ToolResult::success(blocks)
  }
}
