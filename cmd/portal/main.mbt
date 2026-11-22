///|
/// xdg-desktop-portal ScreenCast 客户端。
///
/// 建会话、请求显示器流、拿 pipewire node id，然后把会话一直挂着
/// （node 随会话存活，这个进程一退节点就消失）。
///
/// 用法：screen-kacha-portal --out <node 文件> [--token <restore token 文件>]

///|
fn u32_at(b : Bytes, off : Int32) -> Int32 {
  b[off].to_int() |
  (b[off + 1].to_int() << 8) |
  (b[off + 2].to_int() << 16) |
  (b[off + 3].to_int() << 24)
}

///|
fn find_bytes(hay : Bytes, needle : Bytes) -> Int32 {
  let n = needle.length()
  for i = 0; i <= hay.length() - n; i = i + 1 {
    let mut same = true
    for j = 0; j < n; j = j + 1 {
      if hay[i + j] != needle[j] {
        same = false
        break
      }
    }
    if same {
      return i
    }
  }
  -1
}

///|
/// 在字节里找 marker 之后的一段 base64 样式的串（restore_token 就是这种）。
fn token_after(b : Bytes, marker : String) -> String? {
  let at = find_bytes(b, @utf8.encode(marker))
  if at < 0 {
    return None
  }
  let limit = if at + 300 < b.length() { at + 300 } else { b.length() }
  let mut best_start = -1
  let mut best_len = 0
  let mut i = at + marker.length()
  while i < limit {
    let c = b[i].to_int()
    let ok = (c >= 48 && c <= 57) ||
      (c >= 65 && c <= 90) ||
      (c >= 97 && c <= 122) ||
      c == 95 ||
      c == 45
    if ok {
      let start = i
      while i < limit {
        let d = b[i].to_int()
        let ok2 = (d >= 48 && d <= 57) ||
          (d >= 65 && d <= 90) ||
          (d >= 97 && d <= 122) ||
          d == 95 ||
          d == 45
        if !ok2 {
          break
        }
        i = i + 1
      }
      let len = i - start
      if len > best_len {
        best_len = len
        best_start = start
      }
    } else {
      i = i + 1
    }
  }
  if best_len < 8 || best_start < 0 {
    return None
  }
  Some(@utf8.decode_lossy(Bytes::makei(best_len, fn(k) { b[best_start + k] })))
}

///|
/// 从 marker 之后抠一个以 want 开头的路径串（session_handle 是 /org/... 这种）。
fn path_after(b : Bytes, marker : String, want : Char) -> String? {
  let at = find_bytes(b, @utf8.encode(marker))
  if at < 0 {
    return None
  }
  let mut start = at + marker.length()
  while start < b.length() && b[start].to_int() != want.to_int() {
    start = start + 1
  }
  if start >= b.length() {
    return None
  }
  let mut end = start
  while end < b.length() && b[end].to_int() != 0 {
    end = end + 1
  }
  Some(@utf8.decode_lossy(Bytes::makei(end - start, fn(i) { b[start + i] })))
}

///|
/// results 里 "streams" 是 a(ua{sv})：跳过键名与变体签名后，第一个 u32 就是 node id。
fn stream_node(b : Bytes) -> Int32? {
  let at = find_bytes(b, @utf8.encode("streams"))
  if at < 0 {
    return None
  }
  // 键名 "streams" 后面是 NUL，再后面是变体签名 "a(ua{sv})"（长度字节 + 内容 + NUL）
  let mut p = at + 7
  while p < b.length() && b[p].to_int() != 0 {
    p = p + 1
  }
  p = p + 1
  // 数组长度前缀对齐到 4
  p = (p + 3) / 4 * 4
  p = p + 4
  // 结构体对齐到 8
  p = (p + 7) / 8 * 8
  if p + 4 > b.length() {
    return None
  }
  Some(u32_at(b, p))
}

