///|
/// 一帧抓好的画面
pub struct Frame {
  bytes : Bytes
  ts : Int64
}

///|
/// 采集状态：一帧缓存 + 统计 + 一把锁
///
/// spectacle 是单实例应用，同时拉起多个会互相卡死（实测三个并发就永久挂住）。
/// 所以采集必须串行，且并发请求只能合并成一次采集：抢到锁后再判一次帧龄。

///|
/// PipeWire 取帧的状态。
///
/// 「现在到底用不用它」不在这里，而在 `Store::src`：一个值说清来源，
/// 免得 `on` / `fake` / 别处的标志各说各话。这里只留流的句柄和它的失败计数。
pub struct PipeWireState {
  /// 连续失败次数，到阈值就回落 spectacle
  mut fails : Int32
  /// 抓帧句柄
  stream : @pipewire.PipeWire
  mut raw_seq : Int32
  /// 最近一帧原始像素的位置和尺寸。
  ///
  /// 每帧写一个新文件，不在同一个路径上覆盖：请求方可能在泵写下一帧的时候
  /// 才去读文件，共用一个路径就会读到「上一帧的尺寸配这一帧的像素」。
  mut raw_frame : (String, Int32, Int32)?
  /// 上一帧的位置。留着不删：可能有请求刚拿到它的路径还没读完。
  mut raw_prev : String?
}

///|
pub struct Store {
  shot : String
  lock : @async.Mutex
  /// 测试用假帧源：设了就不跑 spectacle，直接读这个文件
  fake : String?
  /// 运行时目录（/run/user/<uid>），用来确认 Wayland socket 是否已经就绪
  wl_dir : String
  /// PipeWire 那一簇状态：流、连续失败计数、原始帧轮转。
  ///
  /// 从 `Store` 上摘出来单独命名，是因为它们是同一件事的几个部分：
  /// 看门狗判定「流死了」之后要断流、要重连，只看这一个结构就够。
  pw_state : PipeWireState
  /// 当前取帧来源：推模式还是拉模式、`/health` 上叫什么，都由它回答
  mut src : FrameSource
  /// 连续多少轮被看门狗判定「推模式流停了」。
  ///
  /// 恢复只给一次机会：重连之后下一轮还是没帧，就直接退回拉模式。
  /// 不然「重连 → 5 秒没帧 → 再重连」会变成一个安静的自转，
  /// 画面照样不动，日志倒是很热闹。
  mut dead_rounds : Int32
  /// 最近一次请求的时间戳（毫秒），泵据此决定抓多勤
  mut last_req : Int64
  mut frame : Frame?
  mut cap_ms : Int64
  mut count : Int32
  mut fails : Int32
  /// 连续失败次数，成功一次就清零。
  ///
  /// `fails` 是累计值，只增不减，看不出「现在是不是还在坏」。
  /// 这两个分开：累计值给「出过多少次问题」，连续值给「现在有没有好」。
  mut consec_fails : Int32
  /// 上一次真正发起抓帧的时刻。请求驱动的抓帧有频率上限，靠它算间隔。
  mut last_capture : Int64
  /// 后台泵的节奏，用来判断帧是不是该更新了
  pump_ms : Int32
  mut err : String
  mut seq : Int32
  /// 光标合成失败的次数和最后一次原因。
  ///
  /// 合成失败原来是完全静默的：素材打不开、或者坐标有了但贴图失败，
  /// 调用方拿到的仍是一张普通截图（200），从外面看不出区别。托盘那边的开关
  /// 还显示「已开启」。这里记下来，`/health` 才答得出「为什么没箭头」。
  mut cursor_fails : Int32
  mut cursor_err : String
  /// 已经报过「读不到」的文档名。
  ///
  /// `/llms.txt`、`/skill.md` 是 agent 会反复拉的，每次 fallback 都打一行
  /// 会把 journal 冲掉，所以同一个文件只报第一次。
  missing_docs : Map[String, Bool]
  /// 素材（光标 PNG）和文档所在目录。相对文件名都按它拼。
  data_dir : String
  /// 编进二进制的文档与光标素材（名字 → 字节）。
  ///
  /// 以前这些是 pages.mbt 里手抄的硬编码兜底，改磁盘文件忘了改兜底就会漂移。
  /// 现在磁盘读不到时直接用构建时嵌入的那一份，两边永远是同一份。
  embedded : Map[String, Bytes]
  /// 素材实际所在的目录：磁盘上有就用 data_dir，否则是释放出来的临时目录
  mut asset_dir : String
  /// 临时输出文件的目录。
  ///
  /// 不再直接落在 /tmp 根下：那个目录谁都能读、谁都能写，截图 0644 摆着，
  /// 名字又是可预测的（时间戳 + pid + 序号），本地别的用户可以读到屏幕内容，
  /// 也能预置符号链接把写入引走。这里用服务自己的目录，权限 0700。
  tmp_dir : String
}

