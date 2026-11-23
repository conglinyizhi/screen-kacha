///|
/// 来源标签就是 `/health` 上 `source` 的值，三个取值不能变：
/// 外部脚本和托盘都靠它判断当前走的是快路径还是慢路径。
test "来源标签：/health 上的取值保持不变" {
  assert_eq(Pipewire.label(), "pipewire")
  assert_eq(Spectacle.label(), "spectacle")
  assert_eq(Fake.label(), "fake")
}

///|
/// 只有 PipeWire 是推模式：帧它自己送来。spectacle 和假帧源都得有人去要。
test "只有 PipeWire 是推模式" {
  assert_true(Pipewire.is_push())
  assert_false(Spectacle.is_push())
  assert_false(Fake.is_push())
}

///|
/// 推模式下帧龄超过阈值就该判死。
test "看门狗判定：推模式帧龄超阈值判死" {
  assert_true(judge_frame_flow(Pipewire, 6000L, PUSH_STALE_MS) is Stalled)
  assert_true(judge_frame_flow(Pipewire, 60000L, PUSH_STALE_MS) is Stalled)
  // 阈值正上方也要判死，别写成「大于等于两倍」之类
  assert_true(
    judge_frame_flow(Pipewire, PUSH_STALE_MS + 1L, PUSH_STALE_MS) is Stalled,
  )
}

///|
/// 没超阈值就不许动。看门狗每轮都跑，一抖动就重连会自己把自己搞坏。
test "看门狗判定：推模式帧龄未超阈值不判死" {
  assert_true(judge_frame_flow(Pipewire, 0L, PUSH_STALE_MS) is Flowing)
  assert_true(judge_frame_flow(Pipewire, 1000L, PUSH_STALE_MS) is Flowing)
  // 边界：刚好等于阈值不算死，差 1 毫秒也不算
  assert_true(
    judge_frame_flow(Pipewire, PUSH_STALE_MS, PUSH_STALE_MS) is Flowing,
  )
  assert_true(
    judge_frame_flow(Pipewire, PUSH_STALE_MS - 1L, PUSH_STALE_MS) is Flowing,
  )
}

///|
/// 拉模式永远不判死。
///
/// 拉模式没有「流」这回事，帧旧是因为没人去要。这里要是判死，泵会在
/// spectacle 下反复「恢复」，把本来正常的画面打断。
test "看门狗判定：拉模式永不判死" {
  assert_true(judge_frame_flow(Spectacle, 10000000L, PUSH_STALE_MS) is Flowing)
  assert_true(judge_frame_flow(Fake, 10000000L, PUSH_STALE_MS) is Flowing)
}

///|
/// 帧龄是负数表示一帧都还没抓过：那是「还没开始」，不是「死了」。
///
/// 服务刚起来、流刚连上还没协商出画面的时候就处在这个状态，
/// 这时候去重连只会把正要好的流打断。
test "看门狗判定：还没抓过帧（负数）不判死" {
  assert_true(judge_frame_flow(Pipewire, -1L, PUSH_STALE_MS) is Flowing)
  assert_true(judge_frame_flow(Pipewire, -1000000L, PUSH_STALE_MS) is Flowing)
}

///|
/// 流没送新帧：序号不变，帧龄照着墙钟一直涨。
///
/// 这条是「只出 1 帧还说 ok」的根子：JPEG 那一侧会被旧缓冲骗过去，
/// 流序号不会。
test "帧龄时钟：序号不变时帧龄一直涨" {
  let clock = StreamClock::new(7L, 1000L)
  assert_eq(clock.observe(7L, 2000L), 1000L)
  assert_eq(clock.observe(7L, 9000L), 8000L)
  // 涨过阈值之后判定要跟着变
  assert_true(
    judge_frame_flow(Pipewire, clock.observe(7L, 9000L), PUSH_STALE_MS)
    is Stalled,
  )
}

///|
/// 序号变了就是真的来了新帧：帧龄归零，窗口从这一刻重新算。
test "帧龄时钟：序号变化后帧龄归零" {
  let clock = StreamClock::new(7L, 1000L)
  assert_eq(clock.observe(8L, 6500L), 0L)
  assert_eq(clock.observe(8L, 7000L), 500L)
  // 从新帧那一刻算，不是从创建那一刻算
  assert_eq(clock.observe(8L, 12000L), 5500L)
}

///|
/// 重连成功之后要重新给满一个窗口：新流还要协商，不能拿旧流停帧的时间继续算，
/// 否则刚连上就立刻又被判死。
test "帧龄时钟：reset 之后从新时刻算" {
  let clock = StreamClock::new(7L, 1000L)
  assert_eq(clock.observe(7L, 60000L), 59000L)
  clock.reset(60000L)
  assert_eq(clock.observe(7L, 61000L), 1000L)
  assert_true(
    judge_frame_flow(Pipewire, clock.observe(7L, 61000L), PUSH_STALE_MS)
    is Flowing,
  )
}
