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
/// 命令行定义单独抽出来，方便测试直接解析 argv。
fn cli_cmd() -> @argparse.Command {
  @argparse.Command("screenstream", about="本机屏幕快照服务", options=[
    @argparse.OptionArg("port", short='p', about="监听端口", default_values=[
      "18940",
    ]),
    @argparse.OptionArg("bind", about="监听地址", default_values=["0.0.0.0"]),
    @argparse.OptionArg(
      "idle",
      about="无人请求时的保活间隔（秒），0 表示不保活",
      default_values=["20"],
    ),
    @argparse.OptionArg("shm", about="帧文件存放目录", default_values=[
      "/tmp/screenstream-mb",
    ]),
    @argparse.OptionArg("max-conns", about="并发连接上限", default_values=[
      "64",
    ]),
  ])
}

///|
async fn idle_loop(store : @store.Store, seconds : Int32) -> Unit {
  if seconds <= 0 {
    return
  }
  for ;; {
    @async.sleep(seconds * 1000)
    store.ensure(0L)
  }
}

///|
async fn main {
  let m = cli_cmd().parse()
  let port = parse_int(pick(m, "port", "18940"), 18940)
  let bind = pick(m, "bind", "0.0.0.0")
  let idle = parse_int(pick(m, "idle", "20"), 20)
  let shm = pick(m, "shm", "/tmp/screenstream-mb")
  let max_conns = parse_int(pick(m, "max-conns", "64"), 64)
  @fs.mkdir(shm, permission=0o700, recursive=true) catch {
    err => eprintln("创建帧目录失败：\{err}")
  }
  let magick = @store.detect_magick()
  let store = @store.Store::new(shot="\{shm}/latest.jpg", magick~)
  let app = @store.build_app(store, port)
  let server = @http.Server(@socket.Addr::parse("\{bind}:\{port}"))
  let magick_note = match magick {
    Some(m) => m
    None => "未找到，缩放与 WebP 将退回原图"
  }
  eprintln(
    "screenstream-mb v0.1 监听 \{bind}:\{port}  帧目录 \{shm}  保活 \{idle}s  并发上限 \{max_conns}",
  )
  eprintln("  ImageMagick: \{magick_note}")
  @async.with_task_group() <| group => {
    group.spawn_bg(no_wait=true) <| async fn() { idle_loop(store, idle) }
    app.serve_on(
      server,
      options=@crescent.NativeServeOptions(
        max_connections=max_conns,
        // 单连接读写超时对齐 Python 版的 15 秒
        request_body_read_timeout_ms=15000,
        handler_timeout_ms=15000,
      ),
    )
  }
}
