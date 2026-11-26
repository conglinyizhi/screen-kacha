///|
/// MoonBit 字符串 → 带结尾 0 的 C 字符串。
///
/// 这个文件里三样东西原来是每个包各抄一份：`cstr` 五份、`parse_int` 三份、
/// `pick` 两份。抄得越多，改一处漏三处的机会越大。
pub fn cstr(s : String) -> Bytes {
  let src = @utf8.encode(s)
  let n = src.length()
  Bytes::makei(n + 1, fn(i) { if i < n { src[i] } else { 0 } })
}

///|
/// 解析十进制整数，非法返回默认值。
///
/// 严格：空串、带符号、夹了别的东西一律算非法。命令行参数写错了就该退回
/// 默认值，而不是把 `12a` 读成 `12`。
pub fn parse_int(s : StringView, dflt : Int32) -> Int32 {
  if s.length() == 0 {
    return dflt
  }
  let mut n = 0
  for i in 0..<s.length() {
    let c = s[i]
    guard c >= 48 && c <= 57 else { return dflt }
    n = n * 10 + (c.to_int() - 48)
  }
  n
}

///|
/// 从命令行匹配结果里取选项值，没给就用默认值。
pub fn pick(m : @argparse.Matches, name : String, dflt : String) -> String {
  match m.values.get(name) {
    Some([v, ..]) => v
    _ => dflt
  }
}

///|
/// 标准 base64 编码。
///
/// MCP 的图片内容块要 base64 字符串，生成器那边也要用同一份实现。
pub fn b64_encode(data : Bytes) -> String {
  let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  let out = StringBuilder()
  let n = data.length()
  let mut i = 0
  while i + 2 < n {
    let b0 = data[i].to_int()
    let b1 = data[i + 1].to_int()
    let b2 = data[i + 2].to_int()
    out.write_char(alphabet[(b0 >> 2) & 63].unsafe_to_char())
    out.write_char(alphabet[((b0 & 3) << 4) | (b1 >> 4)].unsafe_to_char())
    out.write_char(alphabet[((b1 & 15) << 2) | (b2 >> 6)].unsafe_to_char())
    out.write_char(alphabet[b2 & 63].unsafe_to_char())
    i = i + 3
  }
  let rest = n - i
  if rest == 1 {
    let b0 = data[i].to_int()
    out.write_char(alphabet[(b0 >> 2) & 63].unsafe_to_char())
    out.write_char(alphabet[(b0 & 3) << 4].unsafe_to_char())
    out.write_char('=')
    out.write_char('=')
  } else if rest == 2 {
    let b0 = data[i].to_int()
    let b1 = data[i + 1].to_int()
    out.write_char(alphabet[(b0 >> 2) & 63].unsafe_to_char())
    out.write_char(alphabet[((b0 & 3) << 4) | (b1 >> 4)].unsafe_to_char())
    out.write_char(alphabet[(b1 & 15) << 2].unsafe_to_char())
    out.write_char('=')
  }
  out.to_string()
}

///|
/// screen-kacha 使用的用户路径。CLI 显式路径（如 --shm、--data、--access）不在这里。
pub struct RuntimePaths {
  state_dir : String?
  access_conf : String
  runtime_dir : String
  app_runtime_dir : String
}

///|
/// 用户状态目录：`$XDG_STATE_HOME/screen-kacha`，否则 `$HOME/.local/state/screen-kacha`。
///
/// 拿不到就返回 None。**不要**在这里再编一个 `/tmp` 兜底：多一份文件就多一个
/// 排查时看错的地方，不如干脆不写，界面上照常显示这次的错误。
pub fn state_dir_with(xdg : String?, home : String?) -> String? {
  match xdg {
    Some(v) => if v == "" { None } else { Some("\{v}/screen-kacha") }
    None =>
      match home {
        Some(h) =>
          if h == "" {
            None
          } else {
            Some("\{h}/.local/state/screen-kacha")
          }
        None => None
      }
  }
}

///|
pub fn runtime_dir_with(xdg : String?, uid : Int32) -> String {
  match xdg {
    Some(v) => if v == "" { "/run/user/\{uid}" } else { v }
    None => "/run/user/\{uid}"
  }
}

///|
pub fn runtime_paths_with(
  xdg_state : String?,
  xdg_config : String?,
  xdg_runtime : String?,
  home : String?,
  uid : Int32,
) -> RuntimePaths {
  let state_dir = state_dir_with(xdg_state, home)
  let runtime_dir = runtime_dir_with(xdg_runtime, uid)
  {
    state_dir,
    access_conf: access_conf_path_with(xdg_config, home),
    runtime_dir,
    app_runtime_dir: "\{runtime_dir}/screen-kacha",
  }
}

