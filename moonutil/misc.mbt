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
