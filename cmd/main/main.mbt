///|
/// 命令行定义单独抽出来，方便测试直接解析 argv。
fn cli_cmd() -> @argparse.Command {
  @argparse.Command(
    "screen-kacha",
    about="本机屏幕快照服务",
    flags=[
      @argparse.FlagArg(
        "no-port-fallback",
        about="端口被占时不要换端口，直接报错退出",
      ),
    ],
    options=[
      @argparse.OptionArg(
        "port",
        short='p',
        about="监听端口（必填，1-65535）",
      ),
      @argparse.OptionArg("bind", about="监听地址", default_values=[
        "0.0.0.0",
      ]),
      @argparse.OptionArg(
        "access",
        about="访问控制配置文件；留空用 ~/.config/screen-kacha/access.conf",
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
        "pump-idle",
        about="没人取图时后台泵放慢到的间隔（毫秒）",
        default_values=["3000"],
      ),
      @argparse.OptionArg(
        "source",
        about="取帧来源：auto 和 pipewire 都是优先 PipeWire（拿不到退回 spectacle），spectacle 只用 spectacle",
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
        "/tmp/screen-kacha",
      ]),
      @argparse.OptionArg(
        "data",
        about="素材与文档所在目录（光标 PNG、skill.md、llms.txt 等）",
        default_values=["."],
      ),
      @argparse.OptionArg("max-conns", about="并发连接上限", default_values=[
        "64",
      ]),
    ],
  )
}