///|
pub fn Store::new(
  shot~ : String,
  fake~ : String? = None,
  wl_dir~ : String = default_runtime_dir(),
  pw~ : Bool = false,
  tmp_dir~ : String = "/tmp/screen-kacha",
  pump_ms~ : Int32 = 500,
  data_dir~ : String = ".",
) -> Store {
  {
    shot,
    lock: @async.Mutex(),
    fake,
    wl_dir,
    pw_state: {
      fails: 0,
      stream: @pipewire.PipeWire::new(app_name="screen-kacha"),
      raw_seq: 0,
      raw_frame: None,
      raw_prev: None,
    },
    src: if pw {
      Pipewire
    } else if fake is Some(_) {
      Fake
    } else {
      Spectacle
    },
    dead_rounds: 0,
    last_req: 0L,
    frame: None,
    cap_ms: 0L,
    count: 0,
    fails: 0,
    consec_fails: 0,
    last_capture: 0L,
    pump_ms,
    err: "",
    seq: 0,
    tmp_dir,
    cursor_fails: 0,
    cursor_err: "",
    missing_docs: Map([]),
    data_dir,
    embedded: @embed.decode_all(emb_paths, emb_data),
    asset_dir: data_dir,
  }
}

///|
fn Store::fresh(self : Store, max_age_ms : Int64) -> Bool {
  match self.frame {
    Some(f) => @async.now() - f.ts <= max_age_ms
    None => false
  }
}

///|
/// 请求驱动抓帧的最小间隔。
///
/// `age` 是公开查询参数，把它压到几十毫秒就等于「每个请求都重抓一次」：
/// PipeWire 路径每次 8MB 原始帧落盘 + 一次全尺寸重编码，spectacle 路径一次
/// 七八百毫秒，而且整段都在采集锁里，后面排队的请求一起被堵。
/// 没有认证的服务，一个 curl 循环就能把机器持续打满。
const MIN_CAPTURE_GAP_MS : Int64 = 250

///|
/// 距上次抓帧还不到最小间隔，这次就别抓了。
pub fn capture_too_soon(last_capture_ms : Int64, now_ms : Int64) -> Bool {
  if last_capture_ms <= 0L {
    return false
  }
  now_ms - last_capture_ms < MIN_CAPTURE_GAP_MS
}

///|
/// 保证有一帧不旧于 max_age_ms 的画面
pub async fn Store::ensure(self : Store, max_age_ms : Int64) -> Unit {
  if self.fresh(max_age_ms) {
    return
  }
  self.lock.acquire()
  defer self.lock.release()
  // 抢到锁之后再判一次，把并发请求合并成一次采集
  if self.fresh(max_age_ms) {
    return
  }
  self.capture()
}

///|
/// 桌面还没起来时 Wayland socket 不存在，这时硬拉 spectacle 会被 Qt 直接 abort
/// （开机时就会看到崩溃框和 coredump）。先确认 socket 在，再决定要不要抓。
async fn wayland_ready(dir : String) -> Bool {
  // 不能只认 wayland-0..3：编号在 compositor 每次重启后递增，
  // 跑过几轮 KWin 崩溃的机器上出现 wayland-5、wayland-7 是常态。
  // 那时这里返回 false，capture 会直接记「socket 还没就绪」返回，
  // 连 spectacle 都不拉，桌面好得很，服务却永久抓不到图。
  let names = try {
    let d = @fs.opendir(dir)
    let all = d.read_all()
    d.close()
    all
  } catch {
    _ => []
  }
  for name in names {
    // 只要 wayland-数字 这种：目录里还有 wayland-1.lock、wayland-cursor.sock
    // 之类的东西，见着就算会把「没 socket」误判成「就绪」
    if !name.has_prefix("wayland-") || name.has_suffix(".lock") {
      continue
    }
    let tail = name[8:]
    if tail.length() == 0 || tail.length() > 2 {
      continue
    }
    let mut digits = true
    for i = 0; i < tail.length(); i = i + 1 {
      let c = tail[i].to_int()
      if c < 48 || c > 57 {
        digits = false
      }
    }
    if digits {
      return true
    }
  }
  false
}

///|
async fn Store::capture(self : Store) -> Unit {
  self.last_capture = @async.now()
  let t0 = @async.now()
  // 按来源分派，一条来源一个分支。
  //
  // 以前这里是「pw_state.on 一层、Wayland 就绪一层、fake 一层」的 if 套 if，
  // 每一层都在问「这次是不是该走我」，加一种来源就得在中间插一段。
  match self.src {
    Pipewire => self.capture_pipewire(t0)
    Fake => self.capture_fake(t0)
    Spectacle => self.capture_spectacle(t0)
  }
}

///|
/// 假帧源：直接从固定文件读一帧。测试用，不碰桌面，也不碰 PipeWire。
async fn Store::capture_fake(self : Store, t0 : Int64) -> Unit {
  let path = match self.fake {
    Some(p) => p
    None => {
      // 来源标成 fake 却没有文件：这是状态被摆错，不是画面出问题，
      // 但照样要留痕，否则 /health 会说 ok 而帧永远不变。
      self.record_fail("来源是 fake，却没有给假帧文件")
      return
    }
  }
  let data = try {
    let f = @fs.open(path, mode=ReadOnly)
    let bytes = f.read_all().binary()
    f.close()
    bytes
  } catch {
    err => {
      self.record_fail("读假帧失败: \{err}")
      return
    }
  }
  self.record_ok(data, @async.now() - t0)
}

