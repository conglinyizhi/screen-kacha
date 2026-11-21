///|
#borrow(cmd)
extern "c" fn run_shell(cmd : Bytes) -> Int32 = "moonbit_screenstream_run"

///|
#borrow(cmd, buf)
extern "c" fn capture_shell(cmd : Bytes, buf : Bytes, len : Int32) -> Int32 = "moonbit_screenstream_capture"

///|
extern "c" fn exit_now(code : Int32) -> Unit = "moonbit_screenstream_exit"

///|
#borrow(path, data)
extern "c" fn write_file_raw(path : Bytes, data : Bytes) -> Int32 = "moonbit_screenstream_write_file"

///|
/// 写配置文件。同步调用，托盘菜单里用。
fn write_file(path : String, data : String) -> Bool {
  write_file_raw(cstr(path), cstr(data)) == 0
}

///|
fn cstr(s : String) -> Bytes {
  let src = @utf8.encode(s)
  let n = src.length()
  Bytes::makei(n + 1, fn(i) { if i < n { src[i] } else { 0 } })
}

///|
fn sh(cmd : String) -> Unit {
  run_shell(cstr(cmd)) |> ignore
}

///|
fn capture(cmd : String, limit : Int32) -> String {
  let buf = Bytes::makei(limit + 1, fn(_) { 0 })
  let n = capture_shell(cstr(cmd), buf, limit + 1)
  if n <= 0 {
    return ""
  }
  @utf8.decode_lossy(buf[0:n])
}

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

///|
/// 按 /health 的返回挑图标名和一句话说明。
///
/// 灯的颜色就是这个函数唯一的输出：绿=正常，黄=刚启动，灰=没响应，红=采集失败。
fn health_state(body : String) -> (String, String) {
  if body == "" {
    return ("screenstream-dead", "服务没响应")
  }
  if body.contains("\"ok\": true") {
    return ("screenstream-ok", "正常")
  }
  if body.contains("\"count\": 0") {
    return ("screenstream-warn", "已启动，还没抓到帧")
  }
  ("screenstream-down", "采集失败")
}

///|
/// 查一次健康状态，更新图标和标题。
fn poll_icon(t : @sni.Tray, base : String) -> Unit {
  let h = capture("curl -s --max-time 2 '\{base}/health'", 2048)
  let (icon, _say) = health_state(h)
  t.set_icon_name(icon)
}

///|
/// 访问控制配置文件路径。
fn access_path() -> String {
  match @env.get_env_var("HOME") {
    Some(h) => "\{h}/.config/screenstream-mb/access.conf"
    None => "/etc/screenstream-mb/access.conf"
  }
}

///|
/// 从配置文本里读一个布尔项，缺省用 dflt。
fn read_flag(text : String, key : String, dflt : Bool) -> Bool {
  for line in text.split("\n") {
    let s : String = line.trim().to_owned()
    if s.has_prefix("#") {
      continue
    }
    match s.find("=") {
      None => ()
      Some(eq) =>
        if s[:eq].trim().to_owned() == key {
          let v : String = s[eq + 1:].trim().to_owned()
          return v == "true" || v == "1" || v == "yes"
        }
    }
  }
  dflt
}

///|
/// 读当前访问策略：返回 (局域网放行, 公网放行)。
fn read_access() -> (Bool, Bool) {
  let text = capture("cat '\{access_path()}' 2>/dev/null", 4096)
  (read_flag(text, "allow_lan", true), read_flag(text, "allow_public", false))
}

///|
/// 把两档开关写回配置并重启服务让它生效。失败返回 false。
fn write_access(lan : Bool, public : Bool) -> Bool {
  let body = "# screenstream 访问控制（托盘菜单会改写这个文件）\n" +
    "allow_lan = \{lan}\n" +
    "allow_public = \{public}\n"
  if !write_file(access_path(), body) {
    return false
  }
  run_status("systemctl --user restart screenstream-mb.service") == 0
}

///|
/// 托盘自己是不是开机启动的。决定「退出」这句话怎么说才不误解。
fn tray_autostart() -> Bool {
  let out = capture(
    "systemctl --user is-enabled screenstream-mb-tray.service 2>/dev/null", 64,
  )
  out.trim().to_owned() == "enabled"
}

///|
/// 服务与托盘是否都开机启动。
fn boot_enabled() -> Bool {
  let out = capture(
    "systemctl --user is-enabled screenstream-mb.service screenstream-mb-tray.service 2>/dev/null | grep -c enabled",
    64,
  )
  parse_int(out.trim(), 0) >= 2
}

