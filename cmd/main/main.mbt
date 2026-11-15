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
    @argparse.OptionArg(
      "fake",
      about="测试用：用这张图片当帧源，不跑 spectacle",
      default_values=[""],
    ),
    @argparse.OptionArg(
      "pw-node",
      about="用 PipeWire 指定 node id 取帧（0 表示不用）",
      default_values=["0"],
    ),
    @argparse.OptionArg(
      "pump",
      about="后台抓帧间隔（毫秒），0 表示不启动后台泵",
      default_values=["500"],
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
/// 后台抓帧泵：抓完睡 interval_ms 再抓，请求侧直接读缓存，不必等采集。
async fn pump_loop(
  store : @store.Store,
  interval_ms : Int32,
  idle_interval_ms : Int32,
) -> Unit {
  let mut last_fails = store.fails()
  for ;; {
    store.ensure(0L)
    if store.fails() > last_fails {
      last_fails = store.fails()
      @async.sleep(1000)
    } else if store.idle_ms() > 10000L {
      // 十秒内没人取图就别一直烧 CPU，放慢到 idle 间隔
      @async.sleep(idle_interval_ms)
    } else {
      @async.sleep(interval_ms)
    }
  }
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
  let pump = parse_int(pick(m, "pump", "500"), 500)
  let pump_idle = parse_int(pick(m, "pump-idle", "3000"), 3000)
  let fake = pick(m, "fake", "")
  let pw_node = parse_int(pick(m, "pw-node", "0"), 0)
  let shm = pick(m, "shm", "/tmp/screenstream-mb")
  let max_conns = parse_int(pick(m, "max-conns", "64"), 64)
  @fs.mkdir(shm, permission=0o700, recursive=true) catch {
    err =>
      // 目录已存在是正常情况（重启时），只有真的建不出来才报
      if @fs.exists(shm) {
        ()
      } else {
        eprintln("创建帧目录失败：\{err}")
      }
  }
  let magick = @store.detect_magick()
  let fake_source = if fake == "" { None } else { Some(fake) }
  // 假帧模式下 shot 直接指向那张图，连拷贝都省了
  let shot_path = match fake_source {
    Some(p) => p
    None => "\{shm}/latest.jpg"
  }
  let wl_dir = match @env.get_env_var("XDG_RUNTIME_DIR") {
    Some(d) => d
    None => "/run/user/1000"
  }
  let use_pw = pw_node > 0
  if use_pw {
    let rc = @store.pipewire_start(pw_node)
    if rc != 0 {
      eprintln("PipeWire 启动失败 rc=\{rc}，回落到 spectacle")
    } else {
      eprintln("PipeWire 抓帧已启动，node=\{pw_node}")
    }
  }
  let store = @store.Store::new(
    shot=shot_path,
    magick~,
    fake=fake_source,
    wl_dir~,
    pw=use_pw,
  )
  let app = @store.build_app(store, port)
  // reuse_addr：服务重启时旧连接还处于 TIME-WAIT，不开这个 bind 会失败
  let server = @http.Server(
    @socket.Addr::parse("\{bind}:\{port}"),
    reuse_addr=true,
  )
  let magick_note = match magick {
    Some(m) => m
    None => "未找到，缩放与 WebP 将退回原图"
  }
  eprintln(
    "screenstream-mb v0.1 监听 \{bind}:\{port}  帧目录 \{shm}  泵 \{pump}ms  并发上限 \{max_conns}",
  )
  eprintln("  ImageMagick: \{magick_note}")
  @async.with_task_group() <| group => {
    if pump > 0 && !use_pw {
      group.spawn_bg(no_wait=true) <| async fn() {
        pump_loop(store, pump, pump_idle)
      }
    } else {
      group.spawn_bg(no_wait=true) <| async fn() { idle_loop(store, idle) }
    }
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