///|
/// 拉模式的主路径：拉一次 spectacle。
async fn Store::capture_spectacle(self : Store, t0 : Int64) -> Unit {
  // 手里有假帧源却走到真实抓屏，只可能是来源被手工改错了。
  // 宁可用假帧，也不要在这时拉起 spectacle：没有 DISPLAY 的环境里
  // 它的 Qt 初始化会直接 abort，留一个核心转储。
  if self.fake is Some(_) {
    self.capture_fake(t0)
    return
  }
  if !wayland_ready(self.wl_dir) {
    // 把找的目录写出来：uid 或者 XDG_RUNTIME_DIR 不对时，这行是唯一的线索
    self.record_fail(
      "Wayland socket 还没就绪（在 \{self.wl_dir} 里没找到 wayland-数字）",
    )
    return
  }
  // spectacle 是单实例的：别的抓帧客户端占着锁时它会一直等。
  // 没有超时就会永久卡住并一直握着采集锁，所以用 timeout 兜住。
  //
  // -p 是把鼠标指针画进画面。不带的话截出来没有光标，
  // 「看看屏幕上是什么」就少了「现在指着哪」这条信息。
  // -k 1：TERM 之后 1 秒还活着就 KILL。
  // 不带 -k 的话，spectacle 卡在不可中断的地方不响应 TERM，
  // timeout 自己也不返回（实测：`timeout 2 bash -c "trap '' TERM; sleep 8"`
  // 真的跑满 8 秒），这层兜底就是漏的，采集锁会被一直握着。
  let code = @process.run("/usr/bin/timeout", [
    "-k",
    "1",
    "3",
    "/usr/bin/spectacle",
    "-f",
    "-b",
    "-n",
    "-p",
    "-o",
    self.shot,
  ]) catch {
    err => {
      self.record_fail("spectacle 调用失败: \{err}")
      return
    }
  }
  if code == 124 {
    self.record_fail(
      "spectacle 超过 8 秒未完成（多半被别的抓帧进程占着），已中止",
    )
    return
  }
  if code != 0 {
    self.record_fail("spectacle 退出码 \{code}")
    return
  }
  let data = try {
    let file = @fs.open(self.shot, mode=ReadOnly)
    let bytes = file.read_all().binary()
    file.close()
    bytes
  } catch {
    err => {
      // 这里不能用 pw_failed：这一轮走的是 spectacle，根本没碰 PipeWire。
      // 旧代码会污染 PipeWire 的失败计数，连累它被误判降级，
      // 日志还会打「PipeWire 连续失败…回落到 spectacle」，把排障带偏。
      self.record_fail("读帧文件失败: \{err}")
      return
    }
  }
  self.record_ok(data, @async.now() - t0)
}

///|
pub fn Store::bytes(self : Store) -> Bytes? {
  match self.frame {
    Some(f) => Some(f.bytes)
    None => None
  }
}

///|
/// 有人在取图，帧却迟迟不更新，说明后台泵停了。
///
/// 光看 `err` 判断不出来：泵线程要是整个卡死，就没有任何一次采集失败，
/// `err` 一直是空的，`/health` 会一直说 ok，而画面停在几分钟前。
///
/// 两个前提都要满足才算停摆：
/// - 最近真的有人在取图（`idle_ms` 小）。没人用的时候泵会主动放慢，
///   帧变旧是应该的，不能报错。
/// - 帧龄超过泵节奏的十倍再加五秒余量，避免把正常的调度抖动算进去。
pub fn frame_is_stalled(
  frame_age_ms : Int64,
  idle_ms : Int64,
  pump_ms : Int32,
) -> Bool {
  if frame_age_ms < 0L {
    // 一帧都还没有：那是「还没抓到」，不是「停摆」
    return false
  }
  let pump = pump_ms.to_int64()
  let demand = idle_ms < pump * 20L
  demand && frame_age_ms > pump * 10L + 5000L
}

///|
pub fn Store::is_stalled(self : Store) -> Bool {
  frame_is_stalled(self.age_ms(), self.idle_ms(), self.pump_ms)
}

///|
/// 光标合成成功一次就把失败计数和原因清掉，跟采集那套一致。
pub fn Store::note_cursor_ok(self : Store) -> Unit {
  self.cursor_fails = 0
  self.cursor_err = ""
}

///|
/// 记一次光标合成失败，并在日志里留一行。
pub fn Store::note_cursor_fail(self : Store, why : String) -> Unit {
  self.cursor_fails = self.cursor_fails + 1
  if should_log_failure(self.cursor_fails, why != self.cursor_err) {
    eprintln("光标合成失败（连续 \{self.cursor_fails} 次）：\{why}")
  }
  self.cursor_err = why
}

