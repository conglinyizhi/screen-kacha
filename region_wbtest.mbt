///|
test "parse_region：小数与百分比等价" {
  let a = parse_region("0.1,0.2,0.3,0.4").unwrap()
  let b = parse_region("10%,20%,30%,40%").unwrap()
  assert_true((a.x - b.x).abs() < 1.0e-12)
  assert_true((a.w - b.w).abs() < 1.0e-12)
  // 两种写法可以混着来
  let c = parse_region("10%,0.2,30%,0.4").unwrap()
  assert_true((c.y - 0.2).abs() < 1.0e-12)
}

///|
test "parse_region：整屏与空格" {
  let r = parse_region("0,0,1,1").unwrap()
  assert_eq(r.w, 1.0)
  assert_true(parse_region(" 0 , 0 , 1 , 1 ") is Some(_))
  assert_true(parse_region("0,0,100%,100%") is Some(_))
}

///|
test "parse_region：越界和畸形一律拒绝" {
  // 段数不对
  assert_true(parse_region("") is None)
  assert_true(parse_region("0.1,0.1,0.5") is None)
  assert_true(parse_region("0.1,0.1,0.5,0.5,0.1") is None)
  // 负数、零宽、超界
  assert_true(parse_region("-0.1,0,0.5,0.5") is None)
  assert_true(parse_region("0,0,0,0.5") is None)
  assert_true(parse_region("0,0,1.5,0.5") is None)
  assert_true(parse_region("0.8,0,0.5,1") is None)
  // 垃圾
  assert_true(parse_region("a,b,c,d") is None)
  assert_true(parse_region("0.1,0.1,0.1,0.1x") is None)
  assert_true(parse_region("%,%,%,%") is None)
  assert_true(parse_region("1e999,0,1,1") is None)
  assert_true(parse_region("nan,0,1,1") is None)
  assert_true(parse_region("inf,0,1,1") is None)
  // 超长串不该被逐字符解析
  assert_true(
    parse_region(
      "0.1,0.1,0.1,00000000000000000000000000000000000000000000000000000000000000000000000000000000",
    )
    is None,
  )
}

///|
test "parse_dst_w：只收 1..4096 的十进制" {
  assert_eq(parse_dst_w("1280"), Some(1280))
  assert_eq(parse_dst_w("1"), Some(1))
  assert_eq(parse_dst_w("4096"), Some(4096))
  assert_true(parse_dst_w("0") is None)
  assert_true(parse_dst_w("4097") is None)
  assert_true(parse_dst_w("12a") is None)
  assert_true(parse_dst_w("-12") is None)
  assert_true(parse_dst_w("") is None)
  assert_true(parse_dst_w("999999") is None)
}

///|
/// 畸形输入的清单。每一条都应该被拒 —— 这里「服务端报错」就是通过。
test "parse_region：畸形清单" {
  let bad : Array[String] = [
    "", // 空
     ",", // 只有一个逗号
     ",,,", // 四个空段
     "0,0,1,1,", // 多一个逗号
     "0,0,1", // 少一段
     "0,0,1,1,1", // 多一段
     "0..1,0,1,1", // 两个小数点
     "0x10,0,1,1", // 十六进制
     "1,0,1,1", // x 已经是 1，宽再 1 就越界
     "0,1,1,1", // y 越界
     "150%,0,10%,10%", // 百分比超 100
     "0.0,0.0,0.0,0.0", // 零宽零高
     "   ,0,1,1", // 空段带空格
  ]
  for v in bad {
    assert_true(parse_region(v) is None)
  }
}

///|
/// 边界值要放行：整帧、最小一块。
test "parse_region：边界放行" {
  assert_true(parse_region("0,0,1,1") is Some(_))
  assert_true(parse_region("0,0,0.0001,0.0001") is Some(_))
  assert_true(parse_region("0.9999,0.9999,0.0001,0.0001") is Some(_))
}
