#!/usr/bin/env bash
# install.sh 的两处坑，能在 CI 里静态验：
#   1. Wayland socket 选择不能选中 *.lock / *sock
#   2. 卸载要收掉当前命名的 helper 和它的状态文件
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
NAMES="$ROOT/contrib/screen-kacha-names.sh"
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
grep -q 'SCREEN_KACHA_PROCESSES' "$ROOT/install.sh" \
  && ok || bad "卸载没有从命名表停止 helper"
grep -q 'XDG_STATE_HOME.*screen-kacha' "$ROOT/install.sh" \
  && ok || bad "卸载没有使用 XDG_STATE_HOME 清理状态文件"
grep -q 'portal.token' "$ROOT/install.sh" \
  && ok || bad "卸载没有清 portal.token"

# 已改名的 portal loop 不能作为可执行旧模板留在 contrib。
if [ -e "$ROOT/contrib/screenstream-portal-loop" ]; then
  bad "contrib 仍有旧名称的 portal loop"
else
  ok
fi

# install 和卸载必须消费同一份产物命名表；避免安装名、卸载名和检查规则漂移。
if [ ! -f "$NAMES" ]; then
  bad "缺少共享的 screen-kacha 产物命名表"
else
  # shellcheck disable=SC1090
  . "$NAMES"
  [ -n "${SCREEN_KACHA_BINARIES+x}" ] \
    && grep -q 'screen-kacha-names.sh' "$ROOT/install.sh" \
    && ok || bad "install.sh 没有使用共享命名表"
  [ -n "${SCREEN_KACHA_PROCESSES+x}" ] \
    && [ -n "${SCREEN_KACHA_UNIT_TEMPLATES+x}" ] \
    && [ -n "${SCREEN_KACHA_INSTANCE_UNIT_TEMPLATES+x}" ] \
    && [ -n "${SCREEN_KACHA_PORTAL_LOOP+x}" ] \
    && ok || bad "命名表缺少 helper、unit 或 portal loop"
  [[ " ${SCREEN_KACHA_PROCESSES[*]} " == *" screen-kacha-portal-loop "* ]] \
    && [[ " ${SCREEN_KACHA_PROCESSES[*]} " == *" screen-kacha-portal --out "* ]] \
    && [[ " ${SCREEN_KACHA_PROCESSES[*]} " == *" screen-kacha-cursor "* ]] \
    && ok || bad "命名表没有列齐卸载要停止的进程"
  [ "${#SCREEN_KACHA_INSTANCE_UNIT_TEMPLATES[@]}" -eq 1 ] \
    && [[ " ${SCREEN_KACHA_INSTANCE_UNIT_TEMPLATES[*]} " == *" screen-kacha.service.in:screen-kacha-@INSTANCE@.service "* ]] \
    && ok || bad "named instance 必须只创建独立主服务 unit，不创建第二个托盘"
fi

grep -q 'INSTANCE=.*default' "$ROOT/install.sh" \
  && grep -q 'portal-dir %t/screen-kacha' "$ROOT/contrib/screen-kacha.service.in" \
  && grep -q 'screen-kacha-@INSTANCE@.service' "$NAMES" \
  && ok || bad "named instance 没有隔离 unit/state 或共享 portal 目录约定"

# 运行代码与当前部署模板中不得再残留 Python 项目旧名。
if grep -R -i -n 'screenstream' \
  "$ROOT/install.sh" "$ROOT/contrib" "$ROOT/cmd" "$ROOT/moonutil" \
  "$ROOT/portal_proc.mbt" "$ROOT/store.mbt"; then
  bad "运行代码或部署文件仍含旧项目名 screenstream"
else
  ok
fi

echo
echo "通过 $PASS，失败 $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
