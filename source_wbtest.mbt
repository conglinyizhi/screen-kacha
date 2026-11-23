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
  // 流自己是 streaming 的：这条只测帧龄那一条规则，别让状态规则掺进来
  assert_true(
    judge_frame_flow(Pipewire, 6000L, PUSH_STALE_MS, STREAM_STATE_STREAMING, 0L)
    is Stalled,
  )
  assert_true(
    judge_frame_flow(
      Pipewire,
      60000L,
      PUSH_STALE_MS,
      STREAM_STATE_STREAMING,
      0L,
    )
    is Stalled,
  )
  // 阈值正上方也要判死，别写成「大于等于两倍」之类
  assert_true(
    judge_frame_flow(
      Pipewire,
      PUSH_STALE_MS + 1L,
      PUSH_STALE_MS,
      STREAM_STATE_STREAMING,
      0L,
    )
    is Stalled,
  )
}

///|
/// 没超阈值就不许动。看门狗每轮都跑，一抖动就重连会自己把自己搞坏。
test "看门狗判定：推模式帧龄未超阈值不判死" {
  assert_true(
    judge_frame_flow(Pipewire, 0L, PUSH_STALE_MS, STREAM_STATE_STREAMING, 0L)
    is Flowing,
  )
  assert_true(
    judge_frame_flow(Pipewire, 1000L, PUSH_STALE_MS, STREAM_STATE_STREAMING, 0L)
    is Flowing,
  )
  // 边界：刚好等于阈值不算死，差 1 毫秒也不算
  assert_true(
    judge_frame_flow(
      Pipewire,
      PUSH_STALE_MS,
      PUSH_STALE_MS,
      STREAM_STATE_STREAMING,
      0L,
    )
    is Flowing,
  )
  assert_true(
    judge_frame_flow(
      Pipewire,
      PUSH_STALE_MS - 1L,
      PUSH_STALE_MS,
      STREAM_STATE_STREAMING,
      0L,
    )
    is Flowing,
  )
}

///|
/// 拉模式永远不判死。
///
/// 拉模式没有「流」这回事，帧旧是因为没人去要。这里要是判死，泵会在
/// spectacle 下反复「恢复」，把本来正常的画面打断。
///
/// 顺便把「状态不是 streaming、宽限期也早过了」一起喂进去：拉模式下
/// 这些输入根本不该被看到，判死只能来自推模式。
test "看门狗判定：拉模式永不判死" {
  assert_true(
    judge_frame_flow(Spectacle, 10000000L, PUSH_STALE_MS, 0, 100000L) is Flowing,
  )
  assert_true(
    judge_frame_flow(Fake, 10000000L, PUSH_STALE_MS, -1, 100000L) is Flowing,
  )
}

///|
/// 帧龄是负数表示一帧都还没抓过：那是「还没开始」，不是「死了」。
///
/// 服务刚起来、流刚连上还没协商出画面的时候就处在这个状态，
/// 这时候去重连只会把正要好的流打断。
test "看门狗判定：还没抓过帧（负数）不判死" {
  assert_true(
    judge_frame_flow(Pipewire, -1L, PUSH_STALE_MS, STREAM_STATE_STREAMING, 0L)
    is Flowing,
  )
  assert_true(
    judge_frame_flow(
      Pipewire,
      -1000000L,
      PUSH_STALE_MS,
      STREAM_STATE_STREAMING,
      0L,
    )
    is Flowing,
  )
}

///|
/// 流状态不是 streaming，而且已经过了宽限期：判死。
///
/// 这是这次新增的那条。帧龄要等满阈值，状态一掉下来就说明这条流没有在送画面
/// —— 两条信号互相独立，不必都等到同一个 5 秒。
///
/// 它管不了「接错源」：autoconnect 换源之后流照样是 streaming。实测给一个
/// 不存在的 node（999999），状态也是 3，帧还在来 —— 那种情况只能靠 `/health`
/// 里 `stream_state` 和 `target_node` 对着看。
test "看门狗判定：流状态不是 streaming 且过了宽限期判死" {
  // 帧龄很小（刚出过帧），但流自己说它已经不在 streaming
  assert_true(
    judge_frame_flow(Pipewire, 200L, PUSH_STALE_MS, 0, STREAM_GRACE_MS + 1L)
    is Stalled,
  )
  // 暂停、错误这两个真实枚举值都算
  assert_true(
    judge_frame_flow(Pipewire, 0L, PUSH_STALE_MS, 2, STREAM_GRACE_MS + 1L)
    is Stalled,
  )
  assert_true(
    judge_frame_flow(Pipewire, 0L, PUSH_STALE_MS, -1, STREAM_GRACE_MS + 1L)
    is Stalled,
  )
}

///|
/// 非 streaming 但还在宽限期内：不动。
///
/// 连上、协商、改分辨率这些瞬间状态会短暂跳出 streaming。这里判死的话，
/// 每次协商都会被当成死流，重连一次还不够，下一轮就直接退回慢路径。
test "看门狗判定：流状态不是 streaming 但在宽限期内不判死" {
  assert_true(judge_frame_flow(Pipewire, 0L, PUSH_STALE_MS, 0, 0L) is Flowing)
  assert_true(
    judge_frame_flow(Pipewire, 500L, PUSH_STALE_MS, 1, 1000L) is Flowing,
  )
  // 边界：刚好等于宽限期不算死，多条 1 毫秒才死
  assert_true(
    judge_frame_flow(Pipewire, 500L, PUSH_STALE_MS, 2, STREAM_GRACE_MS)
    is Flowing,
  )
}

