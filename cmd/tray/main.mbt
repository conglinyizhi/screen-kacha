///|
#borrow(cmd)
extern "c" fn run_shell(cmd : Bytes) -> Int32 = "moonbit_screenstream_run"

///|
#borrow(cmd, buf)
extern "c" fn capture_shell(cmd : Bytes, buf : Bytes, len : Int32) -> Int32 = "moonbit_screenstream_capture"

///|
/// 给 C 用的 NUL 结尾字符串。
fn cstr(s : String) -> Bytes {
  let src = @utf8.encode(s)
  let n = src.length()
  Bytes::makei(n + 1, fn(i) { if i < n { src[i] } else { 0 } })
}

///|
fn sh(cmd : String) -> Unit {
  run_shell(cstr(cmd)) |> ignore
}

///|
/// 同步跑一条命令，返回去掉尾部空白的输出前 limit 字节。
fn capture(cmd : String, limit : Int32) -> String {
  let buf = Bytes::makei(limit + 1, fn(_) { 0 })
  let n = capture_shell(cstr(cmd), buf, limit + 1)
  if n <= 0 {
    return ""
  }
  @utf8.decode_lossy(buf[0:n])
}

///|
fn health_summary(base : String) -> String {
  let text = capture("curl -s --max-time 2 '\{base}/health'", 2048)
  if text.length() == 0 {
    return "服务未响应"
  }
  // 菜单标题只放短提示，完整 JSON 走「复制健康 JSON」
  if text.length() > 46 {
    text[0:46].to_owned() + "…"
  } else {
    text
  }
}

///|
fn main {
  let port = 18940
  let base = "http://127.0.0.1:\{port}"
  let cfg = @sni.default_tray_config(
    "screenstream", "screenstream 屏幕快照", "video-display",
  )
  let t = @sni.tray(cfg)
  let status = t.on("status", "端口 \{port} · 点击刷新", fn(_) {  })
  status.set_enabled(false)

  t.on("open", "打开网页", fn(_) { sh("xdg-open '\{base}/'") }) |> ignore
  t.on("copy_url", "复制地址", fn(_) {
    sh("printf %s '\{base}/' | wl-copy")
  })
  |> ignore
  t.on("copy_health", "复制健康 JSON", fn(_) {
    sh("curl -s --max-time 2 '\{base}/health' | wl-copy")
  })
  |> ignore
  t.on("copy_skill", "复制 skill.md 地址", fn(_) {
    sh("printf %s '\{base}/skill.md' | wl-copy")
  })
  |> ignore
  t.separator()
  t.on("refresh", "刷新状态", fn(_) {
    status.set_title("端口 \{port} · \{health_summary(base)}")
  })
  |> ignore
  t.on("quit", "退出托盘", fn(_) { sh("true") }) |> ignore
  t.run() |> ignore
}
