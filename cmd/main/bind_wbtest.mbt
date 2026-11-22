///|
/// 退避是递增的，而且用完就不再等。
///
/// 固定间隔（比如一律 3 秒）在「旧实例正在退」这种场景下要么太慢、要么不够；
/// 递增能在前面几次快速接上，后面给慢退出的进程留时间。
test "退避队列递增且有上限" {
  assert_eq(bind_backoff_ms(0), 250)
  assert_eq(bind_backoff_ms(1), 500)
  assert_eq(bind_backoff_ms(2), 1000)
  assert_eq(bind_backoff_ms(3), 2000)
  // 越界不再等
  assert_eq(bind_backoff_ms(4), 0)
  assert_eq(bind_backoff_ms(-1), 0)
  // 单调不减
  let mut i = 1
  while bind_backoff_ms(i) > 0 {
    assert_true(bind_backoff_ms(i) >= bind_backoff_ms(i - 1))
    i = i + 1
  }
  // 重试次数与队列长度一致：4 次退避之后就不再等
  assert_eq(bind_backoff_ms(BIND_RETRIES), 0)
}

///|
/// 备选端口从下一个开始，不越过 65535。
test "备选端口从下一个开始" {
  let ports = fallback_ports(8930, 8)
  assert_eq(ports.length(), 8)
  assert_eq(ports[0], 8931)
  assert_eq(ports[7], 8938)
  // 端口号有上限
  let edge = fallback_ports(65534, 8)
  assert_eq(edge.length(), 1)
  assert_eq(edge[0], 65535)
  // 已经到头了就没有备选
  assert_eq(fallback_ports(65535, 8).length(), 0)
}
