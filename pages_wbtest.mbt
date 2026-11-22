///|
/// 模板字符串的转义是最容易埋雷的地方：漏一个就整段 JS 语法错误，
/// 而错误只会在浏览器里以「白屏」的形式出现。
test "反引号被转义" {
  assert_eq(escape_for_template_literal("a`b"), "a\\`b")
}

///|
test "美元加大括号被转义，单独的美元不动" {
  // `${` 不转的话会被当成插值，直接语法错误
  assert_eq(escape_for_template_literal("a${b}c"), "a\\${b}c")
  // 单独的 $ 没有风险，不该被改
  assert_eq(escape_for_template_literal("$5 和 $$"), "$5 和 $$")
}

///|
test "反斜杠先转，不会把后面加的转义符再转一遍" {
  // 输入是一个反斜杠，输出必须是两个
  assert_eq(escape_for_template_literal("a\\b"), "a\\\\b")
  // 反斜杠 + 反引号：各转各的
  assert_eq(escape_for_template_literal("\\`"), "\\\\\\`")
}

///|
test "普通 HTML 原样不动" {
  let h = "<div class=\"x\">中文 & 符号</div>"
  assert_eq(escape_for_template_literal(h), h)
}

///|
test "混合内容" {
  assert_eq(escape_for_template_literal("`${x}`"), "\\`\\${x}\\`")
}

///|
test "包装出来的 JS 带上了关键部分" {
  let js = wrap_human_js("<p>hi</p>")
  // 页面本体在里面
  assert_true(js.contains("<p>hi</p>"))
  // 用 createContextualFragment 而不是 innerHTML（后者不执行 <script>）
  assert_true(js.contains("createContextualFragment"))
  assert_false(js.contains("innerHTML = PAGE"))
  // 插到 for_llm 前面
  assert_true(js.contains("getElementById('for_llm')"))
  assert_true(js.contains("insertBefore"))
}
