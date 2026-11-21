///|
/// ASCII 小写。只为了不区分大小写地比较头部，不处理 Unicode。
fn ascii_lower(s : String) -> String {
  let buf = StringBuilder()
  for i = 0; i < s.length(); i = i + 1 {
    let c = s[i].to_int()
    if c >= 65 && c <= 90 {
      buf.write_char((c + 32).unsafe_to_char())
    } else {
      buf.write_char(c.unsafe_to_char())
    }
  }
  buf.to_string()
}

///|
/// 请求是不是浏览器发来的。
///
/// 浏览器一定会带 `Accept: text/html`；curl 默认 `*/*`，agent 往往什么都不带。
/// 这比看 User-Agent 可靠：UA 谁都能改，agent 的名字又五花八门。
pub fn wants_html(accept : String?) -> Bool {
  match accept {
    Some(a) => ascii_lower(a).contains("text/html")
    None => false
  }
}

///|
let fallback_human : String =
  $|<!doctype html><meta charset="utf-8"><title>screenstream</title>
  $|<body style="font:15px system-ui;padding:2em"><h1>screenstream</h1>
  $|<p>本机屏幕的 HTTP 快照服务。</p>
  $|<p>完整页面读不到，端点仍然可用：</p>
  $|<ul>
  $|<li><a href="/snapshot.jpg">/snapshot.jpg</a> 当前画面</li>
  $|<li><a href="/snapshot-1280.webp">/snapshot-1280.webp</a> 缩略 WebP</li>
  $|<li><a href="/health">/health</a> 采集状态</li>
  $|<li><a href="/skill.md">/skill.md</a> 用法</li>
  $|<li><a href="/error.md">/error.md</a> 排查</li>
  $|</ul></body>

///|
/// 给人看的页面：读磁盘上的 human.html（可以改，改完不用重编），
/// 读不到就用编进二进制的兜底。
async fn handle_human_page() -> @crescent.HttpResponse {
  handle_text_file("human.html", "text/html; charset=utf-8", fallback_human)
}

///|
let fallback_skill : String =
  $|# screenstream
  $|
  $|GET /snapshot.jpg 原图，GET /snapshot-1280.jpg 缩到宽 1280，
  $|GET /snapshot-1280.webp 输出 WebP，GET /health 采集状态。
  $|出错排查见 /error.md。

///|
let fallback_error : String =
  $|# 出错了怎么查
  $|
  $|先看服务活着没有：curl -s http://127.0.0.1:8930/health
  $|托盘的问题看：cat ~/.local/state/screenstream-mb/last-error.txt
  $|日志：journalctl --user -u screenstream-mb -u screenstream-mb-tray -n 100 --no-pager
  $|完整的排查步骤在磁盘上的 error.md。

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
