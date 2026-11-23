///|
/// 一条正常的记录，渲染出来是逐行 key=value，原样解析回来必须一致。
test "托盘心跳：序列化与解析能往返" {
  let o : TrayOwner = {
    pid: 4242,
    script: "screen-kacha-cursor-4242",
    helper: 4343,
    ts_ms: 1750000000000L,
    miss: 2,
  }
  let text = o.render()
  assert_eq(
    text, "pid=4242\nscript=screen-kacha-cursor-4242\nhelper=4343\nts_ms=1750000000000\nmiss=2\n",
  )
  let back = TrayOwner::parse(text)
  match back {
    None => fail("解析回来是空的")
    Some(p) => {
      assert_eq(p.pid, 4242)
      assert_eq(p.script, "screen-kacha-cursor-4242")
      assert_eq(p.helper, 4343)
      assert_eq(p.ts_ms, 1750000000000L)
      assert_eq(p.miss, 2)
    }
  }
}

///|
/// 没挂过光标跟踪的托盘：`script` 是空串、`helper` 是 0，这是合法记录。
///
/// 清场那边自然会跳过这两步（空名字不卸、0 号不杀），
/// 但「托盘死了」这件事照样要能判出来。
test "托盘心跳：脚本和 helper 都可以是空" {
  let o : TrayOwner = { pid: 7, script: "", helper: 0, ts_ms: 1000L, miss: 0, }
  let back = TrayOwner::parse(o.render())
  match back {
    None => fail("空 script / helper=0 的记录被当成坏了")
    Some(p) => {
      assert_eq(p.script, "")
      assert_eq(p.helper, 0)
    }
  }
}

///|
/// 关键字段缺失或读不出来 → 整条丢掉。
///
/// pid 读成 0 尤其危险：照着 pid=0 去 kill 是发给整个进程组。
test "托盘心跳：缺 pid 或时间戳就当没有记录" {
  assert_true(TrayOwner::parse("script=x\nts_ms=1000\n") is None)
  assert_true(TrayOwner::parse("pid=123\nscript=x\n") is None)
  // pid 是 0、负数、垃圾，一律不认
  assert_true(TrayOwner::parse("pid=0\nts_ms=1000\n") is None)
  assert_true(TrayOwner::parse("pid=-5\nts_ms=1000\n") is None)
  assert_true(TrayOwner::parse("pid=abc\nts_ms=1000\n") is None)
  // 时间戳同理
  assert_true(TrayOwner::parse("pid=1\nts_ms=0\n") is None)
  assert_true(TrayOwner::parse("pid=1\nts_ms=-1\n") is None)
  assert_true(TrayOwner::parse("pid=1\nts_ms=1750000000000x\n") is None)
}

///|
/// 非关键字段读成垃圾就是 0，不该拖着整条记录一起废掉。
///
/// 这条很重要：`miss` 或 `helper` 写坏了，只要 pid 和时间戳还在，
/// 仍然要能判出「托盘死了」并清场。
test "托盘心跳：helper 和 miss 读成垃圾就退到 0" {
  let back = TrayOwner::parse(
    "pid=9\nscript=s\nhelper=oops\nts_ms=1000\nmiss=-3\n",
  )
  match back {
    None => fail("非关键字段坏了不该整条丢掉")
    Some(p) => {
      assert_eq(p.helper, 0)
      assert_eq(p.miss, 0)
      assert_eq(p.script, "s")
    }
  }
}

///|
/// 空文本、只有空行、完全不是 key=value 的垃圾，都解析不出记录。
test "托盘心跳：空白和垃圾文本解析不出来" {
  assert_true(TrayOwner::parse("") is None)
  assert_true(TrayOwner::parse("\n\n\n") is None)
  assert_true(TrayOwner::parse("this is not a record") is None)
  assert_true(TrayOwner::parse("{}") is None)
}

///|
/// 多出来的字段忽略，顺序变了也照读 —— 以后加字段不用同时改两边。
test "托盘心跳：未知字段忽略、顺序无关" {
  let back = TrayOwner::parse(
    "ts_ms=2000\nfuture=1\npid=11\nfoo=bar\nscript=scr\nhelper=12\n",
  )
  match back {
    None => fail("带未知字段的记录应该能读")
    Some(p) => {
      assert_eq(p.pid, 11)
      assert_eq(p.ts_ms, 2000L)
      assert_eq(p.script, "scr")
      assert_eq(p.helper, 12)
      assert_eq(p.miss, 0)
    }
  }
}
