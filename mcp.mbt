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
    "取一张当前屏幕的截图，返回 JPEG 图片。region 可只取一块，省 token",
    Json::object({
      "type": "object",
      "properties": Json::object({
        "region": Json::object({
          "type": "string",
          "description": "只取一块：x,y,w,h，四段都是 0..1 的比例或带 % 的百分比，例如 0.1,0.1,0.3,0.2 或 10%,10%,30%,20%",
        }),
        "width": Json::object({
          "type": "integer",
          "minimum": 1,
          "maximum": 4096,
          "description": "输出宽度（像素），不传就是原宽",
        }),
      }),
    }),
    async fn(_ctx, args) {
      // 参数是模型给的，不可信：region 解析失败、width 越界都直接回 isError，
      // 不静默退回整屏 —— 那会让调用方以为裁剪生效了，白烧一遍 token。
      let region = match arg_node(args, "region") {
        None => Some(None)
        Some(String(v)) =>
          match parse_region(v.to_string()) {
            Some(r) => Some(Some(r))
            None => None
          }
        Some(_) => None
      }
      let region = match region {
        None =>
          return Ok(
            @mcp.ToolResult::error(
              "region 看不懂。要四段，每段是 0..1 的比例或百分比，例如 0.1,0.1,0.3,0.2",
            ),
          )
        Some(r) => r
      }
      let dst_w = match arg_node(args, "width") {
        None => Some(None)
        Some(Number(v, ..)) =>
          // 只收 1..4096 的整数；小数、NaN、Inf、越界都算写错
          if v.is_nan() ||
            v.is_inf() ||
            v < 1.0 ||
            v > 4096.0 ||
            v != v.to_int().to_double() {
            None
          } else {
            Some(Some(v.to_int()))
          }
        Some(_) => None
      }
      let dst_w = match dst_w {
        None =>
          return Ok(@mcp.ToolResult::error("width 要在 1 到 4096 之间"))
        Some(w) => w
      }
      // 和 HTTP 那条路一样：先按最小间隔取帧，再拿最新的一帧
      store.ensure_request(1500L)
      let frame = match store.bytes() {
        None =>
          return Ok(
            @mcp.ToolResult::error(
              "还没有抓到帧，过一秒再试；原因看 health 工具或 /health",
            ),
          )
        Some(b) => b
      }
      // 不裁剪也不缩放：直接回原始字节，一次编解码都不做
      if region is None && dst_w is None {
        return Ok(
          @mcp.ToolResult::success([
            @mcp.ContentBlock::image(
              @util.b64_encode(frame),
              mime_type="image/jpeg",
            ),
          ]),
        )
      }
      // 要加工就落一份临时文件：C 侧的图像入口吃路径
      let src = store.next_tmp(".jpg")
      let wrote = try {
        @fs.write_file(src, frame, create_mode=CreateOrTruncate)
        true
      } catch {
        _ => false
      }
      if !wrote {
        return Ok(@mcp.ToolResult::error("临时文件写不出来"))
      }
      let out = store.next_tmp(".jpg")
      let w = match dst_w {
        Some(w) => w
        None => 0
      }
      let ok = match region {
        Some(r) =>
          @image.image_region(
            src,
            false,
            0,
            0,
            r.x,
            r.y,
            r.w,
            r.h,
            w,
            82,
            false,
            out,
          )
        None => @image.jpeg_to_file(src, w, 82, false, out)
      }
      let bytes = Some(@fs.read_file(out).binary()) catch { _ => None }
      match (ok, bytes) {
        (true, Some(b)) =>
          Ok(
            @mcp.ToolResult::success([
              @mcp.ContentBlock::image(
                @util.b64_encode(b),
                mime_type="image/jpeg",
              ),
            ]),
          )
        _ => Ok(@mcp.ToolResult::error("图像处理失败"))
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

///|
/// 取出参数对应的 JSON 节点。**没给**返回 None，给了就原样返回 ——
/// 调用方必须能分清「没给」和「给了个不合法的东西」，否则越界参数会被
/// 当成没给，静默退回整屏。
fn arg_node(args : Json, key : String) -> Json? {
  match args {
    Object(obj) => obj.get(key)
    _ => None
  }
}
