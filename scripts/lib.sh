#!/usr/bin/env bash
# 构建产物路径解析，被 smoke.sh、smoke-instances.sh、install.sh 共用。
#
# 没有工作区时产物落在
#   _build/<target>/<profile>/build/<包路径>/<名字>.exe
# 有 moon.work（临时顶替某个注册表依赖时会加）时，模块名会插进路径
#   _build/<target>/<profile>/build/<模块名>/<包路径>/<名字>.exe
# 两种都得认，脚本不该因为哪天加了工作区就改一遍。
#
# 模块名从 moon.mod 里读，不写死。

# sk_module_name <项目根>：打印 moon.mod 里声明的模块名
sk_module_name() {
  sed -n 's/^name *= *"\(.*\)"/\1/p' "$1/moon.mod" | head -1
}

# sk_build_root <项目根> <release|debug>：打印该 profile 下的 build 目录
sk_build_root() {
  local root="$1" profile="$2" module p
  module=$(sk_module_name "$root")
  for p in "$root/_build/native/$profile/build/$module" \
           "$root/_build/native/$profile/build"; do
    if [ -d "$p" ]; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

# sk_exe <项目根> <release|debug> <包路径，如 cmd/main>：打印可执行文件路径
sk_exe() {
  local base exe
  base=$(sk_build_root "$1" "$2") || return 1
  exe="$base/$3/$(basename "$3").exe"
  if [ ! -x "$exe" ]; then
    return 1
  fi
  echo "$exe"
}