///|
/// 后台泵。
///
/// 拉模式来源：按节奏去要帧（现有行为，含 idle 降速）。
/// 推模式来源：帧由常驻流自己送来，泵不去要 —— 但要盯着流有没有停。
async fn pump_loop(
  store : @store.Store,
  shm : String,
  pw_node : Int32,
  interval_ms : Int32,
  idle_interval_ms : Int32,
) -> Unit {
  let mut last_fails = store.fails()
  // 推模式的帧龄按流真正送来的帧序号算，不按 JPEG 缓存（见 StreamClock）
  let clock = @store.StreamClock::new(store.stream_seq(), @async.now())
  // 流状态也要换算出持续时间：宽限期靠它，只看「这一轮是不是 streaming」
  // 会在协商那一瞬间就误判死。
  let state_clock = @store.StreamStateClock::new(@async.now())
  for ;; {
    if store.push_source() {
      // 推模式：帧自己会来，泵不用去要。
      //
      // 但必须盯着。原来是这里一句 `sleep(1000); continue` 就算完：
      // 流悄悄死掉时不会有任何一次采集失败（shim 会把上一帧再写一遍，
      // `capture` 照样「成功」），`/health` 就一直说 ok、fails 是 0、
      // err 是空的，而画面永远停在那一帧上。
      let now = @async.now()
      let age = clock.observe(store.stream_seq(), now)
      let since_streaming = state_clock.observe(
        @store.is_streaming(store.stream_state()),
        now,
      )
      match
        store.watchdog(age, since_streaming, async fn() -> Int32? {
          if pw_node > 0 {
            // 显式指了 node：重连它就行，别去碰 portal（用户没让它走 portal）
            if store.enable_pipewire(pw_node) {
              Some(pw_node)
            } else {
              None
            }
          } else {
            store.recover_push_stream(shm)
          }
        }) {
        Recovered => {
          // 重连之后两个窗口都重开：新流还要协商，旧的「停了多久」
          // 不能带进新流，否则刚连上就又被判死一次。
          let t = @async.now()
          clock.reset(t)
          state_clock.reset(t)
        }
        _ => ()
      }
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
/// `--source` 的合法取值。
///
/// 非法值原来被静默当成 auto：用户写了 `--source spectacl`，以为限定了取帧方式，
/// 实际照旧优先 PipeWire。启动就报错比事后查 /health 便宜。
pub fn source_valid(s : String) -> Bool {
  s == "auto" || s == "pipewire" || s == "spectacle"
}

///|
/// 取路径的最后一段。清理陈旧原始帧时要拿它当文件名前缀。
fn base_name(path : String) -> String {
  let mut cut = -1
  for i = 0; i < path.length(); i = i + 1 {
    if path[i].to_int() == 47 {
      cut = i
    }
  }
  if cut < 0 {
    path
  } else {
    path[cut + 1:].to_owned()
  }
}

///|
/// 启动时告诉用户「谁真的能取图」。
///
/// 只陈述事实。原来的写法是 `访问控制：\{if restricted { 启用（…） } else { 未启用 }}`，
/// 判据是 `allow_public`，于是「局域网放行」也被写成「启用」，读起来像有一层
/// 防护，实际上同网段任何设备都能取整屏。要不要提醒、怎么提醒，在这里定，
/// 好单测；`main` 只负责打印。
fn access_banner(
  access : @store.Access,
  bind : String,
  port : Int32,
) -> Array[String] {
  let lines : Array[String] = ["允许来源：\{access.describe()}"]
  if access.allow_public {
    lines.push(
      "注意：allow_public = true，任何能连到 \{bind}:\{port} 的地址都能取整屏",
    )
  } else if access.allow_lan {
    lines.push(
      "注意：放行的是整个局域网网段，同网段其它设备也能取整屏；只信自己的设备请用 allow 名单并关掉 allow_lan",
    )
  }
  lines
}

///|
/// 后台拿 portal 屏幕流：拿到就切 PipeWire，拿不到就保持 spectacle。
/// portal 首次可能需要人工授权，所以这里允许长时间等待，期间服务照常可用。
async fn portal_bg(store : @store.Store, shm : String) -> Unit {
  for round = 0; ; round = round + 1 {
    // 已经连上就慢慢看着：助手重启、会话过期时流会断。这里必须继续转，
    // 不能连上就 return —— 那样 loop 就结束了，之后流断了没人接，
    // 服务永久停在 spectacle 慢路径上。决策本身在 portal_step 里，好测。
    match @store.portal_step(store.pipewire_on()) {
      Watch => {
        @async.sleep(15000)
        continue
      }
      Reacquire => ()
    }
    eprintln(
      "后台尝试通过 portal 获取屏幕流（第 \{round + 1} 次）",
    )
    match @store.acquire_portal_node(shm) {
      Some(id) => store.enable_pipewire(id) |> ignore
      None => eprintln("portal 这次没给出 node")
    }
    @async.sleep(30000)
  }
}

///|
async fn main {
  let m = cli_cmd().parse()
  // 端口不做默认值：塞在代码里的默认端口和安装版的端口是两回事，
  // 手动跑时静默用了另一个端口，排查的人会以为自己连的是同一个服务。
  let port = @util.parse_int(@util.pick(m, "port", ""), 0)
  if port <= 0 || port > 65535 {
    eprintln("要给 --port（1-65535）。")
    eprintln(
      "安装版的 unit 里已经带了端口，手动跑时自己指定，例如：",
    )
    eprintln("  screen-kacha --port 18940 --bind 127.0.0.1")
    @store.exit_process(2)
    return
  }
  let bind = @util.pick(m, "bind", "0.0.0.0")
  let idle = @util.parse_int(@util.pick(m, "idle", "20"), 20)
  let pump = @util.parse_int(@util.pick(m, "pump", "500"), 500)
  let pump_idle = @util.parse_int(@util.pick(m, "pump-idle", "3000"), 3000)
  let fake = @util.pick(m, "fake", "")
  let pw_node = @util.parse_int(@util.pick(m, "pw-node", "0"), 0)
  let source = @util.pick(m, "source", "auto")
  if !source_valid(source) {
    eprintln(
      "--source 只认 auto / pipewire / spectacle，收到的是「\{source}」",
    )
    @store.exit_process(2)
  }
  let shm = @util.pick(m, "shm", "/tmp/screen-kacha")
  let data_dir = @util.pick(m, "data", ".")
  let max_conns = @util.parse_int(@util.pick(m, "max-conns", "64"), 64)
  @fs.mkdir(shm, permission=0o700, recursive=true) catch {
    err =>
      // 目录已存在是正常情况（重启时），只有真的建不出来才报
      if @fs.exists(shm) {
        ()
      } else {
        eprintln("创建帧目录失败：\{err}")
      }
  }
  // 已存在的目录 mkdir 不管，权限保持原样。老版本建的是 0755，帧和临时
  // 输出都躺在里面，所以这里主动收紧一次。系统 systemd 给的 %t 本来就是
  // 0700，但 --shm 可以指到 /tmp 下，那就全靠这一步。
  @fs.chmod(shm, 0o700) catch {
    err => eprintln("收紧帧目录权限失败（不影响运行）：\{err}")
  }

  // 先确认本机只有这一份在跑。
  //
  // 拿到锁才继续：拿不到说明已经有实例在用同一个帧目录，这时候再起一份
  // 只会抢同一批临时文件。端口那条路上「被占就换口」的兜底，前提正是
  // 「占着端口的不是自己」——由这把锁保证。
  if !@store.acquire_instance_lock(shm) {
    eprintln(
      "帧目录 \{shm} 已经被另一个 screen-kacha 占着，这次不重复启动",
    )
    eprintln("它在哪个端口：cat ~/.local/state/screen-kacha/port")
    @store.exit_process(0)
    return
  }
  // 帧目录的锁只挡得住「同一个帧目录」。换了个 --shm 再起一份，锁是过了，
  // 但抓的还是同一块屏 —— spectacle 单实例，两份并发会互相卡死。
  // 放在锁后面：真正要跑起来的那份才需要看这条警告。
  @store.warn_duplicate_instances() |> ignore
  let fake_source = if fake == "" { None } else { Some(fake) }
  // 假帧模式下 shot 直接指向那张图，连拷贝都省了
  let shot_path = match fake_source {
    Some(p) => p
    None => "\{shm}/latest.jpg"
  }
  // 上一次运行留下的原始帧不会被这次覆盖（序号每进程从 1 重来），先扫掉。
  // 每帧 8MB，而 /run 是内存盘。
  let cleaned_frames = @store.clean_stale_frames(
    shm,
    "\{base_name(shot_path)}.",
    ".bgra",
  )
  if cleaned_frames > 0 {
    eprintln("清掉上次运行留下的原始帧 \{cleaned_frames} 个")
  }
  // 临时输出正常情况读完就删，进程被 kill 时会剩几个
  let cleaned_tmp = @store.clean_stale_frames(shm, "out-", "")
  if cleaned_tmp > 0 {
    eprintln("清掉上次运行留下的临时输出 \{cleaned_tmp} 个")
  }
  let wl_dir = @store.default_runtime_dir()
  let use_pw = pw_node > 0
  let store = @store.Store::new(
    shot=shot_path,
    fake=fake_source,
    wl_dir~,
    pw=use_pw,
    // 临时输出跟帧文件放同一个目录：这个目录是按 0700 建的，
    // 别的本机用户既读不到截图，也没法在里面预置符号链接
    tmp_dir=shm,
    // 停摆判定要知道泵的节奏
    pump_ms=pump,
    // 素材和文档的目录。以前靠进程工作目录，换个 unit 或从别处手动跑，
    // 光标就静默失效而托盘上的勾还亮着
    data_dir~,
  )
  // 内嵌的素材释放到临时目录：C 侧的 cursor_overlay 要文件路径
  store.init_assets()

  // 端口被占时先退避重试，再换口或干净退出，细节见 bind.mbt
  let (server, port) = match
    bind_with_fallback(bind, port, !flag_on(m, "no-port-fallback")) {
    Some(pair) => pair
    None => return
  }
  write_port_file(port)
  let access_path = match @util.pick(m, "access", "") {
    "" =>
      match @env.get_env_var("HOME") {
        Some(h) => "\{h}/.config/screen-kacha/access.conf"
        None => "/etc/screen-kacha/access.conf"
      }
    p => p
  }
  let access = @store.load_access(access_path)
  for line in access_banner(access, bind, port) {
    eprintln(line)
  }
  eprintln("访问配置：\{access_path}")
  let router = @store.build_router(store, port, access)
  if pw_node > 0 {
    if store.enable_pipewire(pw_node) {
      eprintln("PipeWire 抓帧已启动，node=\{pw_node}")
    } else {
      eprintln("PipeWire 启动失败，回落到 spectacle")
    }
  }
  // 光标素材缺了不致命，但必须说一声：否则 ?cursor=1 会一直返回没箭头的图，
  // 从外面看不出区别。
  let cursor_assets : Array[String] = [
    "cursor-arrow.png", "cursor-mask.png", "cursor-arrow-classic.png", "cursor-mask-classic.png",
  ]
  for name in cursor_assets {
    let path = store.data_path(name)
    if !(@fs.exists(path) catch { _ => false }) {
      eprintln("缺少光标素材 \{path}：?cursor= 开了也画不出来")
    }
  }
  eprintln(
    "screen-kacha v0.1 监听 \{bind}:\{port}  帧目录 \{shm}  素材 \{data_dir}  泵 \{pump}ms  并发上限 \{max_conns}",
  )
  // MCP：和 HTTP 共用同一个进程和同一份采集状态
  let mcp = @store.build_mcp(store, port, access) catch {
    e => {
      eprintln("MCP 初始化失败，/mcp 不可用：\{e}")
      // 退化成没有任何工具的服务端，其余接口照常
      @mcp.MCPServer::MCPServer("screen-kacha", "0.1.0")
    }
  }
  @async.with_task_group() <| group => {
    if pw_node <= 0 && source != "spectacle" && fake_source is None {
      // 服务先跑起来，portal 在后台拿屏幕流；拿不到就一直按 spectacle 服务
      // 假帧源不碰 portal：有固定图可用，没必要去抢真实屏幕，
      // 否则每跑一次冒烟都会弹一次「屏幕共享权限请求」。
      group.spawn_bg(no_wait=true) <| async fn() { portal_bg(store, shm) }
    }
    if pump > 0 {
      // 推模式下泵不去要帧，但它是唯一盯着「流还活着没有」的地方，
      // 所以 push 模式也得起来 —— 原来这里排除了 use_pw，结果是
      // 指定 --pw-node 之后整个进程里没有任何人监督那条流。
      group.spawn_bg(no_wait=true) <| async fn() {
        pump_loop(store, shm, pw_node, pump, pump_idle)
      }
    }
    if pump <= 0 || use_pw {
      // 推模式下泵不取帧，/health 的 frame_age_ms 得有人刷，
      // 所以这里留着保活循环；拉模式下泵已经在抓，不需要它。
      group.spawn_bg(no_wait=true) <| async fn() { idle_loop(store, idle) }
    }
    // 托盘心跳监督。
    //
    // 托盘崩掉之后，KWin 里的脚本和 cursor helper 都不会自己消失：
    // 脚本继续每 200ms 打没人接的 D-Bus，helper 继续占着那个名字。
    // 托盘正常退出会自己收，这条循环是给「没来得及收」准备的 ——
    // 读了它写的心跳，判定死了就替它收掉。没有托盘文件时它只是每 5 秒
    // 睁一次眼，不叫也不动手。
    group.spawn_bg(no_wait=true) <| async fn() { @store.supervise_tray() }
    // 一律走自己的 accept 循环。
    //
    // 原来分两条路：有访问限制时自己收连接，放行公网时用框架自带的 serve_on。
    // 框架带着一个它自己的依赖，那条快路径不值得为它留一个不受我们控制的入口 ——
    // 两条路合并之后，超时、并发上限、拒绝路径的行为只有一套。
    @store.serve_with_access(router, mcp, server, access, max_conns)
  }
}
