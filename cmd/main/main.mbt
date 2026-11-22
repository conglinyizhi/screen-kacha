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
      "access",
      about="访问控制配置文件；留空用 ~/.config/screenstream-mb/access.conf",
      default_values=[""],
    ),
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
      "source",
      about="取帧来源：auto / pipewire / spectacle",
      default_values=["auto"],
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
    if store.pipewire_on() {
      // PipeWire 模式下帧由常驻流产出，不需要后台泵
      @async.sleep(1000)
      continue
    }
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
/// 后台拿 portal 屏幕流：拿到就切 PipeWire，拿不到就保持 spectacle。
/// portal 首次可能需要人工授权，所以这里允许长时间等待，期间服务照常可用。
async fn portal_bg(store : @store.Store, shm : String) -> Unit {
  for round = 0; ; round = round + 1 {
    if store.pipewire_on() {
      // 已经连上就慢慢看着：助手重启、会话过期时流会断，这里负责重新接
      @async.sleep(15000)
      continue
    }
    eprintln(
      "后台尝试通过 portal 获取屏幕流（第 \{round + 1} 次）",
    )
    match @store.acquire_portal_node(shm) {
      Some(id) => if store.enable_pipewire(id) { return }
      None => eprintln("portal 这次没给出 node")
    }
    @async.sleep(30000)
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
  let source = pick(m, "source", "auto")
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
  let store = @store.Store::new(
    shot=shot_path,
    fake=fake_source,
    wl_dir~,
    pw=use_pw,
  )
  // reuse_addr：服务重启时旧连接还处于 TIME-WAIT，不开这个 bind 会失败
  let server = @http.Server(
    @socket.Addr::parse("\{bind}:\{port}"),
    reuse_addr=true,
  )
  let access_path = match pick(m, "access", "") {
    "" =>
      match @env.get_env_var("HOME") {
        Some(h) => "\{h}/.config/screenstream-mb/access.conf"
        None => "/etc/screenstream-mb/access.conf"
      }
    p => p
  }
  let access = @store.load_access(access_path)
  eprintln(
    "访问控制：\{if access.restricted() { "启用（\{access.describe()}）" } else { "未启用" }}  配置 \{access_path}",
  )
  let app = @store.build_app(store, port, access)
  if pw_node > 0 {
    if store.enable_pipewire(pw_node) {
      eprintln("PipeWire 抓帧已启动，node=\{pw_node}")
    } else {
      eprintln("PipeWire 启动失败，回落到 spectacle")
    }
  }
  eprintln(
    "screenstream-mb v0.1 监听 \{bind}:\{port}  帧目录 \{shm}  泵 \{pump}ms  并发上限 \{max_conns}",
  )
  @async.with_task_group() <| group => {
    if pw_node <= 0 && source != "spectacle" && fake_source is None {
      // 服务先跑起来，portal 在后台拿屏幕流；拿不到就一直按 spectacle 服务
      // 假帧源不碰 portal：有固定图可用，没必要去抢真实屏幕，
      // 否则每跑一次冒烟都会弹一次「屏幕共享权限请求」。
      group.spawn_bg(no_wait=true) <| async fn() { portal_bg(store, shm) }
    }
    if pump > 0 && !use_pw {
      group.spawn_bg(no_wait=true) <| async fn() {
        pump_loop(store, pump, pump_idle)
      }
    } else {
      group.spawn_bg(no_wait=true) <| async fn() { idle_loop(store, idle) }
    }
    if access.restricted() {
      // 有访问限制时自己收连接：crescent 的 serve_on 拿不到对端地址
      @store.serve_with_access(app, server, access, max_conns)
    } else {
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
}