///|
pub fn Store::cursor_fails(self : Store) -> Int32 {
  self.cursor_fails
}

///|
pub fn Store::cursor_err(self : Store) -> String {
  self.cursor_err
}

///|
/// 素材和文档的路径。相对文件名按 `data_dir` 拼成绝对路径。
///
/// 原来直接用 `cursor-arrow.png` 这种相对名，只有进程的工作目录正好是安装
/// 目录时才找得到。换一个 unit、或者从别处手动跑，光标就静默失效，
/// 而托盘上的勾还亮着。
pub fn Store::data_path(self : Store, name : String) -> String {
  if self.data_dir == "" || self.data_dir == "." || name.has_prefix("/") {
    name
  } else {
    "\{self.data_dir}/\{name}"
  }
}

///|
/// 素材（光标 PNG）的路径。
///
/// 和文档分开：文档从 `data_dir` 读、读不到用嵌入的；素材是 C 侧按路径打开的，
/// 磁盘上没有就得先落盘。`init_assets` 会决定到底从哪个目录取。
pub fn Store::asset_path(self : Store, name : String) -> String {
  if self.asset_dir == "" || name.has_prefix("/") {
    name
  } else {
    "\{self.asset_dir}/\{name}"
  }
}

///|
/// 把内嵌的素材释放到临时目录，供 C 侧按路径读取。
///
/// C 的 `cursor_overlay` 要的是文件路径，不是内存，所以只能落盘。只补缺失的
/// 文件：磁盘上有（用户自己换过素材）就整个用磁盘那份，不混着来。
pub async fn Store::init_assets(self : Store) -> Unit {
  let probe = "\{self.data_dir}/cursor-arrow.png"
  if (@fs.exists(probe) catch { _ => false }) {
    self.asset_dir = self.data_dir
    return
  }
  self.asset_dir = self.tmp_dir
  for
    name in [
      "cursor-arrow.png", "cursor-mask.png", "cursor-arrow-classic.png", "cursor-mask-classic.png",
    ] {
    let target = "\{self.tmp_dir}/\{name}"
    if (@fs.exists(target) catch { _ => false }) {
      continue
    }
    match self.embedded_bytes(name) {
      Some(bytes) => {
        let _ = @fs.write_file(target, bytes, create_mode=CreateOrTruncate) catch {
          _ => ()
        }
      }
      None => ()
    }
  }
}

///|
/// 取内嵌的字节。键在生成时带前导斜杠（`/skill.md`），这里两种都认。
fn Store::embedded_bytes(self : Store, name : String) -> Bytes? {
  let key = if name.has_prefix("/") { name } else { "/\{name}" }
  match self.embedded.get(key) {
    Some(bytes) => Some(bytes)
    None => self.embedded.get(name)
  }
}

///|
/// 取内嵌的文本（文档）。没有就返回 None。
pub fn Store::embedded_text(self : Store, name : String) -> String? {
  match self.embedded_bytes(name) {
    Some(bytes) => Some(@utf8.decode_lossy(bytes))
    None => None
  }
}

///|
/// 第一次读不到某个文档时返回 true，用来决定要不要打日志。
pub fn Store::note_missing_doc(self : Store, name : String) -> Bool {
  match self.missing_docs.get(name) {
    Some(_) => false
    None => {
      self.missing_docs.set(name, true)
      true
    }
  }
}

///|
pub fn Store::consec_fails(self : Store) -> Int32 {
  self.consec_fails
}

///|
pub fn Store::age_ms(self : Store) -> Int64 {
  match self.frame {
    Some(f) => @async.now() - f.ts
    None => -1L
  }
}

///|
pub fn Store::cap_ms(self : Store) -> Int64 {
  self.cap_ms
}

///|
pub fn Store::count(self : Store) -> Int32 {
  self.count
}

///|
pub fn Store::fails(self : Store) -> Int32 {
  self.fails
}

///|
pub fn Store::err(self : Store) -> String {
  self.err
}

///|
pub fn Store::shot(self : Store) -> String {
  self.shot
}

///|
pub fn Store::next_tmp(self : Store, ext : String) -> String {
  self.seq += 1
  // 文件名带时间和 pid，别用纯自增序号：进程重启后序号从 1 开始，
  // 会和上一个实例的同名文件撞上。时间戳 + pid + 序号在进程内保证唯一，
  // 跨进程也几乎不会撞。
  //
  // 光靠名字防不住本地攻击者（可预测就是可预测），真正的防线是 `tmp_dir`：
  // 目录由服务自己按 0700 建，别的用户进不去，也放不进东西。C 侧再叠一层
  // O_NOFOLLOW + 0600。
  // 只管发路径，不在这里删旧文件。
  //
  // 原来是「环形滚动，超了删最旧的」，而并发上限是 64、环上只留 10 个：
  // 并发一高，还在被别的请求读的文件就被后面的人删掉了。现在由读回那头
  // 读完即删（见 `read_result`），这里再删只会误伤。
  "\{self.tmp_dir}/out-\{@async.now()}-\{current_pid()}-\{self.seq}.\{ext}"
}

