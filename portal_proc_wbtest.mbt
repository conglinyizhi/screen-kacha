///|
/// 清掉一个测试目录：里面的东西先删，再删目录自己。
async fn wipe(dir : String) -> Unit {
  let names = try {
    let d = @fs.opendir(dir)
    let all = d.read_all()
    d.close()
    all
  } catch {
    _ => ([] : Array[String])
  }
  for name in names {
    @fs.remove("\{dir}/\{name}") catch {
      _ => ()
    }
  }
  @fs.remove(dir) catch {
    _ => ()
  }
}

///|
/// force 的核心：只认「这一轮之后重写出来的」node。
///
/// 只看时间不看内容，是因为 portal 换了会话也可能给出同一个号（节点号是
/// 复用的）：内容一样、mtime 变了，正是要认的那种。
async test "portal: 重写过才算新的 node" {
  let dir = "/tmp/ssmb-portal-mtime"
  wipe(dir)
  @fs.mkdir(dir, permission=0o700, recursive=true) catch {
    _ => ()
  }
  let path = "\{dir}/portal.node"
  assert_eq(@util.write_atomic_text(path, "111"), 0)

  let stamp = mtime_ns(path)
  assert_true(stamp > 0L)
  // 还是原来那个文件：不算重写
  assert_false(rewritten_since(path, stamp))

  // 内容原样重写一遍（portal 又拿到了同一个号）：算重写
  @async.sleep(5)
  assert_eq(@util.write_atomic_text(path, "111"), 0)
  assert_true(rewritten_since(path, stamp))

  // 文件本来不存在：现在有就算新的
  let gone = "\{dir}/never"
  assert_eq(mtime_ns(gone), -1L)
  assert_false(rewritten_since(gone, -1L))
  assert_eq(@util.write_atomic_text(gone, "7"), 0)
  assert_true(rewritten_since(gone, -1L))

  wipe(dir)
}

///|
/// force 跳过缓存等新的 node，而且**不删文件**。
///
/// 删文件是原来的做法：删的那一瞬间助手可能正好写进来，就被删掉了，
/// 而它以为写完了不会再来一次 —— 于是恢复白等一场。这里让「助手」在
/// 300ms 后重写一遍（同号，只能靠 mtime 认出来），同时检查那一刻文件还在。
async test "portal: force 跳过缓存，也不删掉 node 文件" {
  let dir = "/tmp/ssmb-portal-force"
  wipe(dir)
  @fs.mkdir(dir, permission=0o700, recursive=true) catch {
    _ => ()
  }
  let path = "\{dir}/portal.node"
  assert_eq(@util.write_atomic_text(path, "111"), 0)

  let mut file_alive_midway = false
  @async.with_task_group() <| group => {
    group.spawn_bg() <| async fn() {
      @async.sleep(300)
      // force 期间文件必须还在：删了就是把助手写进来的东西扔掉
      file_alive_midway = @fs.exists(path) catch { _ => false }
      let _ = @util.write_atomic_text(path, "111")
    }
    let got = @async.with_timeout_opt(5000, async fn() {
      match acquire_portal_node(dir, force=true) {
        Some(n) => n
        None => 0
      }
    })
    // 没等到就是超时（这条 5 秒就失败，不会卡 30 秒）
    assert_eq(got, Some(111))
  }
  assert_true(file_alive_midway)

  wipe(dir)
}
