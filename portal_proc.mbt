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
  let tok = "\{home}/.local/state/screen-kacha/portal.token"

  // ① 已经有人写了就直接用 —— 但必须先确认写它的助手还活着。
  //
  // 原来是无条件信任：只要文件里有个正数就返回。助手一旦死掉
  // （崩溃、被 kill、会话被外部关闭），文件内容不变，于是这里
  // 每次都直接返回那个死 id，② 和 ③ 永远不会执行 ——
  // 没有任何自愈路径，只能人工删文件或重启服务。
  let cached = parse_node_id(read_bytes_or_empty(out))
  if cached > 0 {
    if portal_helper_alive() {
      return Some(cached)
    }
    // 助手没了，缓存作废：删掉再走下面的重新拉起流程
    eprintln("portal: 助手进程不在了，作废缓存的 node=\{cached}")
    remove_file(out)
  }

  // ② 等 autostart 助手写它（它开机比服务稍晚，重连时也会重写）
  for k = 0; k < 60; k = k + 1 {
    @async.sleep(500)
    let id = parse_node_id(read_bytes_or_empty(out))
    if id > 0 {
      return Some(id)
    }
  }

  // ③ 没有可用的 node。
  //
  // 先看是不是已经有助手在跑（比如 autostart 拉起的 loop，它只是还没
  // 拿到 node 而已）。已经在跑就只等它，绝不能再拉一个 ——
  // 一个进程同时只能持有一条 screencast 会话，两个助手会互相抢，
  // 两边都拿不到 node，还各自弹一次授权框。
  if portal_helper_alive() {
    eprintln("portal: 已有助手在跑，等它拿 node")
    for k = 0; k < 180; k = k + 1 {
      @async.sleep(500)
      let id = parse_node_id(read_bytes_or_empty(out))
      if id > 0 {
        return Some(id)
      }
    }
    eprintln("portal: 助手在跑但一直没写出 node")
    return None
  }

  // 真的没人管：自己拉一个
  let state_dir = "\{home}/.local/state/screen-kacha"
  let _ = Some(@fs.mkdir(state_dir, permission=0o700, recursive=true)) catch {
    _ => None
  }
  let bin = match @env.get_env_var("HOME") {
    Some(h) => "\{h}/.local/bin/screen-kacha-portal"
    None => "screen-kacha-portal"
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

///|
/// 写 portal.node 的那个助手进程还在不在。
///
/// 这里有个坑：`pgrep -x screen-kacha-portal` **永远匹配不到**。
/// Linux 的进程名（comm）上限是 15 个字符，`screen-kacha-portal` 有 18 个，
/// 内核会把它截成 `screen-kacha-po`，pgrep 还会明确警告
/// 「模式要搜索的进程名的长度超过 15 个字符」。
/// 所以只能用 `-f` 匹配完整命令行。
///
/// `-f` 不会杀自己（这里是 pgrep 不是 pkill），模式里带路径前缀
/// 也避免了误伤命令行里恰好含这串的别的进程。
async fn portal_helper_alive() -> Bool {
  let (code, out) = @process.collect_stdout("/usr/bin/pgrep", [
    "-f", "/screen-kacha-portal --out",
  ]) catch {
    _ => return false
  }
  if code != 0 {
    return false
  }
  let text = out.text() catch { _ => return false }
  text.trim() != ""
}

///|
async fn remove_file(path : String) -> Unit {
  let _ = @process.run("/usr/bin/rm", ["-f", path]) catch { _ => 1 }
}
