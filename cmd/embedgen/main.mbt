///|
/// 把指定的几个文件打成 base64，生成一张路径 → 数据的表。
///
/// 参数：`moon run cmd/embedgen -- <输出文件> <输入文件>...`
///
/// 只收显式列出的文件，不扫目录：仓库根目录里塞满了几十种东西，扫目录会把
/// README、截图、脚本全带进二进制。
async fn main {
  let args = @env.args()
  if args.length() < 3 {
    eprintln("usage: moon run cmd/embedgen -- <out.mbt> <file>...")
    return
  }
  let output = args[1]
  let lines : Array[String] = [
    "// 由 cmd/embedgen 生成，不要手改。", "// 改了文档或光标素材之后跑：moon run cmd/embedgen -- embedded_gen.mbt <文件>...",
    "", "pub let emb_paths : Array[String] = [",
  ]
  let mut i = 2
  while i < args.length() {
    let path = args[i]
    let name = base_name(path)
    lines.push("  \"/\{name}\",")
    i = i + 1
  }
  lines.push("]")
  lines.push("")
  lines.push("pub let emb_data : Array[String] = [")
  i = 2
  let mut failed = false
  while i < args.length() {
    let path = args[i]
    let bytes = Some(@fs.read_file(path).binary()) catch { _ => None }
    match bytes {
      Some(raw) => lines.push("  \"\{b64(raw)}\",")
      None => {
        eprintln("读不到 \{path}")
        failed = true
      }
    }
    i = i + 1
  }
  lines.push("]")
  lines.push("")
  if failed {
    eprintln("有文件读不出来，不生成")
    return
  }
  let wrote = try {
    @fs.write_file(
      output,
      @utf8.encode(lines.join("\n")),
      create_mode=CreateOrTruncate,
    )
    true
  } catch {
    e => {
      eprintln("写不出 \{output}：\{e}")
      false
    }
  }
  if !wrote {
    return
  }
  println("生成 \{output}：\{args.length() - 2} 个文件")
}

///|
/// 取路径最后一段。嵌进去的键就是文件名，运行时按名字查。
fn base_name(path : String) -> String {
  let mut start = 0
  let mut i = 0
  while i < path.length() {
    if path[i] == '/' {
      start = i + 1
    }
    i = i + 1
  }
  path[start:].to_owned()
}

///|
/// 标准 base64 编码。
///
/// 自己写而不是用 moonbitlang/x：那会把 x 变成生成器的直接依赖，而生成器只是
/// 构建期的工具，没必要为此多一条依赖边。运行时解码仍然由 moon-embed 负责。
fn b64(data : Bytes) -> String {
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
