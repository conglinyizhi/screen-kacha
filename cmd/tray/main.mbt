///|
#borrow(cmd)
extern "c" fn run_shell(cmd : Bytes) -> Int32 = "moonbit_screenstream_run"

///|
#borrow(cmd, buf)
extern "c" fn capture_shell(cmd : Bytes, buf : Bytes, len : Int32) -> Int32 = "moonbit_screenstream_capture"

///|
extern "c" fn exit_now(code : Int32) -> Unit = "moonbit_screenstream_exit"

///|
/// 挂上 SIGTERM/SIGINT 的处理：只置标志，真正的收摊交给事件循环。
extern "c" fn watch_stop() = "moonbit_screenstream_watch_stop"

///|
/// 收到过 SIGTERM/SIGINT 吗。
extern "c" fn should_stop() -> Int32 = "moonbit_screenstream_should_stop"

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
/// flag 型参数有没有被点上。
fn flag_on(m : @argparse.Matches, name : String) -> Bool {
  m.flags.get(name) == Some(true)
}

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
///|
/// 解析布尔值。大小写不敏感，跟服务端的 `parse_flag_value` 同一套规则。
fn flag_value(v : String) -> Bool {
  let s = v.trim().to_owned()
  let buf = StringBuilder()
  for i = 0; i < s.length(); i = i + 1 {
    let c = s[i].to_int()
    if c >= 65 && c <= 90 {
      buf.write_char((c + 32).unsafe_to_char())
    } else {
      buf.write_char(c.unsafe_to_char())
    }
  }
  let t = buf.to_string()
  t == "true" || t == "1" || t == "yes" || t == "on"
}

///|
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
          return flag_value(s[eq + 1:].trim().to_owned())
        }
    }
  }
  dflt
}

///|
/// 读当前访问策略：返回 (局域网放行, 公网放行, 100.64/10 也算局域网)。
///
/// 上限放到 64KB 且要求读满：原来是 4096，配置一旦超过就会被截断，
/// 后半个文件里的真实值读不到，`read_flag` 只能退回默认值，
/// 然后 `write_access` 拿这个默认值把用户的配置覆盖掉，
/// 等于「点一次菜单，设置被静默重置」。
fn read_access() -> (Bool, Bool, Bool) {
  let text = capture_whole(access_path())
  match text {
    Some(t) =>
      // 老配置的 local_only 要跟服务端一样认：true 就是「仅本机」。
      // 否则托盘显示「放行局域网」，实际只放行本机，用户从界面上推不出
      // 「现在谁能看我的屏幕」。
      if read_flag(t, "local_only", false) {
        (false, false, false)
      } else {
        (
          read_flag(t, "allow_lan", true),
          read_flag(t, "allow_public", false),
          read_flag(t, "allow_cgnat", false),
        )
      }
    // 读不出来（不存在 / 太大 / 权限）就当作默认，但绝不用它去覆盖
    None => (true, false, false)
  }
}

///|
/// 把整个文件读进来。读不全返回 None，宁可不改，也不拿半截内容去写。
fn capture_whole(path : String) -> String? {
  let limit = 65536
  let out = capture("cat '\{path}' 2>/dev/null", limit)
  // capture 填满缓冲说明可能被截断，这种内容不能信
  if out.length() >= limit {
    return None
  }
  Some(out)
}

///|
/// 把两档开关写回配置并重启服务让它生效。失败返回 false。
fn write_access(lan : Bool, public : Bool, cgnat : Bool) -> Bool {
  // 只改这两行，别的一律原样保留。
  //
  // 原来是整文件重写（只留三行）：用户手写的注释、`allow` 名单
  // 全都会在一次点击里消失。那个 `allow` 名单是有用的配置，不是垃圾。
  let old = capture_whole(access_path())
  let body = rewrite_flags(old, lan, public, cgnat)
  if !write_file(access_path(), body) {
    return false
  }
  // 服务重启失败时，配置文件里已经是新值了，勾选却被回滚，
  // 两边相反，下次服务重启又突然生效。这里把写入也退回去。
  if run_status("systemctl --user restart screenstream-mb.service") != 0 {
    match old {
      Some(t) => {
        let _ = write_file(access_path(), t)
      }
      None => ()
    }
    return false
  }
  true
}