///|
/// 当前进程号，来自 C 的 getpid()。
fn current_pid() -> Int32 {
  current_pid_raw()
}

///|
extern "c" fn current_pid_raw() -> Int32 = "moonbit_current_pid"

///|
/// 删掉目录里匹配「前缀 + 后缀」的文件，返回删掉的数量。
#borrow(dir, prefix, suffix)
extern "c" fn clean_stale_frames_raw(
  dir : Bytes,
  prefix : Bytes,
  suffix : Bytes,
) -> Int32 = "moonbit_clean_stale_frames"

///|
/// 清掉上次运行留下的临时文件。
///
/// 原始帧每帧 8MB，文件名里的序号每个进程都从 1 重来，上个进程跑到几千号的
/// 那些再也不会被覆盖，会一直躺在 tmpfs（也就是内存）里。临时输出正常情况
/// 读完就删了，但进程被 kill 时会留下几个。启动时各扫一遍。
pub fn clean_stale_frames(
  dir : String,
  prefix : String,
  suffix : String,
) -> Int32 {
  clean_stale_frames_raw(
    @util.cstr(dir),
    @util.cstr(prefix),
    @util.cstr(suffix),
  )
}

///|
/// 采集成功记一笔。单独抽出来，采集本身要真跑 spectacle，这层逻辑可以单测。
fn Store::record_ok(self : Store, bytes : Bytes, cap_ms : Int64) -> Unit {
  self.cap_ms = cap_ms
  self.count += 1
  self.err = ""
  // 成功一次就把 PipeWire 的失败计数清零。
  //
  // 这里原来是漏的：计数只加不减，>=3 就永久切到 spectacle。
  // 后果是偶发失败会跨天累积，跑一天几万帧里只要有三次抖动，
  // 抓帧就从 24ms 掉到 700ms，而 /health 只显示 source=spectacle，
  // 看起来像"正常回退"，没人会去查。
  // 启动期更危险：PipeWire::connect 立刻返回不等第一帧，
  // 泵 500ms 一拍，协商超过 1.5 秒就会被判死，一开机就没救了。
  self.pw_state.fails = 0
  self.consec_fails = 0
  // 帧回来了，看门狗的「已经恢复过一次」也归零：下一次真的再停，
  // 它还该有一次重连机会。
  self.dead_rounds = 0
  self.frame = Some({ bytes, ts: @async.now(), })
}

///|
/// 采集失败记一笔，保留失败原因。

///|
/// 连续失败到第几次该往日志里写一行。
///
/// 泵 500ms 一拍，同一个错误会一直重复。只在「错误内容变了」或者
/// 「连续次数是 30 的倍数」时写，既不丢信息，也不会把 journal 刷掉。
const FAIL_LOG_EVERY : Int32 = 30

///|
fn should_log_failure(consec : Int32, err_changed : Bool) -> Bool {
  if err_changed {
    return true
  }
  consec % FAIL_LOG_EVERY == 0
}

///|
fn Store::record_fail(self : Store, msg : String) -> Unit {
  self.fails += 1
  self.consec_fails += 1
  // 失败必须落到日志里。
  //
  // 原来只更新内存字段：服务一直抓不到帧，journal 里却只有启动那两行，
  // 只能靠 /health 才发现，而 /health 也要人主动去问。
  if should_log_failure(self.consec_fails, msg != self.err) {
    eprintln("采集失败（连续 \{self.consec_fails} 次）：\{msg}")
  }
  self.err = msg
}

///|
/// 有人来取图时打点，泵据此判断当前是不是有人在看屏幕。
pub fn Store::mark_request(self : Store) -> Unit {
  self.last_req = @async.now()
}

///|
/// 距离最近一次取图过去了多久（毫秒）。泵用它决定抓帧频率。
pub fn Store::idle_ms(self : Store) -> Int64 {
  if self.last_req == 0L {
    return 1L << 40
  }
  @async.now() - self.last_req
}

///|
/// 当前用户的 uid。
///
/// 问系统要，不写死 1000：多用户机器、root、或者容器里 uid 都可能不是 1000，
/// 猜错就会指到别人的运行时目录。
extern "c" fn current_uid_raw() -> Int32 = "moonbit_current_uid"

///|
pub fn current_uid() -> Int32 {
  current_uid_raw()
}

///|
/// runtime 目录怎么定：给了 XDG_RUNTIME_DIR 就用它，否则 `/run/user/<uid>`。
///
/// 单独抽出来是为了能测：这台机器上 uid 正好是 1000，跟写死的旧值一样，
/// 不换个 uid 试就看不出改没改。
pub fn runtime_dir_from(env : String?, uid : Int32) -> String {
  match env {
    Some(v) => if v == "" { "/run/user/\{uid}" } else { v }
    None => "/run/user/\{uid}"
  }
}

