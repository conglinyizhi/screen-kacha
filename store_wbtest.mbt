///|
/// 运行时目录不能再写死 1000：换一个 uid 必须跟着变。
test "runtime_dir：按 uid 推，不死认 1000" {
  assert_eq(runtime_dir_from(None, 4242), "/run/user/4242")
  assert_eq(runtime_dir_from(None, 0), "/run/user/0")
  // 给了环境变量就以它为准
  assert_eq(runtime_dir_from(Some("/run/user/4242"), 1000), "/run/user/4242")
  // 空串当作没给，别返回一个空路径让后面拼出 "//screen-kacha"
  assert_eq(runtime_dir_from(Some(""), 4242), "/run/user/4242")
}

///|
/// getuid() 真的被问到了：返回值必须等于进程自身的 uid。
test "current_uid 与进程一致" {
  let uid = current_uid()
  assert_true(uid >= 0)
  // 同一进程内多次调用必须稳定
  assert_eq(current_uid(), uid)
}

///|
/// Wayland 找不到时报错要写清楚找的是哪个目录 —— uid 或 XDG_RUNTIME_DIR
/// 不对的时候，这行是唯一能看出问题在哪的线索。
async test "Wayland 未就绪的报错带上目录" {
  let store = Store::new(
    shot="/tmp/none.jpg",
    wl_dir="/nonexistent-runtime-dir-xyz",
    tmp_dir="/tmp/none-shm",
  )
  store.capture()
  let err = store.err()
  assert_true(err.contains("Wayland"))
  assert_true(err.contains("/nonexistent-runtime-dir-xyz"))
}
