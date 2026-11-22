///|
/// 备选端口从下一个开始，不越过 65535。
///
/// 端口被占时直接往上扫，不等待：占着端口的是别人，等多久它也不会让开。
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