///|
/// 当前进程该用的 runtime 目录。
pub fn default_runtime_dir() -> String {
  runtime_dir_from(@env.get_env_var("XDG_RUNTIME_DIR"), current_uid())
}

///|
/// 用 PipeWire 的常驻流取帧：把最新原始帧落盘，再用 moonimage 转成 JPEG。

///|
/// PipeWire 取帧失败：**连续** 3 次才切回 spectacle。
///
/// 「连续」靠 `record_ok` 里清零 `pw_fails` 来保证，别把那一行删了，
/// 删了就退化成「累计」，偶发抖动也能把快路径永久打掉。
fn Store::pw_failed(self : Store, why : String) -> Unit {
  self.pw_state.fails = self.pw_state.fails + 1
  if self.pw_state.fails >= 3 {
    let next = self.pull_source()
    self.src = next
    eprintln(
      "PipeWire 连续失败 \{self.pw_state.fails} 次，回落到 \{next.label()}: \{why}",
    )
  }
  self.record_fail(why)
}

///|
async fn Store::capture_pipewire(self : Store, t0 : Int64) -> Unit {
  // 每帧一个独立文件：请求方读的时候，泵可能已经在写下一帧了，
  // 共用一个路径就会读到错位的内容。
  self.pw_state.raw_seq += 1
  let raw = "\{self.shot}.\{self.pw_state.raw_seq}.bgra"
  // 尺寸和像素必须来自同一帧，所以用一次调用同时取。
  //
  // 原来是 size() + save_frame() 两次独立调用，中间隔着一次完整落盘
  // （8MB 写）。桌面在这段时间改分辨率（切缩放倍率、拔插外接屏），
  // 第二次拿到的就是「旧尺寸配新像素」，解码按错的尺寸走，
  // 产出花屏，或者直接读越界。改成一次调用后由 C 侧在同一把锁里
  // 读完尺寸再写像素，两者必然一致。
  let (wrote, w, h) = self.pw_state.stream.save_frame_consistent(raw)
  if w <= 0 || h <= 0 {
    self.pw_failed("PipeWire 还没协商出画面格式")
    return
  }
  // 写入长度必须正好是 w*h*4：磁盘满、quota 打满、tmpfs 被吃光时
  // 会返回一个正数的「部分写入量」，当成成功就会去解一个截断的文件。
  let expect = w * h * 4
  if wrote != expect {
    self.pw_failed("PipeWire 帧写入不完整（\{wrote}/\{expect} 字节）")
    return
  }
  // 用自带的 moonimage 转码：
  // 实测 19ms vs 53ms，而且不再依赖外部程序。
  // 先记下「这一帧在哪、多大」，再去编码。
  // 编码和后续请求都只看这个三元组，不再碰 C 侧的实时状态。
  // 轮转：删上上帧，保留上一帧。
  //
  // 删上一帧是不行的，可能有请求刚拿到它的路径、正要读，
  // 文件就没了。留一帧的余量足够：请求拿到路径到读完只有几毫秒，
  // 而泵最快 500ms 才换一次帧。
  match self.pw_state.raw_prev {
    Some(old) => {
      let _ = @fs.remove(old) catch { _ => () }
    }
    None => ()
  }
  self.pw_state.raw_prev = match self.pw_state.raw_frame {
    Some((p, _, _)) => Some(p)
    None => None
  }
  self.pw_state.raw_frame = Some((raw, w, h))
  if !@image.bgra_to_jpeg(raw, w, h, 0, JPEG_QUALITY, self.shot) {
    self.pw_failed("moonimage 转码失败")
    return
  }
  let data = try {
    let f = @fs.open(self.shot, mode=ReadOnly)
    let b = f.read_all().binary()
    f.close()
    b
  } catch {
    err => {
      // 这里不能用 pw_failed：这一轮走的是 spectacle，根本没碰 PipeWire。
      // 旧代码会污染 PipeWire 的失败计数，连累它被误判降级，
      // 日志还会打「PipeWire 连续失败…回落到 spectacle」，把排障带偏。
      self.record_fail("读帧文件失败: \{err}")
      return
    }
  }
  self.record_ok(data, @async.now() - t0)
}

///|
/// 请求驱动的取帧：比 `ensure` 多一道频率上限。
///
/// 后台泵仍然走 `ensure`，不受这个限制：泵的节奏由 `--pump` 控制，是运维
/// 自己定的，不该被请求侧的策略改掉。
pub async fn Store::ensure_request(self : Store, max_age_ms : Int64) -> Unit {
  if self.fresh(max_age_ms) {
    return
  }
  if capture_too_soon(self.last_capture, @async.now()) {
    // 太近了，这次就用现有帧（可能是旧的），不抓
    return
  }
  self.ensure(max_age_ms)
}

///|
/// 当前实际使用的取帧来源，供 /health 展示。
pub fn Store::source(self : Store) -> String {
  self.src.label()
}

///|
/// 当前来源是不是推模式。泵只问这一句，不对 PipeWire 写特例。
pub fn Store::push_source(self : Store) -> Bool {
  self.src.is_push()
}