///|
/// streaming 时只看帧龄：流在正常送帧，状态那一侧不该再插一脚。
test "看门狗判定：streaming 时只看帧龄" {
  // 已经被看见 streaming 很久了，也无所谓 —— 规则看的是状态本身
  assert_true(
    judge_frame_flow(
      Pipewire,
      100L,
      PUSH_STALE_MS,
      STREAM_STATE_STREAMING,
      999999L,
    )
    is Flowing,
  )
  // 帧龄超了照样判死
  assert_true(
    judge_frame_flow(
      Pipewire,
      6000L,
      PUSH_STALE_MS,
      STREAM_STATE_STREAMING,
      999999L,
    )
    is Stalled,
  )
}

///|
/// 帧龄还是负数时，状态再糟也不判死。
///
/// 这条是现有行为（「一帧都没抓过 = 还没开始」）的直接后果，写下来是为了
/// 让人看见这个缺口：流要是一帧都送不出来，看门狗不会动它。要堵这个缺口
/// 得先定「等多久算连不上」，不是这次改动的范围。
test "看门狗判定：帧龄为负时状态规则不参与" {
  assert_true(
    judge_frame_flow(Pipewire, -1L, PUSH_STALE_MS, -1, 100000L) is Flowing,
  )
}

///|
/// streaming 就是枚举里的 3，别的值都不是。
///
/// 取值来自 `<pipewire/stream.h>`（构建机 pipewire 1.6.11：
/// -1 错误、0 未连接、1 连接中、2 暂停、3 streaming）。4 在这个枚举里
/// 没有定义，别照别处的记忆改回去。
test "流状态：只有 3 算 streaming" {
  assert_true(is_streaming(3))
  assert_false(is_streaming(4))
  assert_false(is_streaming(-1))
  assert_false(is_streaming(0))
  assert_false(is_streaming(1))
  assert_false(is_streaming(2))
}

///|
/// 判死原因要分得清「停帧」和「状态不对」。
///
/// 把状态不对也写成「没有新帧」会把排障的人引到帧龄上去，而那里是正常的。
test "判死原因：停帧和状态不对分开写" {
  let stalled = stall_reason(60000L, PUSH_STALE_MS, STREAM_STATE_STREAMING, 0L)
  assert_true(stalled.contains("没有新帧"))
  let bad_state = stall_reason(200L, PUSH_STALE_MS, 0, STREAM_GRACE_MS + 1L)
  assert_true(bad_state.contains("不是 streaming"))
  assert_false(bad_state.contains("没有新帧"))
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
    judge_frame_flow(
      Pipewire,
      clock.observe(7L, 9000L),
      PUSH_STALE_MS,
      STREAM_STATE_STREAMING,
      0L,
    )
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
    judge_frame_flow(
      Pipewire,
      clock.observe(7L, 61000L),
      PUSH_STALE_MS,
      STREAM_STATE_STREAMING,
      0L,
    )
    is Flowing,
  )
}

///|
/// 流状态的时间窗：在 streaming 就一直归零，不在就照着墙钟涨。
///
/// 宽限期要的是「离开 streaming 多久了」，而 shim 只给这一轮的瞬时状态。
test "流状态时钟：离开 streaming 之后时间一直涨" {
  let clock = StreamStateClock::new(1000L)
  // 一上来还没 streaming：从创建那一刻算
  assert_eq(clock.observe(false, 3000L), 2000L)
  // 看见 streaming：归零，基准推到这一刻
  assert_eq(clock.observe(true, 4000L), 0L)
  // 又不在 streaming 了：从最后一次看见 streaming 算
  assert_eq(clock.observe(false, 6000L), 2000L)
  assert_eq(clock.observe(false, 9000L), 5000L)
}

///|
/// 重连之后要重开窗口：新流还要协商，不能拿旧流离开 streaming 的时间继续算。
test "流状态时钟：reset 之后从新时刻算" {
  let clock = StreamStateClock::new(1000L)
  assert_eq(clock.observe(false, 60000L), 59000L)
  clock.reset(60000L)
  assert_eq(clock.observe(false, 61000L), 1000L)
  // 重开之后还在宽限期内，判定不该动
  assert_true(
    judge_frame_flow(
      Pipewire,
      100L,
      PUSH_STALE_MS,
      1,
      clock.observe(false, 61000L),
    )
    is Flowing,
  )
}

///|
/// 时间窗和判定连起来：流刚跳出 streaming 的那几秒不判死，过了宽限期才判死。
test "流状态时钟：宽限期前后判定跟着变" {
  let clock = StreamStateClock::new(1000L)
  // 跳过连接瞬间
  assert_true(
    judge_frame_flow(
      Pipewire,
      0L,
      PUSH_STALE_MS,
      0,
      clock.observe(false, 2000L),
    )
    is Flowing,
  )
  // 宽限期还没过
  assert_true(
    judge_frame_flow(
      Pipewire,
      0L,
      PUSH_STALE_MS,
      0,
      clock.observe(false, 3000L),
    )
    is Flowing,
  )
  // 过了一毫秒就判死
  assert_true(
    judge_frame_flow(
      Pipewire,
      0L,
      PUSH_STALE_MS,
      0,
      clock.observe(false, 1000L + STREAM_GRACE_MS + 1L),
    )
    is Stalled,
  )
}
