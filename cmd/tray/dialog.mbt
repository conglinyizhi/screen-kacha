///|
/// 同步跑一条命令，返回退出码；-1 表示连 shell 都没起来。
#borrow(cmd)
extern "c" fn run_status_raw(cmd : Bytes) -> Int32 = "moonbit_screen_kacha_run_status"

///|
fn run_status(cmd : String) -> Int32 {
  run_status_raw(@util.cstr(cmd))
}

///|
/// 出错时怎么让人知道。
///
/// 顺序：KDE 的原生对话框 → 通知 → 兜底网页。
///
/// 网页只做最后一道，因为「服务起不来」本身就是常见错误，那时候
/// :8930 也打不开，只能靠前两种。
///
/// 网页不接收任意文本：只带一个错误**代号**，正文由服务端内置。
/// 早先想传 body + hash 校验，但裸 hash 谁都能算，拦不住注入；
/// 而正文如果只从固定表里查，注入面直接消失。

///|
/// 这条命令能不能用。
fn has(cmd : String) -> Bool {
  run_status("command -v \{cmd} >/dev/null 2>&1") == 0
}

///|
/// 出错记录落在哪。
fn error_log_path() -> String {
  match @env.get_env_var("HOME") {
    Some(h) => "\{h}/.local/state/screen-kacha/last-error.txt"
    None => "/tmp/screen-kacha-last-error.txt"
  }
}

///|
/// 把一次失败写进记录文件（最新的在最上面，只留最近 40 行）。
///
/// 为什么不靠 journal：用户不一定会翻 `journalctl --user`，但
/// `cat` 一个固定路径谁都会。`/error.md` 里也是让人先看这个文件。
fn record_error(action : String, detail : String) -> Unit {
  let stamp = capture("date '+%Y-%m-%d %H:%M:%S'", 64)
  let when = stamp.trim().to_owned()
  let head = "[\{when}] \{action}\n  \{detail}\n"
  let old = capture("head -40 '\{error_log_path()}' 2>/dev/null", 8192)
  let _ = write_file(error_log_path(), head + old)
}

///|
/// 弹一个错误框，并先把这次失败记下来。
///
/// 对话框一律**异步**拉起：这里是同步的托盘主循环，同步等对话框关闭会把
/// 图标刷新和所有菜单项一起冻住，用户读到一半就发现托盘死了。
/// 所以不做「弹不出来就试下一个」，改成先用 `command -v` 问在不在，
/// 在就直接拉起。
///
/// `code` 是给兜底网页用的短代号，`title/body` 是给人看的。
pub fn alert(title : String, body : String, code : String) -> Unit {
  record_error(title, body)
  if has("kdialog") {
    sh("kdialog --title '\{title}' --error '\{body}'")
    return
  }
  if has("zenity") {
    sh("zenity --error --title='\{title}' --text='\{body}'")
    return
  }
  if has("notify-send") {
    sh("notify-send -u critical -a screen-kacha '\{title}' '\{body}'")
    return
  }
  // 最后兜底：让本机服务渲染一个固定文案的错误页
  sh("xdg-open 'http://127.0.0.1:8930/ui/err?code=\{code}'")
}

///|
/// 普通提示框：告诉用户一件事，不写错误记录。
///
/// 和 `alert` 的区别是它不调用 `record_error`。用 `alert` 做说明会把
/// 正常操作写进错误日志，之后排查真问题就被这些噪音埋了。
pub fn inform(title : String, body : String) -> Unit {
  if has("kdialog") {
    sh("kdialog --title '\{title}' --msgbox '\{body}'")
    return
  }
  if has("zenity") {
    sh("zenity --info --title='\{title}' --text='\{body}'")
    return
  }
  if has("notify-send") {
    sh("notify-send -a screen-kacha '\{title}' '\{body}'")
  }
}

///|
/// 系统级（非 --user）有没有同名的 unit。
///
/// 有的话，托盘用 `systemctl --user` 是管不到它的：点击开机启动会静默无效，
/// 用户只会觉得「点了没反应」。所以要先说清楚，让人自己用 sudo 处理。
pub fn system_unit_conflict() -> Bool {
  let out = capture(
    "systemctl list-unit-files 'screen-kacha*' --no-pager 2>/dev/null | grep -c screen-kacha",
    256,
  )
  @util.parse_int(out.trim(), 0) > 0
}
