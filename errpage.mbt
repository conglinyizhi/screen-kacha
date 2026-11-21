///|
/// 出错兜底页：托盘在极端情况下（拿不到对话框、也没有通知）会打开这一页。
///
/// URL 只接受一个 `code`，正文从这张固定表里查。不接收任意文本，所以没有注入面。
/// 早先想过 `body=...&hash=md5(...)`，但裸 hash 谁都能算，等于没有校验。
fn err_page(code : String) -> String {
  let (title, body) = match code {
    "sysunit" =>
      (
        "无法用托盘管理开机启动", "检测到系统级（非 --user）的同名 systemd unit。托盘只能用 systemctl --user 管理用户级 unit，对系统级无效，请用 sudo systemctl 自行处理。",
      )
    "boot" =>
      (
        "开机启动设置失败", "调用 systemctl 失败了。可以用 journalctl --user -xe 看看具体原因。",
      )
    "access" =>
      (
        "访问控制设置失败", "写入配置文件或重启服务失败。检查 ~/.config/screenstream-mb/ 是否可写。",
      )
    "service" =>
      (
        "服务操作失败", "systemctl 调用返回了非零退出码。可以用 systemctl --user status screenstream-mb 看看状态。",
      )
    _ =>
      (
        "screenstream 出错了", "托盘遇到了一个没有预置说明的错误，请查看 journalctl --user -u screenstream-mb-tray 的日志。",
      )
  }
  let html = "<!doctype html><meta charset='utf-8'>"
  let html = html + "<title>" + title + "</title>"
  let html = html +
    "<style>body{font:16px/1.6 system-ui,sans-serif;max-width:38em;margin:12vh auto;padding:0 1.5em;color:#222}h1{font-size:1.4em;margin:0 0 .6em}p{color:#444}</style>"
  let html = html + "<h1>" + title + "</h1><p>" + body + "</p>"
  html
}
