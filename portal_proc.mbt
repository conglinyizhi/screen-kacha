///|
/// 读整个文件，失败返回空。
async fn read_bytes_or_empty(path : String) -> Bytes {
  let f = Some(@fs.open(path, mode=ReadOnly)) catch { _ => None }
  match f {
    None => Bytes::new(0)
    Some(file) => {
      let data = Some(file.read_all()) catch { _ => None }
      file.close()
      match data {
        None => Bytes::new(0)
        Some(r) => r.binary()
      }
    }
  }
}

///|
/// node 文件里就是一个十进制数字。
fn parse_node_id(b : Bytes) -> Int32 {
  let mut n = 0
  for i = 0; i < b.length(); i = i + 1 {
    let c = b[i].to_int()
    if c >= 48 && c <= 57 {
      n = n * 10 + (c - 48)
    } else if n > 0 {
      break
    }
  }
  n
}

///|
/// 拉起 portal 助手并等它写出 node id。
///
/// 助手是独立进程，它把会话一直挂着，node 才存在。
/// 最多等 90 秒：首次可能需要人工确认授权框。
pub async fn acquire_portal_node(dir : String) -> Int32? {
  let out = "\{dir}/portal.node"
  // token 必须放持久目录：帧目录在 tmpfs 上，重启就没了
  let home = match @env.get_env_var("HOME") {
    Some(h) => h
    None => "/tmp"
  }
  let tok = "\{home}/.local/state/screenstream-mb/portal.token"
  // 清掉上一次遗留的助手，避免旧会话一直占着「正在录制」指示
  let _ = Some(@process.run("/usr/bin/pkill", ["-f", "screenstream-portal"])) catch {
    _ => None
  }
  let state_dir = "\{home}/.local/state/screenstream-mb"
  let _ = Some(@fs.mkdir(state_dir, permission=0o700, recursive=true)) catch {
    _ => None
  }
  let bin = match @env.get_env_var("HOME") {
    Some(h) => "\{h}/.local/bin/screenstream-portal"
    None => "screenstream-portal"
  }
  let spawned = Some(@process.spawn_orphan(bin, ["--out", out, "--token", tok])) catch {
    _ => None
  }
  match spawned {
    None => {
      eprintln("拉起 portal 助手失败")
      return None
    }
    Some(_) => ()
  }
  for i = 0; i < 180; i = i + 1 {
    let exists = @fs.exists(out) catch { _ => false }
    if exists {
      let id = parse_node_id(read_bytes_or_empty(out))
      if id > 0 {
        return Some(id)
      }
    }
    @async.sleep(500)
  }
  None
}
