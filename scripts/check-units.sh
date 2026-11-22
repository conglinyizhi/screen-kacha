#!/usr/bin/env bash
# systemd unit 模板的静态检查。
#
# unit 文件没法在 CI 里真跑起来（要 systemd + 桌面会话），但 hardening 的
# 关键条目被谁顺手删掉是能查的。真机上的验证记录见 commit 说明。
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
MAIN="$ROOT/contrib/screen-kacha.service.in"
TRAY="$ROOT/contrib/screen-kacha-tray.service.in"
PASS=0
FAIL=0

ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

want() { # 文件 正则 描述
  grep -qE "$2" "$1" && ok || bad "$3"
}

for f in "$MAIN" "$TRAY"; do
  [ -f "$f" ] || { echo "缺文件：$f"; exit 1; }
done

# 两个 unit 都要：崩溃循环要停，异常退出要拉起
for f in "$MAIN" "$TRAY"; do
  want "$f" '^Restart=always$' "$(basename "$f")：缺 Restart=always"
  want "$f" '^StartLimitIntervalSec=300$' "$(basename "$f")：缺 StartLimitIntervalSec"
  want "$f" '^StartLimitBurst=6$' "$(basename "$f")：缺 StartLimitBurst"
  # 指数退避：固定间隔会在端口短暂被占时过早放弃
  want "$f" '^RestartSteps=5$' "$(basename "$f")：缺 RestartSteps"
  want "$f" '^RestartMaxDelaySec=60$' "$(basename "$f")：缺 RestartMaxDelaySec"
  want "$f" '^NoNewPrivileges=yes$' "$(basename "$f")：缺 NoNewPrivileges"
done

# 主服务多一层：文件系统与调用面的收缩
want "$MAIN" '^ProtectSystem=strict$' '主 unit：缺 ProtectSystem=strict'
want "$MAIN" '^ReadWritePaths=%t$' '主 unit：缺 ReadWritePaths=%t'
want "$MAIN" '^PrivateTmp=yes$' '主 unit：缺 PrivateTmp'
want "$MAIN" '^RestrictAddressFamilies=' '主 unit：缺 RestrictAddressFamilies'
want "$MAIN" '^CapabilityBoundingSet=$' '主 unit：缺空 CapabilityBoundingSet'
want "$MAIN" '^UMask=0077$' '主 unit：缺 UMask=0077'
want "$MAIN" '^LockPersonality=yes$' '主 unit：缺 LockPersonality'
# ProtectHome 故意没加：spectacle 要往 ~/.config、~/.local/share、~/.cache 写
# 东西，加上之后截不了图（真机验过）。哪天 spectacle 不再需要，可以再加。
grep -qE '^ProtectHome=' "$MAIN" \
  && bad "主 unit：加了 ProtectHome，spectacle 会截不了图（见注释）" \
  || ok

echo
echo "通过 $PASS，失败 $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
