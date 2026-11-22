#!/usr/bin/env bash
# install.sh 的两处坑，能在 CI 里静态验：
#   1. Wayland socket 选择不能选中 *.lock / *sock
#   2. 卸载要收掉 portal 助手和它的状态文件
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PASS=0
FAIL=0
ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# --- 1) 把 install.sh 里的 pick_wayland_socket 抽出来真跑一遍 ---
SNIPPET=$(sed -n '/^pick_wayland_socket()/,/^}/p' "$ROOT/install.sh")
if [ -z "$SNIPPET" ]; then
  bad "install.sh 里找不到 pick_wayland_socket"
else
  eval "$SNIPPET"
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  # KWin 重启过一轮之后的样子：真有 socket 的是 wayland-2
  : > "$TMP/wayland-1.lock"
  : > "$TMP/wayland-2"
  : > "$TMP/wayland-cursor.sock"
  : > "$TMP/wayland-0.lock"
  picked=$(pick_wayland_socket "$TMP")
  [ "$picked" = "wayland-2" ] && ok || bad "Wayland socket 选错了：得到「$picked」，期望 wayland-2"

  # 只有 lock / sock 时必须选不出来（交给调用方报错退出），不能瞎猜一个
  EMPTY=$(mktemp -d)
  : > "$EMPTY/wayland-3.lock"
  : > "$EMPTY/wayland-cursor.sock"
  picked2=$(pick_wayland_socket "$EMPTY")
  rm -rf "$EMPTY"
  [ -z "$picked2" ] && ok || bad "只有 lock/sock 时不该选中任何东西，得到「$picked2」"
fi

# 老写法不能再回来（注释里提到它是允许的，只看真正执行的代码）
if grep -v '^[[:space:]]*#' "$ROOT/install.sh" | grep -q 'ls -1 wayland-\*'; then
  bad "install.sh 又用 ls wayland-* 选 socket 了"
else
  ok
fi

# --- 2) 卸载收尾 ---
grep -q "pkill -f '\[s\]creenstream-portal'" "$ROOT/install.sh" \
  && ok || bad "卸载没有收 portal 助手"
grep -q 'portal.token' "$ROOT/install.sh" \
  && ok || bad "卸载没有清 portal.token"
grep -q "pkill -f '\[s\]creenstream-cursor'" "$ROOT/install.sh" \
  && ok || bad "卸载没有收光标 helper"

echo
echo "通过 $PASS，失败 $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
