///|
test "parse_int：正常、空串与非法字符" {
  assert_eq(@util.parse_int("18940", 0), 18940)
  assert_eq(@util.parse_int("0", 7), 0)
  assert_eq(@util.parse_int("", 7), 7)
  assert_eq(@util.parse_int("12a", 7), 7)
  assert_eq(@util.parse_int("--1", 7), 7)
}

///|
test "pick：取到值、回落默认、未知键" {
  let cmd = cli_cmd()
  let m = cmd.parse(argv=["--port", "9999", "--idle", "0"])
  assert_eq(@util.pick(m, "port", "1"), "9999")
  assert_eq(@util.pick(m, "idle", "20"), "0")
  assert_eq(@util.pick(m, "bind", "0.0.0.0"), "0.0.0.0")
  assert_eq(@util.pick(m, "nope", "dflt"), "dflt")
}

///|
test "cli_cmd：除端口外都有默认值" {
  let cmd = cli_cmd()
  let m = cmd.parse(argv=[])
  // 端口必须由调用方给：代码里的默认值和安装版的端口是两回事，
  // 静默挑一个会让人以为连的是同一个服务
  assert_eq(@util.pick(m, "port", ""), "")
  let m2 = cmd.parse(argv=["--port", "18940"])
  assert_eq(@util.pick(m2, "port", ""), "18940")
  assert_eq(@util.pick(m, "bind", ""), "0.0.0.0")
  assert_eq(@util.pick(m, "idle", ""), "20")
  assert_eq(@util.pick(m, "shm", ""), "/tmp/screen-kacha")
  assert_eq(@util.pick(m, "max-conns", ""), "64")
}

///|
/// 启动横幅要陈述「谁能取图」，不能把「局域网放行」包装成「访问控制：启用」。
///
/// 原来那行的判据是 `allow_public`，局域网放行也走「启用」分支，读起来像
/// 已经有一层防护，其实同网段任何设备都能取整屏。
test "启动横幅只说事实，不说「启用」" {
  let lan = @store.parse_access("allow_lan = true\nallow_public = false")
  let lines = access_banner(lan, "0.0.0.0", 8930)
  assert_true(lines[0].has_prefix("允许来源："))
  let text = lines.join("\n")
  assert_false(text.contains("启用"))
  // 必须点明放行的是整个网段，不是只有自己的设备
  assert_true(text.contains("整个局域网网段"))
  // 全放行要给更直白的警示
  let open = @store.parse_access("allow_public = true")
  assert_true(
    access_banner(open, "0.0.0.0", 8930).join("\n").contains("都能取整屏"),
  )
  // 仅本机时不啰嗦，只留一行
  let solo = @store.parse_access("allow_lan = false\nallow_public = false")
  let solo_lines = access_banner(solo, "127.0.0.1", 8930)
  assert_eq(solo_lines.length(), 1)
  assert_true(solo_lines[0].contains("仅本机"))
}

///|
/// 清理陈旧原始帧要用文件名前缀，得能正确取出最后一段。
test "base_name 取路径最后一段" {
  assert_eq(base_name("/run/user/1000/screen-kacha/latest.jpg"), "latest.jpg")
  assert_eq(base_name("latest.jpg"), "latest.jpg")
  assert_eq(base_name("/a/b/c.png"), "c.png")
  assert_eq(base_name("/"), "")
  assert_eq(base_name(""), "")
}

///|
/// --source 只认三个值，写错了启动就报错。
///
/// 原来非法值被静默当成 auto：用户写 `--source spectacl` 以为限定了取帧方式，
/// 实际照旧优先 PipeWire。
test "source 只认 auto / pipewire / spectacle" {
  assert_true(source_valid("auto"))
  assert_true(source_valid("pipewire"))
  assert_true(source_valid("spectacle"))
  assert_false(source_valid("spectacl"))
  assert_false(source_valid(""))
  assert_false(source_valid("Auto"))
}

///|
/// --pump-idle 现在真的接在 CLI 上。
///
/// 原来 main 里去 pick 它，但 cli_cmd 里没声明：用户真传会被 argparse
/// 当成未知参数直接退出，空闲泵间隔事实上是硬编码的。
test "pump-idle 是声明过的参数" {
  let cmd = cli_cmd()
  let m = cmd.parse(argv=["--pump-idle", "5000"])
  assert_eq(@util.pick(m, "pump-idle", "3000"), "5000")
  let d = cmd.parse(argv=[])
  assert_eq(@util.pick(d, "pump-idle", "3000"), "3000")
}

///|
/// 端口文件必须认 XDG_STATE_HOME。
///
/// 以前这里直接拼 HOME：临时实例（测试、探针、手动起的第二个进程）会把生产
/// 的状态文件改掉，托盘照着那个死端口轮询，就显示「服务没响应」—— 服务其实
/// 好好地跑在 8930 上。这次就是这么被坑的。
test "state_dir 认 XDG_STATE_HOME" {
  assert_eq(
    @util.state_dir_with(Some("/tmp/xdg-state"), Some("/home/someone")),
    Some("/tmp/xdg-state/screen-kacha"),
  )
  // 没设 XDG_STATE_HOME 时走 HOME 的老路径
  assert_eq(
    @util.state_dir_with(None, Some("/home/someone")),
    Some("/home/someone/.local/state/screen-kacha"),
  )
  // 两个都没有就不写：宁可没有端口文件，也不要写到别处
  assert_eq(@util.state_dir_with(None, None), None)
}

///|
test "named instance default paths do not collide" {
  assert_eq(default_shm("default"), "/tmp/screen-kacha")
  assert_eq(default_shm("capture-b"), "/tmp/screen-kacha-capture-b")
  assert_eq(
    @util.instance_state_dir_with(
      Some("/state"),
      Some("/home/u"),
      Some("capture-b"),
    ),
    Some("/state/screen-kacha/instances/capture-b"),
  )
}

///|
test "CLI exposes instance and shared portal directory" {
  let m = cli_cmd().parse(argv=[
    "--port", "8931", "--instance", "capture-b", "--portal-dir", "/run/user/1000/screen-kacha",
  ])
  assert_eq(@util.pick(m, "instance", "default"), "capture-b")
  assert_eq(@util.pick(m, "portal-dir", ""), "/run/user/1000/screen-kacha")
}
