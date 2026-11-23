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
/// 三条规则写成显式分支而不串成一串 &&：读得出来比写得短重要。
pub fn judge_frame_flow(
  src : FrameSource,
  frame_age_ms : Int64,
  stale_ms : Int64,
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
  if frame_age_ms > stale_ms {
    Stalled
  } else {
    Flowing
  }
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