///|
/// 在保留原有内容的前提下，改掉 allow_lan / allow_public / allow_cgnat 三行。
/// 没有这两行就追加，其它行（注释、allow 名单、未知键）原样留着。
///|
/// 取一行配置的 key（`=` 左边，去掉空白）。空行和注释返回 None。
///
/// 服务端的 `access.mbt` 里有一份同样的 `config_line_key`。这里没有共用是
/// 有意的：托盘不链接根包，引进来会把 pipewire / jpeg / webp / png 的链接参数
/// 一起拖进这个只做 SNI 的小程序。两份实现都很小，改的时候要一起改。
fn config_key(line : String) -> String? {
  let s : String = line.trim().to_owned()
  if s == "" || s.has_prefix("#") {
    return None
  }
  match s.find("=") {
    None => None
    Some(eq) => Some(s[:eq].trim().to_owned())
  }
}

///|
fn rewrite_flags(
  old : String?,
  lan : Bool,
  public : Bool,
  cgnat : Bool,
) -> String {
  let sb = StringBuilder()
  let src = match old {
    Some(t) => t
    None => ""
  }
  let mut seen_lan = false
  let mut seen_public = false
  let mut seen_cgnat = false
  for line in src.split("\n") {
    let s : String = line.to_owned()
    // 按完整 key 比对，不用前缀。未知键（`allow_lan_next` 之类）原样留着，
    // 服务端只认 key 完全相等的行，改写了反而让两边理解不一致。
    let key = match config_key(s) {
      Some(k) => k
      None => ""
    }
    if key == "allow_lan" {
      sb.write_string("allow_lan = \{lan}\n")
      seen_lan = true
    } else if key == "allow_public" {
      sb.write_string("allow_public = \{public}\n")
      seen_public = true
    } else if key == "allow_cgnat" {
      sb.write_string("allow_cgnat = \{cgnat}\n")
      seen_cgnat = true
    } else if s != "" {
      sb.write_string("\{s}\n")
    }
  }
  if !seen_lan {
    sb.write_string("allow_lan = \{lan}\n")
  }
  if !seen_public {
    sb.write_string("allow_public = \{public}\n")
  }
  if !seen_cgnat {
    sb.write_string("allow_cgnat = \{cgnat}\n")
  }
  sb.to_string()
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
  ) ==
  0
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
    flags=[
      @argparse.FlagArg(
        "cursor-on",
        about="挂上光标跟踪然后退出。不点菜单也能测这条路径",
      ),
      @argparse.FlagArg("cursor-off", about="摘掉光标跟踪然后退出"),
    ],
  )
  let m = cmd.parse()
  let port = parse_int(pick(m, "port", "8930"), 8930)
  let helper = match @env.get_env_var("HOME") {
    Some(h) => "\{h}/.local/bin/screenstream-cursor"
    None => "screenstream-cursor"
  }
  // 两个一次性开关：跑完就退，不进事件循环。用来在没有菜单的情况下
  // 验证挂载/摘除这条路径，出问题时也能直接把结论打出来。
  if flag_on(m, "cursor-on") {
    if cursor_tracking_on(helper) {
      eprintln("cursor tracking: on")
      exit_now(0)
    } else {
      eprintln(
        "cursor tracking: on 失败，日志见 journalctl --user -u screenstream-mb-tray",
      )
      exit_now(1)
    }
  }
  if flag_on(m, "cursor-off") {
    cursor_tracking_off()
    eprintln("cursor tracking: off")
    exit_now(0)
  }
  let base = "http://127.0.0.1:\{port}"
  let cfg = @sni.default_tray_config(
    "screenstream", "screenstream 屏幕快照", "video-display",
  )
  let t = @sni.tray(cfg)
  t.on("open", "打开 :\{port} 页面", fn(_) { sh("xdg-open '\{base}/'") })
  |> ignore
  t.separator()
  let (lan_on, public_on, cgnat_on) = read_access()
  let cb_lan = t.checkbox("allow_lan", "放行局域网请求", lan_on, fn(
    item,
  ) {
    let (_, cur_public, cur_cgnat) = read_access()
    if !write_access(item.checked(), cur_public, cur_cgnat) {
      alert(
        "访问控制设置失败", "写配置或重启服务失败了。可以检查 ~/.config/screenstream-mb/ 是否可写，或用 journalctl --user -xe 看原因。",
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
      let (cur_lan, _, cur_cgnat) = read_access()
      if !write_access(cur_lan, item.checked(), cur_cgnat) {
        alert(
          "访问控制设置失败", "写配置或重启服务失败了。可以检查 ~/.config/screenstream-mb/ 是否可写，或用 journalctl --user -xe 看原因。",
          "access",
        )
        item.set_checked(!item.checked())
      }
    },
  )
  // 额外豁免：把 100.64/10 也算局域网。
  //
  // 这一段不属于 RFC1918，公网上确实分配过，所以默认关着。
  // Tailscale、内网穿透这些工具会把流量落在 100.64.x.x，用户遇到
  // 「明明在同一张网里却 403」时才需要它。开启时给一段说明，
  // 让人知道刚才放宽了什么，而不是点完不知道发生了什么。
  let cb_cgnat = t.checkbox(
    "allow_cgnat",
    "额外豁免 100.64/10（内网穿透）",
    cgnat_on,
    fn(item) {
      let (cur_lan, cur_public, _) = read_access()
      let on = item.checked()
      if !write_access(cur_lan, cur_public, on) {
        alert(
          "访问控制设置失败", "写配置或重启服务失败了。可以检查 ~/.config/screenstream-mb/ 是否可写，或用 journalctl --user -xe 看原因。",
          "access",
        )
        item.set_checked(!on)
        return
      }
      if on {
        inform(
          "已放宽 100.64/10", "运营商级 NAT 段现在也算局域网，和「放行局域网请求」用同一个开关。\n\nTailscale、内网穿透这类工具常把地址落在这里。如果你的穿透地址不是这段，用不到这个选项，建议关掉。",
        )
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
          "开机启动设置失败", "调用 systemctl 失败了。可以用 journalctl --user -xe 看看具体原因。",
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
  let _ = (cb_lan, cb_public, cb_cgnat, cb_boot)
  t.separator()
  // 光标跟踪：临时挂一个 KWin 脚本 + 一个收坐标的小进程，勾掉就全撤
  let cb_cursor = t.checkbox(
    "cursor_track",
    "在截图里标出鼠标位置",
    cursor_pos_fresh(),
    fn(item) {
      if item.checked() {
        if !cursor_tracking_on(helper) {
          alert(
            "开不了鼠标坐标跟踪", "挂载 KWin 脚本或等坐标失败。可能的原因：KWin 的 Scripting 接口没响应、脚本文件写不进去、坐标进程抢不到 D-Bus 名字。用 journalctl --user -u screenstream-mb-tray 能看到托盘这边的动作。",
            "cursor",
          )
          item.set_checked(false)
        }
      } else {
        cursor_tracking_off()
      }
    },
  )
  let _ = cb_cursor
  t.separator()
  t.on("restart", "重启服务", fn(_) {
    if !restart_service() {
      alert(
        "重启服务失败", "systemctl 调用返回了非零退出码。可以用 systemctl --user status screenstream-mb 看看状态。",
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
  let quit_item = t.on("quit", quit_label, fn(_) {
    // 退出前把光标跟踪收掉。
    //
    // 不收的话：脚本还挂在 KWin 里、helper 进程还在跑、坐标还在刷新，
    // 而唯一能关掉它的入口（这个菜单）已经没了，用户只能重启 KWin
    // 或重启机器。systemd 重启（SIGTERM）走的是另一条路，见下面
    // watch_stop 那段。
    cursor_tracking_off()
    exit_now(0)
  })
  quit_ref.val = Some(quit_item)
  // systemd 重启（SIGTERM）不会走菜单的退出口，这里把收摊补上。
  // 不补的话：KWin 脚本还挂着、helper 还占着 D-Bus 名字，
  // 每重启一次托盘就多留一份，下次勾选会直接复用这个僵尸。
  watch_stop()
  // 每 5 秒查一次，图标跟着健康状态变
  match
    t.run_with_tick(
      fn() {
        if should_stop() != 0 {
          cursor_tracking_off()
          exit_now(0)
        }
        poll_icon(t, base)
      },
      5000,
    ) {
    Ok(_) => eprintln("托盘事件循环已结束")
    Err(code) => eprintln("托盘启动失败，错误码 \{code}")
  }
}