///|
/// 常驻流真正送来的帧序号。
///
/// 看门狗用它算帧龄：流死了之后序号就不再变，而 JPEG 那一侧
/// 仍然能「成功」地从旧缓冲里再编一帧出来（见 `StreamClock`）。
pub fn Store::stream_seq(self : Store) -> Int64 {
  if self.src is Pipewire {
    self.pw_state.stream.seq()
  } else {
    0L
  }
}

///|
/// 流自己报告的状态（`enum pw_stream_state` 的整数值）。
///
/// 不是推模式时没有流可问，报 0（未连接）：把上一条死流的残留状态报给
/// `/health`，只会让人以为还有条流在。
pub fn Store::stream_state(self : Store) -> Int32 {
  if self.src is Pipewire {
    self.pw_state.stream.state()
  } else {
    0
  }
}

///|
/// 当初给 PipeWire 的 node id；没连过返回 0。
///
/// 和 `stream_state` 一起看才有意义：状态是 streaming、node 却不是 portal
/// 给的那个，说明画面来自别的源 —— 那种情况下 `seq` 涨了也白涨。
pub fn Store::target_node(self : Store) -> Int32 {
  self.pw_state.stream.target_node()
}

///|
/// 后台 portal 监督循环每一轮该做什么。
pub enum PortalStep {
  /// 流还在，等下一轮再看
  Watch
  /// 流没了（从没连上，或者降级了），去重新申请一个 node
  Reacquire
}

///|
/// 降级之后必须继续去申请。
///
/// 「连上过一次就退出循环」是原来的 bug：会话过期或 KWin 重启之后
/// `pw` 掉回 false，可循环已经结束了，服务就永久停在 spectacle 慢路径上。
/// `/health` 还显示 `source=spectacle`，看着像「正常回退」，实际再也不会好。
pub fn portal_step(pipewire_on : Bool) -> PortalStep {
  if pipewire_on {
    Watch
  } else {
    Reacquire
  }
}

///|
/// portal 拿到 node 之后切到 PipeWire 取帧。
///
/// 连之前先断开旧的：`pw_shim` 里「已经在跑就直接返回 0」的分支会拿上一个
/// 可能已经死掉的流假装成功，调用方以为恢复了，实际上还是没帧。
pub fn Store::enable_pipewire(self : Store, node : Int32) -> Bool {
  self.pw_state.stream.disconnect()
  if self.pw_state.stream.connect(node) != 0 {
    eprintln("PipeWire 启动失败，继续用 \{self.src.label()}")
    return false
  }
  self.src = Pipewire
  self.pw_state.fails = 0
  self.dead_rounds = 0
  eprintln("已切到 PipeWire 取帧，node=\{node}")
  true
}

///|
pub fn Store::pipewire_on(self : Store) -> Bool {
  self.src is Pipewire
}

///|
/// 看门狗这一轮干了什么。日志和测试看它。
pub enum WatchdogOutcome {
  /// 流还在出帧，不用动
  Quiet
  /// 判定流死了，重连成功，仍在推模式
  Recovered
  /// 判定流死了，救不回来（或者已经救过一次还是没帧），退回拉模式
  FellBack
}

///|
/// 推模式来源的看门狗：帧停了就恢复，恢复不成退回拉模式。
///
/// 线上那次「只产出 1 帧、`/health` 一直 ok: true、fails: 0、err 空」，
/// 根子就在推模式下泵只会 `sleep(1000); continue`：没人看流还在不在，
/// 流悄悄死掉也不产生任何一次「采集失败」，看板一片绿。
///
/// `recover` 由调用方注入：清 portal 缓存、重新要 node、重连流都要碰文件、
/// 进程和设备，判定和记账留在这里才好单测。返回 `Some(node)` 表示重连成功，
/// `None` 表示没救回来。
///
/// `since_streaming_ms` 是「距上一次确认流在 streaming 过了多久」，由泵那一侧
/// 用 `StreamStateClock` 算好送进来：判定要的是持续时间，而 shim 只给瞬时状态。
pub async fn Store::watchdog(
  self : Store,
  frame_age_ms : Int64,
  since_streaming_ms : Int64,
  recover : async () -> Int32?,
) -> WatchdogOutcome {
  let stream_state = self.stream_state()
  match
    judge_frame_flow(
      self.src,
      frame_age_ms,
      PUSH_STALE_MS,
      stream_state,
      since_streaming_ms,
    ) {
    Flowing => {
      self.dead_rounds = 0
      Quiet
    }
    Stalled => {
      let why = stall_reason(
        frame_age_ms,
        PUSH_STALE_MS,
        stream_state,
        since_streaming_ms,
      )
      if self.dead_rounds > 0 {
        // 上一轮已经重连过一次，帧还是没来：别再重连，直接退回拉模式。
        // `connect` 是立刻返回的，重连成功不代表新流会出帧；
        // 反复重连只会让「流死了」变成一条安静的自转，画面照样不动。
        self.fall_back(why)
        return FellBack
      }
      self.dead_rounds = 1
      match recover() {
        Some(node) => {
          self.record_fail("PipeWire \{why}，已重连 node=\{node}")
          Recovered
        }
        None => {
          self.fall_back(why)
          FellBack
        }
      }
    }
  }
}

