///|
/// 脚本名必须带 pid。
///
/// 原来是写死的 `cursorprobe`：两个托盘实例（手滑起第二份、新旧两个 unit
/// 同时装着）会抢同一个名字 —— 后加载的顶掉前一个，先退出的那个按名字
/// 一卸载，另一个的脚本也跟着没了。
test "KWin 脚本名带 pid" {
  assert_eq(cursor_script_name(4242), "screen-kacha-cursor-4242")
  // 两个实例拿到的是两个名字，谁也顶不掉谁
  assert_true(cursor_script_name(1) != cursor_script_name(2))
  // 前缀固定：一看就知道这是我们的脚本
  assert_true(cursor_script_name(4242).has_prefix("screen-kacha-cursor-"))
}

///|
/// 本进程用的名字和 pid 对得上（`own_script_name` 走的是真实 getpid）。
test "KWin 脚本名跟本进程 pid 一致" {
  let name = own_script_name()
  assert_eq(name, "screen-kacha-cursor-\{current_pid()}")
  // 名字里不能再出现大写、空格、引号这类会把 gdbus 参数拼坏的东西
  assert_false(name.contains(" "))
  assert_false(name.contains("'"))
}
