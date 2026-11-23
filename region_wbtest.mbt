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
  assert_true(parse_region("0.1,0.1,0.1,00000000000000000000000000000000000000000000000000000000000000000000000000000000") is None)
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