///|
/// 开/关两个 unit 的开机启动。失败返回 false。
fn set_boot(on : Bool) -> Bool {
  let verb = if on { "enable" } else { "disable" }
  run_status(
    "systemctl --user \{verb} screenstream-mb.service screenstream-mb-tray.service",
  ) == 0
}

///|
/// 重启服务。失败返回 false。
fn restart_service() -> Bool {
  run_status("systemctl --user restart screenstream-mb.service") == 0
}

///|
fn main raise {
  let cmd = @argparse.Command(
    "screenstream-tray",
    about="screenstream 托盘",
    options=[
      @argparse.OptionArg("port", about="服务端口", default_values=["8930"]),
    ],
  )
  let m = cmd.parse()
  let port = parse_int(pick(m, "port", "8930"), 8930)
  let base = "http://127.0.0.1:\{port}"
  let cfg = @sni.default_tray_config(
    "screenstream", "screenstream 屏幕快照", "video-display",
  )
  let t = @sni.tray(cfg)
  t.on("open", "打开 :\{port} 页面", fn(_) { sh("xdg-open '\{base}/'") })
  |> ignore
  t.separator()
  let (lan_on, public_on) = read_access()
  let cb_lan = t.checkbox("allow_lan", "放行局域网请求", lan_on, fn(
    item,
  ) {
    let (_, cur_public) = read_access()
    if !write_access(item.checked(), cur_public) {
      alert(
        "访问控制设置失败",
        "写配置或重启服务失败了。可以检查 ~/.config/screenstream-mb/ 是否可写，或用 journalctl --user -xe 看原因。",
        "access",
      )
      item.set_checked(!item.checked())
    }
  })
  let cb_public = t.checkbox(
    "allow_public",
    "[危险] 放行非局域网请求",
    public_on,
    fn(item) {
      let (cur_lan, _) = read_access()
      if !write_access(cur_lan, item.checked()) {
        alert(
          "访问控制设置失败",
          "写配置或重启服务失败了。可以检查 ~/.config/screenstream-mb/ 是否可写，或用 journalctl --user -xe 看原因。",
          "access",
        )
        item.set_checked(!item.checked())
      }
    },
  )
  // 退出项的文案取决于托盘是否开机自启：先占位，勾选时同步改
  let quit_ref : Ref[@menu.ItemHandle?] = Ref(None)
  let cb_boot = t.checkbox(
    "boot",
    "开机启动（使用 systemd）",
    boot_enabled(),
    fn(item) {
      if system_unit_conflict() {
        alert(
          "无法用托盘管理开机启动", "检测到系统级（非 --user）的同名 systemd unit。\n托盘只能用 systemctl --user 管理用户级 unit，对系统级无效。\n\n请自行用 sudo systemctl disable screenstream-mb 处理，或先删掉系统级 unit。",
          "sysunit",
        )
        // 勾选状态以真实状态为准，避免看起来像生效了
        item.set_checked(!item.checked())
        return
      }
      let on = item.checked()
      if !set_boot(on) {
        alert(
          "开机启动设置失败",
          "调用 systemctl 失败了。可以用 journalctl --user -xe 看看具体原因。",
          "boot",
        )
        item.set_checked(!on)
        return
      }
      match quit_ref.val {
        Some(q) =>
          q.set_title(
            if on {
              "退出托盘（直到下次开机）"
            } else {
              "退出托盘"
            },
          )
        None => ()
      }
    },
  )
  let _ = (cb_lan, cb_public, cb_boot)
  t.separator()
  t.on("restart", "重启服务", fn(_) {
    if !restart_service() {
      alert(
        "重启服务失败",
        "systemctl 调用返回了非零退出码。可以用 systemctl --user status screenstream-mb 看看状态。",
        "service",
      )
    }
  })
  |> ignore
  t.separator()
  // 左键点图标直接开页面
  t.on_click(fn(_x, _y) { sh("xdg-open '\{base}/'") })
  let quit_label = if tray_autostart() {
    "退出托盘（直到下次开机）"
  } else {
    "退出托盘"
  }
  let quit_item = t.on("quit", quit_label, fn(_) { exit_now(0) })
  quit_ref.val = Some(quit_item)
  // 每 5 秒查一次，图标跟着健康状态变
  match t.run_with_tick(fn() { poll_icon(t, base) }, 5000) {
    Ok(_) => eprintln("托盘事件循环已结束")
    Err(code) => eprintln("托盘启动失败，错误码 \{code}")
  }
}
