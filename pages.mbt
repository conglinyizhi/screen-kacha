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
/// `/` 返回的外壳：一段给 LLM 的纯文本 + 一个外链脚本。
///
/// 界面本体在 `/for_human_use_browser.js` 里，由 JS 画出来。这样：
///
/// - 不执行 JS 的客户端（LLM、curl、agent）永远不下载那 15 KB 界面，
///   只拿到这段说明文字
/// - 浏览器照常看到完整界面
/// - 只有一个 URL，没有跳转，地址栏停在 `/`
///
/// 界面插在 `#for_llm` 前面，所以那段原始文本落在页面最下方，
/// 人想确认「机器看到的是什么」，滚到底就能看见。
let index_shell : String =
  $|<!doctype html><meta charset="utf-8">
  $|<meta name="viewport" content="width=device-width, initial-scale=1">
  $|<title>screen-kacha</title>
  $|<script defer src="/for_human_use_browser.js"></script>
  $|<div id="for_llm">
  $|<pre>screen-kacha — 本机屏幕快照服务
  $|
  $|界面由 /for_human_use_browser.js 渲染，不执行 JS 的客户端只会看到这段文字。
  $|程序或 LLM 请读 /llms.txt（端点索引和参数说明）。
  $|</pre></div>

///|
let fallback_human_js : String =
  $|(() => {
  $|  document.body.insertAdjacentHTML('afterbegin',
  $|    '<div style="font:15px system-ui;padding:2em">' +
  $|    '<h1>screen-kacha</h1>' +
  $|    '<p>界面文件 human.html 读不到，端点仍然可用：</p>' +
  $|    '<ul>' +
  $|    '<li><a href="/snapshot.jpg">/snapshot.jpg</a> 当前画面</li>' +
  $|    '<li><a href="/health">/health</a> 采集状态</li>' +
  $|    '<li><a href="/llms.txt">/llms.txt</a> 端点索引</li>' +
  $|    '<li><a href="/error.md">/error.md</a> 排查</li>' +
  $|    '</ul></div>');
  $|})();

///|
/// 把一段文本转义成能安全放进 JS 模板字符串的形式。
///
/// 只处理三种，顺序不能乱：
///
/// - `\` → `\\`   必须第一个处理，否则会把后面刚加上的转义符再转一遍
/// - `` ` `` → `` \` ``
/// - `${` → `\${`  不转的话会被当成插值，直接语法错误
fn escape_for_template_literal(src : String) -> String {
  let out = StringBuilder()
  let n = src.length()
  let mut i = 0
  while i < n {
    let c = src[i].to_int()
    if c == 92 {
      out.write_string("\\\\")
      i = i + 1
    } else if c == 96 {
      out.write_string("\\`")
      i = i + 1
    } else if c == 36 && i + 1 < n && src[i + 1].to_int() == 123 {
      out.write_string("\\${")
      i = i + 2
    } else {
      out.write_char(c.unsafe_to_char())
      i = i + 1
    }
  }
  out.to_string()
}

///|
/// 把整页 human.html 包成一段 JS。
///
/// 关键点在 `createContextualFragment`：`innerHTML` 插入的内联 `<script>`
/// 不会执行，而 `createContextualFragment` 会（实测确认过）。
/// 所以整页可以原样塞进模板字符串，不用把 `<script>` 拆出来单独跑。
/// 少一层脆弱的字符串切分。
fn wrap_human_js(page : String) -> String {
  "(() => {\n" +
  "  // 兜底：正常情况下 <script defer> 会等 DOM 解析完再执行。\n" +
  "  if (!document.body) {\n" +
  "    document.addEventListener('DOMContentLoaded', () => location.reload(), { once: true });\n" +
  "    return;\n" +
  "  }\n" +
  "  const PAGE = `" +
  escape_for_template_literal(page) +
  "`;\n" +
  "  // 用 createContextualFragment 而不是 innerHTML：\n" +
  "  // 后者不会执行页面里的 <script>。\n" +
  "  const frag = document.createRange().createContextualFragment(PAGE);\n" +
  "  // 插到 #for_llm 前面：界面在上，给 LLM 的原始文本留在页面最下方。\n" +
  "  const anchor = document.getElementById('for_llm');\n" +
  "  if (anchor) {\n" +
  "    document.body.insertBefore(frag, anchor);\n" +
  "  } else {\n" +
  "    document.body.prepend(frag);\n" +
  "  }\n" +
  "  // <pre> 默认不换行，窄屏会把底部那段文本右侧切掉。\n" +
  "  // 样式写在这里而不是塞进外壳的 HTML：那个 <pre> 是给 LLM 读的\n" +
  "  // 纯文本，不该混进 style 属性。\n" +
  "  const pre = document.querySelector('#for_llm > pre');\n" +
  "  if (pre) {\n" +
  "    pre.style.cssText = 'white-space:pre-wrap;overflow-wrap:anywhere';\n" +
  "  }\n" +
  "})();\n"
}

