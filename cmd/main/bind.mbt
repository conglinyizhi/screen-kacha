///|
/// 端口被占用时的重试间隔（毫秒）。
///
/// 要覆盖的场景是「上一个实例正在退出，端口还没放开」：等 250ms 就够了，
/// 不行就翻倍，累计约 3.75 秒。等这么久还占着，就不是等一等能解决的事了。
const BIND_RETRIES : Int32 = 4

///|
/// 端口一直被占用时，往上最多再找几个。
const PORT_FALLBACK_SPAN : Int32 = 8

///|
/// 第 attempt 次重试前等多久；越界返回 0。
pub fn bind_backoff_ms(attempt : Int32) -> Int32 {
  match attempt {
    0 => 250
    1 => 500
    2 => 1000
    3 => 2000
    _ => 0
  }
}

///|
/// 备选端口：从 port+1 起，最多 span 个，不超过 65535。
pub fn fallback_ports(port : Int32, span : Int32) -> Array[Int32] {
  let out : Array[Int32] = []
  let end = if port + span > 65535 { 65535 } else { port + span }
  let mut p = port + 1
  while p <= end {
    out.push(p)
    p = p + 1
  }
  out
}

///|
/// 试着在 bind:port 上建监听。失败时连错误原文一起返回。
async fn try_bind(bind : String, port : Int32) -> (@http.Server?, String) {
  let mut err = ""
  let server = Some(
    @http.Server(@socket.Addr::parse("\{bind}:\{port}"), reuse_addr=true),
  ) catch {
    e => {
      err = e.to_string()
      None
    }
  }
  (server, err)
}

///|
/// 绑定监听端口；端口被占时先退避重试，再决定是退出还是换口。
///
/// 顺序是刻意这么排的：
///   1. 指数退避重试，等的是「旧实例正在退出」
///   2. 还占着 —— 先问一句占着的是不是我们自己，是就干净退出（不抢帧目录）
///   3. 是别人的 —— 往上找第一个能绑的端口，并说清楚换到了哪儿
///
/// 失败时自己打印原因并以 1 退出，调用方拿到 None 直接 return 就行。
pub async fn bind_with_retry(
  bind : String,
  port : Int32,
  fallback : Bool,
) -> (@http.Server, Int32)? {
  let started = try_bind(bind, port)
  let first = started.0
  let mut err = started.1
  match first {
    Some(server) => return Some((server, port))
    None => ()
  }
  let mut attempt = 0
  while attempt < BIND_RETRIES {
    let wait = bind_backoff_ms(attempt)
    eprintln("端口 \{port} 暂时绑不上（\{err}），\{wait}ms 后重试")
    @async.sleep(wait)
    let (server, e) = try_bind(bind, port)
    err = e
    match server {
      Some(s) => return Some((s, port))
      None => ()
    }
    attempt = attempt + 1
  }
  if fallback {
    for p in fallback_ports(port, PORT_FALLBACK_SPAN) {
      let (server, e) = try_bind(bind, p)
      match server {
        Some(s) => {
          eprintln(
            "端口 \{port} 被别的程序占着（\{err}），改用 \{p}",
          )
          eprintln(
            "托盘会读 ~/.local/state/screen-kacha/port 跟着过来；unit 里写的还是 \{port}",
          )
          return Some((s, p))
        }
        None => err = e
      }
    }
    eprintln(
      "端口 \{port}..\{port + PORT_FALLBACK_SPAN} 都绑不上（最后一个是：\{err}）",
    )
  } else {
    eprintln("端口 \{bind}:\{port} 绑不上（\{err}）")
  }
  eprintln(
    "换一个：--port <号>；或看谁占着：ss -ltnp | grep :\{port}",
  )
  @store.exit_process(1)
  None
}

///|
/// flag 型参数有没有被点上。
fn flag_on(m : @argparse.Matches, name : String) -> Bool {
  m.flags.get(name) == Some(true)
}

///|
/// 把实际监听的端口写进状态目录，供托盘发现。
///
/// 端口被占时会往上挪，托盘要是死认 unit 里写的那一个号，就会一直显示
/// 「服务没响应」——而服务其实好好地跑在隔壁端口上。
async fn write_port_file(port : Int32) -> Unit {
  match @env.get_env_var("HOME") {
    Some(h) => {
      let dir = "\{h}/.local/state/screen-kacha"
      let _ = @fs.mkdir(dir, permission=0o700, recursive=true) catch { _ => () }
      let _ = @fs.write_file(
        "\{dir}/port",
        @utf8.encode(port.to_string()),
        create_mode=CreateOrTruncate,
      ) catch {
        _ => ()
      }
    }
    None => ()
  }
}
