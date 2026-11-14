///|
#borrow(cmd)
extern "c" fn run_shell(cmd : Bytes) -> Int32 = "moonbit_screenstream_run"

///|
#borrow(cmd, buf)
extern "c" fn capture_shell(cmd : Bytes, buf : Bytes, len : Int32) -> Int32 = "moonbit_screenstream_capture"

///|
extern "c" fn exit_now(code : Int32) -> Unit = "moonbit_screenstream_exit"

///|
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
fn capture(cmd : String, limit : Int32) -> String {
  let buf = Bytes::makei(limit + 1, fn(_) { 0 })
  let n = capture_shell(cstr(cmd), buf, limit + 1)
  if n <= 0 {
    return ""
  }
  @utf8.decode_lossy(buf[0:n])
}

///|
fn parse_int(s : StringView, dflt : Int32) -> Int32 {
  if s.length() == 0 {
    return dflt
  }
  let mut n = 0
  for i in 0..<s.length() {
    let c = s[i]
    guard c >= 48 && c <= 57 else { return dflt }
    n = n * 10 + (c.to_int() - 48)
  }
  n
}

///|
fn pick(m : @argparse.Matches, name : String, dflt : String) -> String {
  match m.values.get(name) {
    Some([v, ..]) => v
    _ => dflt
  }
}

///|
/// 菜单标题只放短提示，完整 JSON 走「复制健康 JSON」。
fn shorten(text : String) -> String {
  if text.length() == 0 {
    return "服务未响应"
  }
  if text.length() > 46 {
    text[0:46].to_owned() + "…"
  } else {
    text
  }
}

///|
fn main raise {
  let cmd = @argparse.Command(
    "screenstream-tray",
    about="screenstream 托盘",
    options=[
      @argparse.OptionArg("port", about="服务端口", default_values=["8930"]),
    ],
  )
  let m = cmd.parse()
  let port = parse_int(pick(m, "port", "8930"), 8930)
  let base = "http://127.0.0.1:\{port}"
  let cfg = @sni.default_tray_config(
    "screenstream", "screenstream 屏幕快照", "video-display",
  )
  let t = @sni.tray(cfg)
  let status = t.on("status", "端口 \{port} · 点「刷新状态」", fn(_) {

  })
  status.set_enabled(false)
  // 自绘图标就绪，但 moonsni 0.1.4 的 IconPixmap 编码会让 dbus-daemon 断开连接，
  // 暂时仍用主题图标；修好库再接线。

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
    let h = capture("curl -s --max-time 2 '\{base}/health'", 2048)
    status.set_title("端口 \{port} · \{shorten(h)}")
  })
  |> ignore
  t.on("restart", "重启服务", fn(_) {
    sh("systemctl --user restart screenstream-mb.service")
  })
  |> ignore
  t.separator()
  // 左键点图标也刷新一次，顺手重画灯
  t.on_click(fn(_x, _y) {
    let h = capture("curl -s --max-time 2 '\{base}/health'", 2048)
    status.set_title("端口 \{port} · \{shorten(h)}")
  })
  t.on("quit", "退出托盘", fn(_) { exit_now(0) }) |> ignore
  match t.run() {
    Ok(_) => eprintln("托盘事件循环已结束")
    Err(code) => eprintln("托盘启动失败，错误码 \{code}")
  }
}
