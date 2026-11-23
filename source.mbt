///|
/// 取帧来源。
///
/// 原来「帧从哪来」这件事散在三个标志里：`pw_state.on` 表示常驻流还活着、
/// `fake` 表示测试用的固定图片、两者都不是就当 spectacle，`capture()` 里
/// 靠一层层 if 落到某个分支。多一种来源就得在中间再插一段，
/// 看门狗也只能对着 `pipewire_on()` 写特例。
///
/// 收成一个值之后，「谁在产出帧」只有一个答案：推/拉由 `is_push()` 回答，
/// `/health` 的 `source` 直接读 `label()`，取值和以前完全一样。
pub enum FrameSource {
  /// PipeWire 常驻流：帧自己送来，没人去要也会有（推模式）
  Pipewire
  /// spectacle：没人去要就不出帧，泵得按节奏主动拉（拉模式）
  Spectacle
  /// 测试用固定图片：泵去读那个文件（拉模式）
  Fake
}

///|
/// 给 `/health` 的 `source` 字段用。
///
/// 取值必须保持 `pipewire` / `spectacle` / `fake`：外部脚本和托盘都按它判断
/// 当前走的是快路径还是慢路径。
pub fn FrameSource::label(self : FrameSource) -> String {
  match self {
    Pipewire => "pipewire"
    Spectacle => "spectacle"
    Fake => "fake"
  }
}

///|
/// 推模式还是拉模式。
///
/// 泵只问这一句：推模式下它不去要帧（帧自己会来），但要盯着流有没有停；
/// 拉模式下它得按节奏主动去要。
pub fn FrameSource::is_push(self : FrameSource) -> Bool {
  match self {
    Pipewire => true
    Spectacle => false
    Fake => false
  }
}

///|
/// 推模式的流多久没有新帧就认定它死了。
///
/// 5 秒：正常的推流一秒内必到帧，留出余量是为了容忍协商、改分辨率、
/// 锁屏解除这些短暂停顿；又不能给太长，否则「流死了」会一直藏在
/// 一个看起来正常的 `/health` 后面。
pub const PUSH_STALE_MS : Int64 = 5000

///|
/// `PW_STREAM_STATE_STREAMING`：流已经连上并且正在送帧。
///
/// 取值抄自 PipeWire 头文件 `<pipewire/stream.h>` 的 `enum pw_stream_state`
/// （构建机上 pipewire 1.6.11）：-1 错误、0 未连接、1 连接中、2 暂停、
/// 3 streaming。这个枚举没有 4，别照别处的记忆写。
pub const STREAM_STATE_STREAMING : Int32 = 3

///|
/// 流说它不在 streaming 之后，先观察这么久再判死。
///
/// 连上、协商、改分辨率这些瞬间，状态会短暂跳出 streaming。一看到不是
/// streaming 就重连，等于自己把正要好的流打断，还会白白耗掉一次恢复机会。
pub const STREAM_GRACE_MS : Int64 = 3000

///|
/// 这个流状态算不算「在送帧」。
pub fn is_streaming(state : Int32) -> Bool {
  state == STREAM_STATE_STREAMING
}

///|
/// 流还在不在出帧。
pub enum FrameFlow {
  Flowing
  Stalled
}

///|
/// 看门狗一轮的判定：这条来源现在是不是停在那里不出帧了。
///
/// 只吃标量，不碰时钟也不碰设备 —— 判定是线上「只出 1 帧」这类事故里
/// 第一个要复核的东西，得能单独单测。
///
/// - `stream_state`：PipeWire 报的 `enum pw_stream_state` 整数值
/// - `since_streaming_ms`：距上一次确认它在 streaming 过了多久，见 `StreamStateClock`
///
/// 四条规则写成显式分支而不串成一串 &&：读得出来比写得短重要。
pub fn judge_frame_flow(
  src : FrameSource,
  frame_age_ms : Int64,
  stale_ms : Int64,
  stream_state : Int32,
  since_streaming_ms : Int64,
) -> FrameFlow {
  // 拉模式没有「流」这回事：帧旧是因为没人去要，不是坏了。
  // 这里要是判死，泵会在 spectacle 下反复「恢复」，把正常的画面打断。
  if !src.is_push() {
    return Flowing
  }
  // 负数表示一帧都还没抓过：那是「还没开始」，不是「死了」。
  if frame_age_ms < 0L {
    return Flowing
  }
  // 流不再送新帧，帧龄一直涨。
  if frame_age_ms > stale_ms {
    return Stalled
  }
  // 流自己说它不在 streaming，而且已经持续过宽限期。
  //
  // 这是帧龄之外的第二条独立信号：帧龄要等满阈值才判得出来，而状态一掉下来
  // （node 被销毁、会话被回收、流被挂起）就说明它没有在送画面了。
  //
  // 它补不上「接错了源」那一种：autoconnect 换源之后流照样是 streaming，
  // 帧也照样来。那种情况只能靠 `/health` 里 `stream_state` 和 `target_node`
  // 对着看，判定这一层管不了。
  if !is_streaming(stream_state) && since_streaming_ms > STREAM_GRACE_MS {
    return Stalled
  }
  Flowing
}

