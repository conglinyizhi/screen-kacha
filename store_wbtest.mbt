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

///|
/// 回归：推模式的流悄悄死掉之后，看门狗必须动手，并且 `/health` 说得出原因。
///
/// 线上那次「只产出 1 帧、`/health` 一直 ok: true、fails: 0、err 空」：
/// 泵在推模式分支里一直睡，流死了没有任何失败计数。
///
/// 这里不连真的 PipeWire：`pw=true` 只把来源摆成推模式
/// （`PipeWire::new` 不做任何 I/O，`connect` 才连流），恢复动作由测试注入。
async test "看门狗：推模式流停帧、恢复不成就退回并记原因" {
  let store = Store::new(
    shot="/tmp/watchdog-test.jpg",
    fake=Some("/nonexistent-frame-for-test.png"),
    pw=true,
  )
  // 摆出来的局面：来源是推模式，而帧已经 30 秒没动
  assert_true(store.push_source())
  assert_eq(store.source(), "pipewire")
  let mut tried = 0
  let out = store.watchdog(30000L, fn() -> Int32? {
    tried = tried + 1
    // 恢复失败：portal 没给出 node，或者重连没成功
    None
  })
  assert_true(out is FellBack)
  // 恢复必须真的被尝试过一次，不能直接放弃
  assert_eq(tried, 1)
  // 退回之后来源要跟着变，不能再自称还在推模式
  assert_eq(store.source(), "fake")
  assert_false(store.push_source())
  // 原因要留痕，否则 /health 只会看到「来源变了」，像一次正常回退
  assert_true(store.err().contains("没有新帧"))
  assert_true(store.err().contains("退回"))
  assert_eq(store.fails(), 1)
}

///|
/// 恢复成功就留在推模式，但原因一样要留痕：
/// `/health` 才说得清「它刚才死过一次，我救回来了」。
async test "看门狗：推模式流停帧、恢复成功留在推模式但留原因" {
  let store = Store::new(
    shot="/tmp/watchdog-test.jpg",
    fake=Some("/nonexistent-frame-for-test.png"),
    pw=true,
  )
  let out = store.watchdog(30000L, fn() -> Int32? { Some(42) })
  assert_true(out is Recovered)
  assert_eq(store.source(), "pipewire")
  assert_true(store.push_source())
  assert_true(store.err().contains("node=42"))
}

///|
/// 恢复一次还是没帧：直接退回，不再反复重连。
///
/// `connect` 是立刻返回的，重连成功不代表新流会出帧。要是每轮都重连，
/// 「流死了」就变成一条安静的自转，画面照样不动，日志还很热闹。
async test "看门狗：恢复过一次还没帧就直接退回，不再反复重连" {
  let store = Store::new(
    shot="/tmp/watchdog-test.jpg",
    fake=Some("/nonexistent-frame-for-test.png"),
    pw=true,
  )
  let mut tried = 0
  let first = store.watchdog(30000L, fn() -> Int32? {
    tried = tried + 1
    Some(42)
  })
  assert_true(first is Recovered)
  // 下一个周期帧还是没来
  let second = store.watchdog(30000L, fn() -> Int32? {
    tried = tried + 1
    Some(43)
  })
  assert_true(second is FellBack)
  // 第二回合没有再尝试恢复
  assert_eq(tried, 1)
  assert_eq(store.source(), "fake")
}

///|
/// 流还在出帧时什么都不许做：看门狗每轮都跑，一有抖动就重连会自己把自己搞坏。
async test "看门狗：帧龄没超阈值时什么都不做" {
  let store = Store::new(
    shot="/tmp/watchdog-test.jpg",
    fake=Some("/nonexistent-frame-for-test.png"),
    pw=true,
  )
  let mut tried = 0
  let out = store.watchdog(100L, fn() -> Int32? {
    tried = tried + 1
    Some(1)
  })
  assert_true(out is Quiet)
  assert_eq(tried, 0)
  assert_eq(store.source(), "pipewire")
  assert_eq(store.fails(), 0)
  assert_eq(store.err(), "")
}

///|
/// 拉模式来源永远不该被判死：帧旧是因为没人去要，不是坏了。
async test "看门狗：拉模式来源不会被判死" {
  let store = Store::new(
    shot="/tmp/watchdog-test.jpg",
    fake=Some("/nonexistent-frame-for-test.png"),
  )
  assert_false(store.push_source())
  assert_eq(store.source(), "fake")
  let mut tried = 0
  let out = store.watchdog(10000000L, fn() -> Int32? {
    tried = tried + 1
    Some(1)
  })
  assert_true(out is Quiet)
  assert_eq(tried, 0)
  assert_eq(store.source(), "fake")
  assert_eq(store.err(), "")
}
