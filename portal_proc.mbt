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
/// 删掉 node 文件，下次重新拿。
pub async fn forget_portal_node(dir : String) -> Unit {
  let _ = Some(@fs.remove("\{dir}/portal.node")) catch { _ => None }
}

///|
/// 拿 portal 给出来的 pipewire node id。
///
/// 正常情况是 autostart 那个助手（跑在 app-...@autostart.service 里，portal 认得出
/// app id，授权记得住）把 node 写进文件，这里只读文件，不碰它。
/// 只有在没人写文件时才自己拉一个助手 —— 那种身份 portal 认不出来，会弹授权框。
pub async fn acquire_portal_node(dir : String) -> Int32? {
  let out = "\{dir}/portal.node"
  let home = match @env.get_env_var("HOME") {
    Some(h) => h
    None => "/tmp"
  }
  let tok = "\{home}/.local/state/screenstream-mb/portal.token"

  // ① 已经有人写了就直接用
  let first = parse_node_id(read_bytes_or_empty(out))
  if first > 0 {
    return Some(first)
  }

  // ② 等 autostart 助手写它（它开机比服务稍晚，重连时也会重写）
  for k = 0; k < 60; k = k + 1 {
    @async.sleep(500)
    let id = parse_node_id(read_bytes_or_empty(out))
    if id > 0 {
      return Some(id)
    }
  }

  // ③ 没人管：自己拉一个
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
  for k = 0; k < 180; k = k + 1 {
    @async.sleep(500)
    let id = parse_node_id(read_bytes_or_empty(out))
    if id > 0 {
      return Some(id)
    }
  }
  None
}