///|
fn wait_response(conn : @dbus.Connection) -> (Int32, Bytes)? {
  for k = 0; k < 240; k = k + 1 {
    let raw = match @dbus.recv_message(conn) {
      Ok(r) => r
      Err(_) => break
    }
    let m = match @dbus.parse_message(raw) {
      Some(m) => m
      None => continue
    }
    if m.msg_type == 4 {
      let body = m.body
      let rest = Bytes::makei(body.length() - 4, fn(i) { body[4 + i] })
      return Some((u32_at(body, 0), rest))
    }
  }
  None
}

///|
fn call_portal(
  conn : @dbus.Connection,
  meth : String,
  sig : String,
  body : Bytes,
  serial : Int32,
) -> Bool {
  match
    @dbus.call(
      conn, "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
      "org.freedesktop.portal.ScreenCast", meth, body, sig, serial,
    ) {
    Ok(_) => true
    Err(_) => false
  }
}

///|
/// 读上次存下的 restore token，没有就返回空串。
async fn read_token(path : String) -> String {
  if path == "" {
    return ""
  }
  let f = Some(@fs.open(path, mode=ReadOnly)) catch { _ => None }
  match f {
    None => ""
    Some(file) => {
      let data = Some(file.read_all()) catch { _ => None }
      file.close()
      match data {
        None => ""
        Some(r) => @utf8.decode_lossy(r.binary())
      }
    }
  }
}

