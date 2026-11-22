///|
/// 端口被占用时，往上最多再找几个。
const PORT_FALLBACK_SPAN : Int32 = 8

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
/// 绑定监听端口。被占就直接往上找一个能用的，不等待。
///
/// 这里刻意没有退避重试。
///
/// 调用方在进来之前已经拿到了帧目录的锁（见 main 里的 acquire_instance_lock）：
/// 拿得到锁，说明本机没有第二份 screen-kacha 在跑。既然是「别人」占着这个端口，
/// 等 250ms 还是等 2 秒结果都一样 —— 它不会自己让开。等待只会在启动路径上
/// 多加几秒，还给人「等久一点就成功」的错觉。
///
/// TIME_WAIT 不算占用：建监听时开了 reuse_addr，旧连接残留不会挡路。
///
/// 失败时自己打印原因并以 1 退出，调用方拿到 None 直接 return 就行。
pub async fn bind_with_fallback(
  bind : String,
  port : Int32,
  fallback : Bool,
) -> (@http.Server, Int32)? {
  let started = try_bind(bind, port)
  match started.0 {
    Some(server) => return Some((server, port))
    None => ()
  }
  let err = started.1
  if fallback {
    for p in fallback_ports(port, PORT_FALLBACK_SPAN) {
      let (server, _e) = try_bind(bind, p)
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
        None => ()
      }
    }
    eprintln(
      "端口 \{port}..\{port + PORT_FALLBACK_SPAN} 都被占着（\{err}）",
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