///|
/// 给人用的界面本体。读磁盘上的 for_human_use_browser.js
/// （可以改，改完不用重编），读不到就用编进二进制的兜底。
///
/// 它只被 `index_shell` 里那个 `<script src>` 拉起。不执行 JS 的客户端
/// LLM、curl、agent 都不会请求它，也就不会下载这十几 KB。
async fn handle_human_js(store : Store, port : Int32) -> @crescent.HttpResponse {
  let path = store.data_path("human.html")
  let page = try {
    let f = @fs.open(path, mode=ReadOnly)
    let t = f.read_all().text()
    f.close()
    Some(t)
  } catch {
    _ => {
      // 兜底外壳和真页面从外面分不出来，留一行日志
      if store.note_missing_doc("human.html") {
        eprintln("读不到 \{path}，页面退回内置兜底")
      }
      None
    }
  }
  let body = match page {
    Some(t) =>
      if t == "" {
        fallback_human_js
      } else {
        wrap_human_js(fill_port(t, port))
      }
    None => fallback_human_js
  }
  make_res(
    @crescent.StatusCode::OK,
    "application/javascript; charset=utf-8",
    @utf8.encode(body),
  )
}

///|
let fallback_skill : String =
  $|# screen-kacha
  $|
  $|GET /snapshot.jpg 原图，GET /snapshot-1280.jpg 缩到宽 1280，
  $|GET /snapshot-1280.webp 输出 WebP，GET /health 采集状态。
  $|出错排查见 /error.md。

///|
/// 把文档里的 {{PORT}} 换成实际端口。
///
/// 这些文档是运行时读的，例子写着 `curl 127.0.0.1:8930/health` 这种具体地址。
/// 端口被占时会往上挪，写死的例子就把人指到错的地方 —— 而出错的时候正好是最
/// 需要正确地址的时候。
pub fn fill_port(text : String, port : Int32) -> String {
  if !text.contains("{{PORT}}") {
    return text
  }
  text.replace_all(old="{{PORT}}", new=port.to_string())
}

///|
let fallback_error : String =
  $|# 出错了怎么查
  $|
  $|先看服务活着没有：curl -s http://127.0.0.1:{{PORT}}/health
  $|托盘的问题看：cat ~/.local/state/screen-kacha/last-error.txt
  $|日志：journalctl --user -u screen-kacha -u screen-kacha-tray -n 100 --no-pager
  $|完整的排查步骤在磁盘上的 error.md。

///|
/// 文本类静态文件：磁盘上有就用磁盘的（可改），没有就用编进二进制的兜底。
async fn handle_text_file(
  store : Store,
  name : String,
  ctype : String,
  fallback : String,
  port : Int32,
) -> @crescent.HttpResponse {
  let path = store.data_path(name)
  let text = try {
    let f = @fs.open(path, mode=ReadOnly)
    let s = f.read_all().text()
    f.close()
    s
  } catch {
    _ => {
      // 内置兜底和真文件从外面完全分不出来，所以至少留一行日志。
      // 同一个文件只报第一次：agent 会反复拉这些文档。
      if store.note_missing_doc(name) {
        eprintln("读不到 \{path}，改用内置兜底文案")
      }
      fallback
    }
  }
  make_res(@crescent.StatusCode::OK, ctype, @utf8.encode(fill_port(text, port)))
}

///|
/// 404 回纯文本：地址错、链路通、指向 skill.md
pub fn not_found_text(path : String) -> String {
  "404 路径不存在：\{path}\n\n地址写错了，但服务器是通的，问题只出在路径上。\n用法说明在 /skill.md。\n"
}

///|
let fallback_robots : String = "User-agent: *\nDisallow: /\n"

///|
let fallback_llms : String = "# screen-kacha\n\n> 本机屏幕的 HTTP 快照服务。\n\n- /snapshot.jpg\n- /health\n- /skill.md\n"
