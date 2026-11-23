///|
/// 测试用的读写小工具。原子写本身是同步的，读回来验内容得走 async fs。
async fn read_text(path : String) -> String? {
  let got = Some(@fs.read_file(path).binary()) catch { _ => None }
  match got {
    Some(b) => Some(@utf8.decode_lossy(b))
    None => None
  }
}

///|
/// 目录里的文件名，用逗号拼起来好比较。
async fn dir_listing(dir : String) -> String {
  let names = try {
    let d = @fs.opendir(dir)
    let all = d.read_all()
    d.close()
    all
  } catch {
    _ => ([] : Array[String])
  }
  let out = StringBuilder()
  let mut first = true
  for name in names {
    if !first {
      out.write_char(',')
    }
    first = false
    out.write_string(name)
  }
  out.to_string()
}

///|
/// 清掉一个测试目录：里面的东西先删，再删目录自己。
///
/// 不用 `@fs.remove` 的 recursive 参数：这个工具链上它不认这个 label，
/// 测试里也不值得为它绕。
async fn wipe_dir(dir : String) -> Unit {
  let names = try {
    let d = @fs.opendir(dir)
    let all = d.read_all()
    d.close()
    all
  } catch {
    _ => ([] : Array[String])
  }
  for name in names {
    let p = "\{dir}/\{name}"
    let is_dir = try {
      let d = @fs.opendir(p)
      d.close()
      true
    } catch {
      _ => false
    }
    if is_dir {
      wipe_dir(p)
    } else {
      @fs.remove(p) catch {
        _ => ()
      }
    }
  }
  @fs.remove(dir) catch {
    _ => ()
  }
}

///|
/// 准备一个干净的测试目录。
async fn fresh_dir(dir : String) -> Unit {
  wipe_dir(dir)
  @fs.mkdir(dir, permission=0o700, recursive=true) catch {
    _ => ()
  }
}

///|
/// 正常写：内容原样落盘，临时文件不许留下。
async test "原子写：写进去的内容完整" {
  let dir = "/tmp/ssmb-atomic-basic"
  fresh_dir(dir)
  let path = "\{dir}/port"
  assert_eq(write_atomic_text(path, "8930"), 0)
  assert_eq(read_text(path), Some("8930"))
  // 只剩正式文件：临时文件必须已经 rename 掉
  assert_eq(dir_listing(dir), "port")
  wipe_dir(dir)
}

///|
/// 覆盖已有文件：新内容整份替换，不能残留上一次的尾巴。
///
/// 后写的内容更短，正好能看出「有没有把旧文件截断干净」。
async test "原子写：覆盖已有文件，不留旧内容的尾巴" {
  let dir = "/tmp/ssmb-atomic-overwrite"
  fresh_dir(dir)
  let path = "\{dir}/portal.node"
  assert_eq(write_atomic_text(path, "88123456"), 0)
  assert_eq(read_text(path), Some("88123456"))
  assert_eq(write_atomic_text(path, "42"), 0)
  assert_eq(read_text(path), Some("42"))
  assert_eq(dir_listing(dir), "portal.node")
  wipe_dir(dir)
}

///|
/// 父目录不存在时自己建出来（端口文件、错误记录都会落到状态目录里，
/// 首次运行时那个目录可能还没有）。
async test "原子写：父目录不存在就建" {
  let dir = "/tmp/ssmb-atomic-mkdir"
  wipe_dir(dir)
  let path = "\{dir}/a/b/access.conf"
  assert_eq(write_atomic_text(path, "allow_lan = false\n"), 0)
  assert_eq(read_text(path), Some("allow_lan = false\n"))
  wipe_dir(dir)
}

///|
/// 写失败时旧内容必须原样留着，也不能留下临时文件。
///
/// 用不可写目录模拟失败：目录 0500 之后建不了临时文件，写必然失败。
/// 这条正是不原子写法最坏的地方 —— 先 open(O_TRUNC) 把旧文件截断，
/// 后面写失败就只剩一个空文件，读到它的一方会退回默认配置。
///
/// 注意：以 root 跑测试时这条会失败（root 无视目录权限）。
async test "原子写：写失败时旧内容不变" {
  let dir = "/tmp/ssmb-atomic-readonly"
  fresh_dir(dir)
  let path = "\{dir}/access.conf"
  assert_eq(write_atomic_text(path, "allow_lan = false\n"), 0)
  @fs.chmod(dir, 0o500) catch {
    _ => ()
  }
  let rc = write_atomic_text(path, "allow_lan = true\n")
  assert_true(rc < 0)
  // 旧内容一字不变
  assert_eq(read_text(path), Some("allow_lan = false\n"))
  // 失败路径也不许把临时文件留在目录里
  assert_eq(dir_listing(dir), "access.conf")
  @fs.chmod(dir, 0o700) catch {
    _ => ()
  }
  wipe_dir(dir)
}

///|
/// 连写两次不会互相踩：临时文件名带进程内序号。
///
/// 固定叫「<path>.tmp」的话，两个写方同时写会互相截断，然后各自 rename，
/// 结果是一份拼接出来的内容。
async test "原子写：连写两次都成功" {
  let dir = "/tmp/ssmb-atomic-twice"
  fresh_dir(dir)
  let path = "\{dir}/port"
  for i = 0; i < 5; i = i + 1 {
    assert_eq(write_atomic_text(path, "port-\{i}"), 0)
    assert_eq(read_text(path), Some("port-\{i}"))
  }
  assert_eq(dir_listing(dir), "port")
  wipe_dir(dir)
}
