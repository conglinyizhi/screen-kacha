///|
let page_html : String =
  $|<!doctype html>
  $|<html lang="zh-CN"><head><meta charset="utf-8">
  $|<title>screenstream</title>
  $|<style>body{margin:0;background:#111;color:#bbb;font:14px system-ui}
  $|header{padding:8px 12px}img{display:block;width:100%}</style></head><body>
  $|<header><strong>屏幕画面</strong> <a href="/skill.md">/skill.md</a></header>
  $|<img id="v" alt="等待画面">
  $|<script>setInterval(()=>{document.getElementById('v').src='/snapshot.jpg?t='+Date.now()},2000)</script>
  $|</body></html>

///|
let fallback_skill : String =
  $|# screenstream
  $|
  $|GET /snapshot.jpg 原图，GET /snapshot-1280.jpg 缩到宽 1280，
  $|GET /snapshot-1280.webp 输出 WebP，GET /health 采集状态。

///|
/// 文本类静态文件：磁盘上有就用磁盘的（可改），没有就用编进二进制的兜底。
async fn handle_text_file(
  name : String,
  ctype : String,
  fallback : String,
) -> @crescent.HttpResponse {
  let text = try {
    let f = @fs.open(name, mode=ReadOnly)
    let s = f.read_all().text()
    f.close()
    s
  } catch {
    _ => fallback
  }
  make_res(@crescent.StatusCode::OK, ctype, @utf8.encode(text))
}

///|
/// 404 回纯文本：地址错、链路通、指向 skill.md
pub fn not_found_text(path : String) -> String {
  "404 路径不存在：\{path}\n\n地址写错了，但服务器是通的，问题只出在路径上。\n用法说明在 /skill.md。\n"
}

///|
let fallback_robots : String = "User-agent: *\nDisallow: /\n"

///|
let fallback_llms : String = "# screenstream\n\n> 本机屏幕的 HTTP 快照服务。\n\n- /snapshot.jpg\n- /health\n- /skill.md\n"
