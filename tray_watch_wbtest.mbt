///|
/// 把判定摊平成 (标签, 下一次 miss, 间隔)，方便直接 assert_eq。
///
/// 直接断言枚举要给它实现 Eq/Show，摊平成整数元组读起来也更清楚：
/// (0, m, iv) = 继续盯着，miss 变成 m、隔 iv 毫秒再看；(1, _, _) = 判死；
/// (2, _, _) = 时钟不统一。
fn flat(d : ProbeDecision) -> (Int32, Int32, Int32) {
  match d {
    Keep(m, iv) => (0, m, iv)
    Dead => (1, 0, 0)
    Skew => (2, 0, 0)
  }
}

///|
/// 心跳还新鲜时按基准间隔看，计数一直是 0。
test "托盘监督：新鲜心跳按基准间隔、计数归零" {
  let base = TRAY_PROBE_BASE_MS
  assert_eq(flat(decide_probe(0, false, 0L, base)), (0, 0, base))
  // 差一点点到基准
  assert_eq(
    flat(decide_probe(0, false, base.to_int64() - 1L, base)),
    (0, 0, base),
  )
  // 之前攒了两次失败，收到一次新鲜心跳就归零
  assert_eq(flat(decide_probe(2, false, 100L, base)), (0, 0, base))
}

///|
/// 心跳过期之后的升级路径：0→1→2→3，然后判死。
///
/// 间隔的含义是「带着这个计数要用多久再看一次」：计数 0 时是基准，
/// 一旦记到 1 就缩到 3/10（1.5 秒）去催，这样「只是抖动」能很快洗清，
/// 「真死了」也能在十秒上下确认掉。
test "托盘监督：miss 0→1→2→3 的间隔与判定" {
  let base = TRAY_PROBE_BASE_MS
  let stale = base.to_int64() // 刚好等于基准：算过期
  // 第一次过期：0→1，间隔缩到 1500
  assert_eq(flat(decide_probe(0, false, stale, base)), (0, 1, 1500))
  // 已经记到 1 的时候，间隔就是 1.5 秒这一档
  assert_eq(flat(decide_probe(1, false, stale, base)), (0, 2, 1500))
  assert_eq(flat(decide_probe(2, false, stale, base)), (0, 3, 1500))
  // 已经满 3 次：判死
  assert_eq(flat(decide_probe(3, false, stale, base)), (1, 0, 0))
  // 再多也一样，不会回到「继续等」
  assert_eq(flat(decide_probe(9, false, 60000L, base)), (1, 0, 0))
}

///|
/// 高压力：不升级、不判死，间隔放宽到 base*2。
///
/// 机器正忙的时候，「心跳过期」很可能只是我们自己的调度延迟 ——
/// 这时候判死就是给一台已经很忙的机器再添一次 D-Bus 清场。
test "托盘监督：高压力下不判死，间隔放宽" {
  let base = TRAY_PROBE_BASE_MS
  // 就算已经攒到 3 次，高压下也不判死
  assert_eq(flat(decide_probe(3, true, 60000L, base)), (0, 3, base * 2))
  // 攒到 2 次，保持不动
  assert_eq(flat(decide_probe(2, true, 60000L, base)), (0, 2, base * 2))
  // 一次都没攒到：也不加
  assert_eq(flat(decide_probe(0, true, 60000L, base)), (0, 0, base * 2))
  // 高压期间收到新鲜心跳照样归零（只是看得慢一点）
  assert_eq(flat(decide_probe(2, true, 0L, base)), (0, 0, base * 2))
}

///|
/// 压力回到正常之后马上收紧：攒着的失败次数照旧生效。
///
/// 注意顺序：先判「过期」，再看压力。压力一撤，下一次过期就立刻往上升，
/// 这正是「压力过去之后把欠下的判定补上」。
test "托盘监督：压力回正常后开始收紧" {
  let base = TRAY_PROBE_BASE_MS
  let stale = base.to_int64()
  // 高压期间停在 2
  assert_eq(flat(decide_probe(2, true, stale, base)), (0, 2, base * 2))
  // 压力一撤，同一份过期证据直接升到 3
  assert_eq(flat(decide_probe(2, false, stale, base)), (0, 3, 1500))
  // 再下一轮判死
  assert_eq(flat(decide_probe(3, false, stale, base)), (1, 0, 0))
}

