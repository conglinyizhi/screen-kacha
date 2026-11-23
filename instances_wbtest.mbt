///|
/// 把字符串数组拼成一个串，方便比较（Array 的相等性不好直接断言）。
fn joined_names(arr : Array[String]) -> String {
  let out = StringBuilder()
  let mut first = true
  for s in arr {
    if !first {
      out.write_char(',')
    }
    first = false
    out.write_string(s)
  }
  out.to_string()
}

///|
/// 一个典型的自身：装好的二进制，KDE Wayland 会话里的终端环境。
fn me_kde() -> ProcInfo {
  {
    pid: 100,
    exe: "screen-kacha",
    wayland_display: "wayland-0",
    display: ":0",
  }
}

///|
/// 同机第二个实例：同一个显示、同一个可执行名 —— 就是要报出来的那种。
test "同机实例：同一个显示同一个可执行名要报" {
  let out = screen_capture_conflicts(me_kde(), [
    {
      pid: 200,
      exe: "screen-kacha",
      wayland_display: "wayland-0",
      display: ":0",
    },
  ])
  assert_eq(joined_names(out.map(fn(p) { p.to_string() })), "200")
}

///|
/// 不同显示就是另一个会话，跟我们的屏没关系。
test "同机实例：不同显示不报" {
  // 另一个 Wayland 会话
  assert_true(
    screen_capture_conflicts(me_kde(), [
      {
        pid: 200,
        exe: "screen-kacha",
        wayland_display: "wayland-1",
        display: ":1",
      },
    ]).is_empty(),
  )
  // 同一个 Wayland、另一个 X display
  assert_true(
    screen_capture_conflicts(me_kde(), [
      {
        pid: 200,
        exe: "screen-kacha",
        wayland_display: "wayland-0",
        display: ":1",
      },
    ]).is_empty(),
  )
}

///|
/// 托盘和 portal 助手本来就跟主服务同时存在，不能报。
///
/// 助手手里那条流正是我们要的；把助手算成「第二个实例」会把每次正常启动
/// 都变成一条假警告。
test "同机实例：托盘和 portal 助手不算" {
  assert_true(
    screen_capture_conflicts(me_kde(), [
      {
        pid: 200,
        exe: "screen-kacha-tray",
        wayland_display: "wayland-0",
        display: ":0",
      },
      {
        pid: 201,
        exe: "screen-kacha-portal",
        wayland_display: "wayland-0",
        display: ":0",
      },
      { pid: 202, exe: "sh", wayland_display: "wayland-0", display: ":0", },
      { pid: 203, exe: "moon", wayland_display: "wayland-0", display: ":0", },
    ]).is_empty(),
  )
}

///|
/// 自己不算。这条检查是给别人看的，不能自己报自己。
test "同机实例：自己不算" {
  assert_true(screen_capture_conflicts(me_kde(), [me_kde()]).is_empty())
}

///|
/// unit 里设了 WAYLAND_DISPLAY 没有 DISPLAY，终端里两个都有 —— 这种
/// 「一边缺变量」必须算同一个显示。
///
/// 不这么判的话，最该抓的那种情况正好漏掉：手滑多起一份基本都是从终端起的。
test "同机实例：一边缺 DISPLAY 也要报" {
  let service : ProcInfo = {
    pid: 200,
    exe: "screen-kacha",
    wayland_display: "wayland-0",
    display: "",
  }
  let out = screen_capture_conflicts(me_kde(), [service])
  assert_eq(joined_names(out.map(fn(p) { p.to_string() })), "200")
}

///|
/// 两边都问不出显示（裸环境、ssh 里起的临时实例）：没法区分就按同一块屏算。
///
/// 警告而已，宁可多报一次，也别把「两个进程抢同一块屏」漏成静默卡死。
test "同机实例：两边都没设显示时按同一块屏算" {
  let me : ProcInfo = {
    pid: 100,
    exe: "main.exe",
    wayland_display: "",
    display: "",
  }
  let cand : ProcInfo = {
    pid: 200,
    exe: "main.exe",
    wayland_display: "",
    display: "",
  }
  let out = screen_capture_conflicts(me, [cand])
  assert_eq(joined_names(out.map(fn(p) { p.to_string() })), "200")
}

///|
/// 开发时跑的是 `main.exe`，装好的是 `screen-kacha`，两个都算抓帧程序。
test "同机实例：main.exe 和 screen-kacha 都认" {
  let me : ProcInfo = {
    pid: 100,
    exe: "main.exe",
    wayland_display: "wayland-0",
    display: "",
  }
  let out = screen_capture_conflicts(me, [
    {
      pid: 200,
      exe: "screen-kacha",
      wayland_display: "wayland-0",
      display: ":0",
    },
    { pid: 201, exe: "main.exe", wayland_display: "wayland-0", display: ":0", },
  ])
  assert_eq(joined_names(out.map(fn(p) { p.to_string() })), "200,201")
}

///|
/// `/proc/<pid>/cmdline` 里是完整路径，要比的是最后一段。
test "同机实例：可执行名取最后一段" {
  assert_eq(basename("/home/clyzhi/.local/bin/screen-kacha"), "screen-kacha")
  assert_eq(basename("main.exe"), "main.exe")
  assert_eq(
    basename("./_build/native/debug/build/cmd/main/main.exe"),
    "main.exe",
  )
  assert_true(is_capture_exe("screen-kacha"))
  assert_true(is_capture_exe("main.exe"))
  // 名字前缀相同但不是一个程序的东西不能算进来
  assert_false(is_capture_exe("screen-kacha-tray"))
  assert_false(is_capture_exe("screen-kacha-portal"))
}

///|
/// cmdline / environ 都是 NUL 分隔的，空项要丢掉（cmdline 末尾有一个 NUL，
/// environ 里也可能有连续 NUL）。
test "同机实例：按 NUL 切分" {
  assert_eq(
    joined_names(split_nul(b"screen-kacha\x00--port\x008930\x00")),
    "screen-kacha,--port,8930",
  )
  assert_eq(
    joined_names(split_nul(b"WAYLAND_DISPLAY=wayland-0\x00DISPLAY=:0\x00")),
    "WAYLAND_DISPLAY=wayland-0,DISPLAY=:0",
  )
  // 空的输入不能切出一个空串
  assert_true(split_nul(b"").is_empty())
}