///|
/// 推模式救不回来：退回拉模式来源，并把原因记到 `/health` 的 err 里。
///
/// 这一步必须留痕。线上那次流死了之后 `/health` 一直说 ok、err 是空的，
/// 谁也不知道它死过；退回也不写原因的话，看到的只是「来源变成 spectacle」，
/// 看起来像一次正常回退。
///
/// `why` 是判定给出的原因（`stall_reason`）：停帧和「流状态不对」是两回事，
/// 都写成「没有新帧」会把排障的人引到帧龄上去。
fn Store::fall_back(self : Store, why : String) -> Unit {
  let next = self.pull_source()
  self.src = next
  self.pw_state.fails = 0
  self.dead_rounds = 0
  // 死掉的流要断掉：不断它就一直占着那条 screencast 会话，
  // 之后 portal 再申请时拿到的可能还是同一条没人推送的 node。
  self.pw_state.stream.disconnect()
  self.record_fail(
    "PipeWire \{why}，恢复没成功，已退回 \{next.label()} 取帧",
  )
}

///|
/// 退回时该用哪个拉模式来源。
///
/// 有假帧源就用假帧源：测试环境里绝不能因为「退回」把真实的 spectacle 拉起来。
fn Store::pull_source(self : Store) -> FrameSource {
  if self.fake is Some(_) {
    Fake
  } else {
    Spectacle
  }
}

///|
/// 恢复动作最多等这么久。
///
/// `acquire_portal_node` 最坏会等上两分钟（等 autostart 助手重写 node）。
/// 看门狗等它的时候泵是停着的，画面就跟着死那么久 —— 那等于没有退回。
/// 超时按「恢复失败」处理，直接退回拉模式；portal 那边过一会儿还会自己
/// 再申请一次，路不会堵死。
const RECOVER_TIMEOUT_MS : Int32 = 10000

///|
/// 推模式的流判定死了之后的重连：重新要一个 portal node、连上流。
///
/// 不能先删 `portal.node` 再要：删的那一瞬间助手可能正好写进新 node，
/// 就被我们删掉了（它以为已经写完，不会再写第二次），于是这次恢复白等一场。
/// 改成给 `acquire_portal_node` 打 force：跳过缓存，只认这一轮之后新写出来的
/// node，文件本身不动。
pub async fn Store::recover_push_stream(self : Store, dir : String) -> Int32? {
  // 0 不是合法的 pipewire node，拿它当「这次没拿到」的标记
  let got = @async.with_timeout_opt(RECOVER_TIMEOUT_MS, async fn() {
    match acquire_portal_node(dir, force=true) {
      Some(node) => node
      None => 0
    }
  })
  match got {
    Some(node) =>
      if node > 0 && self.enable_pipewire(node) {
        Some(node)
      } else {
        None
      }
    None => None
  }
}

///|
/// 光标坐标文件的位置。由 `screen-kacha-cursor` 写，这里只读。
/// 用 runtime 目录：重启就清掉，本来就是瞬时状态。
pub fn Store::cursor_pos_path(self : Store) -> String {
  let _ = self
  let rt = match @env.get_env_var("XDG_RUNTIME_DIR") {
    Some(v) => v
    None => "/tmp"
  }
  "\{rt}/screen-kacha/cursor.pos"
}

///|
/// PipeWire 原始帧（BGRA）的路径和尺寸。
///
/// 缩放请求可以直接从原始像素重新编码，省掉「先编码成 JPEG、
/// 再解码回来缩放」这一来一回。
pub fn Store::pw_raw(self : Store) -> (String, Int32, Int32)? {
  if !(self.src is Pipewire) {
    return None
  }
  // 用抓帧时记下的尺寸，不要再现场问 C 侧。
  //
  // 现场问的话，拿到的可能是「下一帧」的尺寸，而文件里躺的是上一帧的
  // 像素，改分辨率的那一瞬间就会按错的尺寸去解，出花屏。
  // 尺寸和像素必须在同一时刻确定下来，这里就是那个「同一时刻」的结果。
  match self.pw_state.raw_frame {
    Some((path, w, h)) => if w > 0 && h > 0 { Some((path, w, h)) } else { None }
    None => None
  }
}

///|
/// 帧目录上的实例锁。返回是否拿到。
///
/// 拿到锁说明本机没有别的 screen-kacha 在跑；拿不到就该干净退出，
/// 而不是换个端口再起一份去抢同一份帧目录。见 pid_stub.c 里的注释。
pub fn acquire_instance_lock(dir : String) -> Bool {
  lock_instance(@util.cstr(dir)) == 1
}

///|
#borrow(dir)
extern "c" fn lock_instance(dir : Bytes) -> Int32 = "moonbit_instance_lock"