///|
/// 时间戳在未来：两边时钟不统一，这一轮不算数。
///
/// 判死不成立（我们根本不知道过去了多久），也不许往上加 ——
/// 加了就会攒出一个假死判定，而托盘可能活得好好的。
test "托盘监督：时间戳在未来时记异常、不判死" {
  let base = TRAY_PROBE_BASE_MS
  // 已经到了判死的次数也不判死
  assert_eq(flat(decide_probe(3, false, -1L, base)), (2, 0, 0))
  assert_eq(flat(decide_probe(0, false, -60000L, base)), (2, 0, 0))
  // 高压也一样，时钟问题优先
  assert_eq(flat(decide_probe(2, true, -5000L, base)), (2, 0, 0))
}

///|
/// 停滞时长就是两个时间戳的差，负数表示托盘的时间在未来。
test "托盘监督：停滞时长计算" {
  assert_eq(stale_ms_of(1000L, 400L), 600L)
  assert_eq(stale_ms_of(1000L, 1000L), 0L)
  assert_eq(stale_ms_of(1000L, 1200L), -200L)
}

///|
/// PSI 里取的是 `some` 那一行的 avg10，`full` 行不算。
///
/// cpu 和 io 两个文件的格式一样；io 多一行 full，不挑 `some` 就会读到
/// full 的值（io 的 full 往往更高，会把正常机器判成高压力）。
test "托盘监督：解析 PSI 的 some avg10" {
  assert_eq(
    parse_psi_some_avg10(
      "some avg10=1.25 avg60=0.80 avg300=0.30 total=12345\n" +
      "full avg10=88.00 avg60=0.80 avg300=0.30 total=999\n",
    ),
    Some(125),
  )
  // 整数位、满值
  assert_eq(
    parse_psi_some_avg10("some avg10=100.00 avg60=0.00 avg300=0.00 total=1\n"),
    Some(10000),
  )
  assert_eq(
    parse_psi_some_avg10("some avg10=0.00 avg60=0.00 avg300=0.00 total=0\n"),
    Some(0),
  )
  // 只有 full 行（没有 some）：不取
  assert_eq(
    parse_psi_some_avg10("full avg10=99.00 avg60=0.00 avg300=0.00 total=0\n"),
    None,
  )
  // avg10 缺了
  assert_eq(parse_psi_some_avg10("some avg60=1.00 avg300=0.50 total=1\n"), None)
  // 空文件、垃圾
  assert_eq(parse_psi_some_avg10(""), None)
  assert_eq(parse_psi_some_avg10("some avg10=abc total=1\n"), None)
}

///|
/// loadavg 只取第一个数（load1）。
test "托盘监督：解析 loadavg 的 load1" {
  assert_eq(parse_load1("0.24 0.20 0.29 1/1471 252732\n"), Some(24))
  assert_eq(parse_load1("3.4 2.1 1.5 2/100 999\n"), Some(340))
  // 整数形式的 load1（机器特别忙时会出现）
  assert_eq(parse_load1("12 11 10 1/1 1\n"), Some(1200))
  assert_eq(parse_load1(""), None)
  assert_eq(parse_load1("garbage"), None)
}

///|
/// 高压判定：有 PSI 就以 PSI 为准，两个都读不到才退到 load1 / 核数。
test "托盘监督：高压判定" {
  // CPU 或 io 任一超阈值（60.00）就算高压；刚好等于不算
  assert_true(pressure_is_high(Some(6001), Some(0), None, 8))
  assert_false(pressure_is_high(Some(6000), Some(0), None, 8))
  assert_true(pressure_is_high(Some(0), Some(8000), None, 8))
  // 有 PSI 就不看 loadavg：load 再高也不改判
  assert_false(pressure_is_high(Some(100), Some(100), Some(9000), 8))
  // 两个 PSI 都没有：8 核 → 阈值 1200（1.5 × 8）
  assert_true(pressure_is_high(None, None, Some(1201), 8))
  assert_false(pressure_is_high(None, None, Some(1200), 8))
  // 只有一个 PSI 也算「有 PSI」，不退回 loadavg
  assert_false(pressure_is_high(Some(1), None, Some(9000), 8))
  // 全读不到：当正常，别因为读不了压力就把托盘晾着
  assert_false(pressure_is_high(None, None, None, 8))
}