///|
extern "c" fn current_uid_raw() -> Int32 = "moonbit_util_current_uid"

///|
pub fn current_uid() -> Int32 {
  current_uid_raw()
}

///|
pub fn runtime_paths() -> RuntimePaths {
  runtime_paths_with(
    @env.get_env_var("XDG_STATE_HOME"),
    @env.get_env_var("XDG_CONFIG_HOME"),
    @env.get_env_var("XDG_RUNTIME_DIR"),
    @env.get_env_var("HOME"),
    current_uid(),
  )
}

///|
pub fn state_dir() -> String? {
  runtime_paths().state_dir
}

///|
fn valid_instance_name(name : String) -> Bool {
  if name == "" || name.length() > 64 {
    return false
  }
  for i = 0; i < name.length(); i = i + 1 {
    let c = name[i].to_int()
    if !((c >= 48 && c <= 57) ||
      (c >= 65 && c <= 90) ||
      (c >= 97 && c <= 122) ||
      c == 45 ||
      c == 95 ||
      c == 46) {
      return false
    }
  }
  name != "." && name != ".."
}

///|
pub fn instance_state_dir_with(
  xdg_state : String?,
  home : String?,
  instance : String?,
) -> String? {
  let name = match instance {
    Some(v) => v
    None => "default"
  }
  if !valid_instance_name(name) {
    return None
  }
  match state_dir_with(xdg_state, home) {
    // 默认实例继续使用旧目录，升级后托盘仍能发现端口、portal 状态和错误记录。
    Some(dir) =>
      if name == "default" {
        Some(dir)
      } else {
        Some("\{dir}/instances/\{name}")
      }
    None => None
  }
}

///|
pub fn instance_state_dir(instance : String) -> String? {
  instance_state_dir_with(
    @env.get_env_var("XDG_STATE_HOME"),
    @env.get_env_var("HOME"),
    Some(instance),
  )
}

///|

///|
/// 出错记录文件的位置。只有这一份，不存在第二个。
pub fn error_log_path() -> String? {
  match state_dir() {
    Some(d) => Some("\{d}/last-error.txt")
    None => None
  }
}

///|
pub fn instance_error_log_path(instance : String) -> String? {
  match instance_state_dir(instance) {
    Some(d) => Some("\{d}/last-error.txt")
    None => None
  }
}

///|
/// 当前时间：自 epoch 的毫秒数。
///
/// 托盘和服务要拿同一个时钟比「心跳过去多久了」。托盘是同步循环，用不了
/// async 包里的 `@async.now()`；两边都调这一个函数，就不可能出现
/// 「一边写 CLOCK_MONOTONIC、一边读墙上时钟」那种负值。
///
/// 底层是 `@env.now()`，和 `@async.now()` 同一个来源（epoch 毫秒）。
pub fn now_ms() -> Int64 {
  @env.now().reinterpret_as_int64()
}

///|
/// 访问控制配置文件的路径。
///
/// 认 `XDG_CONFIG_HOME`：服务读、托盘写，两边必须算到同一个路径，所以这段
/// 逻辑只能有一份。
pub fn access_conf_path_with(xdg : String?, home : String?) -> String {
  match xdg {
    Some(v) =>
      if v != "" {
        "\{v}/screen-kacha/access.conf"
      } else {
        access_conf_path_with(None, home)
      }
    None =>
      match home {
        Some(h) =>
          if h == "" {
            ""
          } else {
            "\{h}/.config/screen-kacha/access.conf"
          }
        None => "/etc/screen-kacha/access.conf"
      }
  }
}

///|
pub fn access_conf_path() -> String {
  runtime_paths().access_conf
}

///|
/// 配置里的布尔值。大小写不敏感，认 true/1/yes/on。
///
/// 服务和托盘原来各有一份实现（`parse_flag_value` 和 `flag_value`），
/// 规则一样、名字不同，改一处忘另一处就是两边行为分叉。
pub fn parse_flag(v : String) -> Bool {
  let s = v.trim()
  if s.length() == 0 {
    return false
  }
  // 小写化：只处理 ASCII，配置里的键值不会有别的字母
  let buf = StringBuilder()
  let mut i = 0
  while i < s.length() {
    let c = s[i].to_int()
    buf.write_char(
      if c >= 65 && c <= 90 {
        (c + 32).unsafe_to_char()
      } else {
        s[i].unsafe_to_char()
      },
    )
    i = i + 1
  }
  let t = buf.to_string()
  t == "true" || t == "1" || t == "yes" || t == "on"
}