///|
/// 判死的原因，给 `/health` 的 `err` 和日志用。
///
/// 为什么单独一个函数：新增的「流状态不是 streaming」也能判死，这时帧龄可能
/// 只有几百毫秒。把它也写成「XXXms 没有新帧」就是在骗人 —— 排障的人会去翻
/// 帧龄，然后怀疑判定逻辑。
pub fn stall_reason(
  frame_age_ms : Int64,
  stale_ms : Int64,
  stream_state : Int32,
  since_streaming_ms : Int64,
) -> String {
  if frame_age_ms > stale_ms {
    "流 \{frame_age_ms}ms 没有新帧（阈值 \{stale_ms}ms）"
  } else {
    "流状态 \{stream_state} 不是 streaming 已经 \{since_streaming_ms}ms（宽限 \{STREAM_GRACE_MS}ms）"
  }
}

///|
/// 流状态的时间窗：把「这一轮流是不是在 streaming」变成「离开 streaming 多久了」。
///
/// 判定要的是持续时间（宽限期），而 shim 只给瞬时状态。记时刻这件事挪到这里，
/// `judge_frame_flow` 才能保持纯函数。
pub struct StreamStateClock {
  /// 上一次确认流在 streaming 的时刻
  mut since_ms : Int64
}

///|
/// 起步按「这一刻刚确认过 streaming」算：刚连上还在协商，
/// 本来就不会立刻 streaming，先给满一个宽限窗口。
pub fn StreamStateClock::new(now_ms : Int64) -> StreamStateClock {
  { since_ms: now_ms, }
}

///|
/// 每轮喂一次当前状态，返回距上一次确认 streaming 过了多少毫秒。
///
/// 在 streaming 就返回 0 并把基准推到这一刻；不在就从「最后一次看见
/// streaming」算起 —— 于是宽限期既覆盖刚连上还没 streaming 的那几秒，
/// 也覆盖流中途跳出 streaming 的那几秒。
pub fn StreamStateClock::observe(
  self : StreamStateClock,
  streaming : Bool,
  now_ms : Int64,
) -> Int64 {
  if streaming {
    self.since_ms = now_ms
    return 0L
  }
  now_ms - self.since_ms
}

///|
/// 重连成功之后重开窗口：新流还要协商，不能拿旧流离开 streaming 的时间继续算。
pub fn StreamStateClock::reset(self : StreamStateClock, now_ms : Int64) -> Unit {
  self.since_ms = now_ms
}

///|
/// 推模式下「帧有多旧」的算法：看流真正送来的帧序号。
///
/// 不能直接拿 JPEG 缓存的帧龄来判：
/// 流死掉之后 shim 会把上一帧再写一遍，`capture` 照样返回成功、
/// 帧龄被刷新，`/health` 于是继续说 ok、fails 还是 0、err 还是空的 ——
/// 线上那次「只产出 1 帧却一直说 ok」就是这么被骗过去的。
/// 流真死了，序号就不再变，这里的帧龄才会一直涨。
pub struct StreamClock {
  /// 上一次看到的帧序号
  mut seq : Int64
  /// 上一次序号变化（也就是真的来了新帧）的时刻（毫秒）
  mut since_ms : Int64
}

///|
/// 起步：把当前序号当成「这一刻刚有过帧」，先给满一个阈值窗口，
/// 免得刚连上、还在协商的时候就判死。
pub fn StreamClock::new(seq : Int64, now_ms : Int64) -> StreamClock {
  { seq, since_ms: now_ms, }
}

///|
/// 看一眼当前序号，返回距上一帧真正到达过了多少毫秒。
///
/// 序号变了就是有新帧：帧龄归零，窗口从这一刻重新算。
pub fn StreamClock::observe(
  self : StreamClock,
  seq : Int64,
  now_ms : Int64,
) -> Int64 {
  if seq != self.seq {
    self.seq = seq
    self.since_ms = now_ms
    return 0L
  }
  now_ms - self.since_ms
}

///|
/// 重连成功之后把窗口重开：新流还要协商，不能拿旧流停帧的时间继续算。
pub fn StreamClock::reset(self : StreamClock, now_ms : Int64) -> Unit {
  self.since_ms = now_ms
}