///|
async fn main {
  let args = @env.args()
  let mut out_path = ""
  let mut token_path = ""
  let mut i = 1
  while i < args.length() {
    if args[i] == "--out" && i + 1 < args.length() {
      out_path = args[i + 1]
      i = i + 2
    } else if args[i] == "--token" && i + 1 < args.length() {
      token_path = args[i + 1]
      i = i + 2
    } else {
      i = i + 1
    }
  }
  if out_path == "" {
    eprintln("portal: 缺少 --out")
    return
  }

  let conn = match @dbus.connect_bus() {
    Ok(c) => c
    Err(e) => {
      eprintln("portal: 连不上会话总线 \{e}")
      return
    }
  }
  match @dbus.hello(conn) {
    Ok(_) => ()
    Err(e) => {
      eprintln("portal: Hello 失败 \{e}")
      return
    }
  }
  // 订阅 Response 信号
  let e = @dbus.Encoder::new()
  e.string(
    "type='signal',interface='org.freedesktop.portal.Request',member='Response'",
  )
  match
    @dbus.call(
      conn,
      "org.freedesktop.DBus",
      "/org/freedesktop/DBus",
      "org.freedesktop.DBus",
      "AddMatch",
      e.finish(),
      "s",
      10,
    ) {
    Ok(_) => ()
    Err(_) => ()
  }

  // CreateSession
  let cs = @dbus.Encoder::new()
  cs.array_with(8, fn(a) {
    a.struct_with_align(8, fn(s) {
      s.string("handle_token")
      s.signature("s")
      s.string("ssmba")
    })
    a.struct_with_align(8, fn(s) {
      s.string("session_handle_token")
      s.signature("s")
      s.string("ssmb")
    })
  })
  if !call_portal(conn, "CreateSession", "a{sv}", cs.finish(), 11) {
    eprintln("portal: CreateSession 调用失败")
    return
  }
  let (code1, res1) = match wait_response(conn) {
    Some(v) => v
    None => {
      eprintln("portal: 等 CreateSession 响应超时")
      return
    }
  }
  if code1 != 0 {
    eprintln("portal: CreateSession 被拒，码 \{code1}")
    return
  }
  let session = match path_after(res1, "session_handle", '/') {
    Some(s) => s
    None => {
      eprintln("portal: 响应里没有 session_handle")
      return
    }
  }
  eprintln("portal: 会话 \{session}")

  // SelectSources：显示器 + 持久会话
  let saved = read_token(token_path)
  let ss = @dbus.Encoder::new()
  ss.string(session)
  ss.array_with(8, fn(a) {
    a.struct_with_align(8, fn(s) {
      s.string("handle_token")
      s.signature("s")
      s.string("ssmbb")
    })
    a.struct_with_align(8, fn(s) {
      s.string("types")
      s.signature("u")
      s.u32(1)
    })
    a.struct_with_align(8, fn(s) {
      s.string("multiple")
      s.signature("b")
      s.bool(false)
    })
    a.struct_with_align(8, fn(s) {
      s.string("persist_mode")
      s.signature("u")
      s.u32(2)
    })
    // 光标画进画面：0=隐藏 1=嵌入 2=单独给元数据。
    // 不传的话由 portal 实现自己定，KDE 下拿到的画面里没有光标，
    // 对「看看屏幕上现在是什么」这个用途来说少了一半信息。
    a.struct_with_align(8, fn(s) {
      s.string("cursor_mode")
      s.signature("u")
      s.u32(1)
    })
    if saved != "" {
      a.struct_with_align(8, fn(s) {
        s.string("restore_token")
        s.signature("s")
        s.string(saved)
      })
    }
  })
  if !call_portal(conn, "SelectSources", "oa{sv}", ss.finish(), 12) {
    eprintln("portal: SelectSources 调用失败")
    return
  }
  let (code2, _) = match wait_response(conn) {
    Some(v) => v
    None => {
      eprintln("portal: 等 SelectSources 响应超时")
      return
    }
  }
  if code2 != 0 {
    eprintln("portal: SelectSources 被拒，码 \{code2}")
    return
  }

  // Start
  let st = @dbus.Encoder::new()
  st.string(session)
  st.string("")
  st.array_with(8, fn(a) {
    a.struct_with_align(8, fn(s) {
      s.string("handle_token")
      s.signature("s")
      s.string("ssmbc")
    })
  })
  if !call_portal(conn, "Start", "osa{sv}", st.finish(), 13) {
    eprintln("portal: Start 调用失败")
    return
  }
  let (code3, res3) = match wait_response(conn) {
    Some(v) => v
    None => {
      eprintln("portal: 等 Start 响应超时（授权框没确认？）")
      return
    }
  }
  if code3 != 0 {
    eprintln("portal: Start 被拒，码 \{code3}")
    return
  }

  if token_path != "" {
    match token_after(res3, "restore_token") {
      Some(t) => {
        let f = @fs.create(token_path, allow_existing=true) catch {
          _ => {
            eprintln("portal: token 文件打不开")
            return
          }
        }
        f.write(@utf8.encode(t)) catch {
          _ => eprintln("portal: token 写入失败")
        }
        f.close()
        eprintln("portal: restore_token 已保存")
      }
      None => eprintln("portal: 这次没有 restore_token")
    }
  }

  match stream_node(res3) {
    None => eprintln("portal: 响应里没有 streams")
    Some(id) => {
      let f = @fs.create(out_path, allow_existing=true) catch {
        _ => {
          eprintln("portal: node 文件打不开")
          return
        }
      }
      f.write(@utf8.encode("\{id}")) catch {
        _ => eprintln("portal: node 写入失败")
      }
      f.close()
      eprintln("portal: node=\{id}，会话保持中")
      // 一直睡着，直到进程被外部干掉（systemd 停服务、用户注销、机器关机）。
      //
      // 这里原来是 `for k = 0; k < 86400` —— 正好 24 小时，睡满就正常返回、
      // 退出码 0。后果非常隐蔽：服务跑一天后 node 静默消失，因为退出码是 0，
      // systemd 的 Restart=on-failure 不会拉起它；而 portal.node 文件还留着
      // 旧 id，主服务照用不误 → 「开机好好的，跑一天截图就永久坏掉」。
      // 用「睡 N 次」来表达「永远挂着」，本身就是个坑。
      for ;; {
        @async.sleep(3600000)
      }
    }
  }
}
