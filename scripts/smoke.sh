#!/usr/bin/env bash
# 端到端冒烟：用假帧源起一个临时实例，把 HTTP 全链路走一遍。
# 不需要显示器、不需要 spectacle，也不会碰正在运行的服务。
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 1

PORT=${PORT:-$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')}
WORK=$(mktemp -d)
PORT_LOG="$WORK/server.log"
PASS=0
FAIL=0

cleanup() {
  [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

check() { # 描述 期望 实际
  if [ "$2" = "$3" ]; then ok; else bad "$1（期望 $2，实际 $3）"; fi
}

echo "== 准备假帧 =="
magick -size 800x600 xc:'#2b6cb0' -fill white -pointsize 48 -gravity center -annotate 0 'smoke' "$WORK/frame.png" 2>/dev/null
[ -s "$WORK/frame.png" ] || { echo "  造图失败"; exit 1; }

echo "== 起实例（端口 $PORT，假帧源）=="
./_build/native/debug/build/cmd/main/main.exe \
  --port "$PORT" --bind 127.0.0.1 --pump 100 \
  --shm "$WORK/shm" --fake "$WORK/frame.png" \
  ${ACCESS_CONF:+--access "$ACCESS_CONF"} >"$PORT_LOG" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 50); do
  curl -sf --max-time 1 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break
  sleep 0.1
done

B="http://127.0.0.1:$PORT"
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$1"; }
ctype() { curl -s -o /dev/null -w '%{content_type}' --max-time 10 "$1"; }
dims() { curl -s --max-time 10 "$1" -o "$WORK/out.bin" && magick identify -format '%wx%h' "$WORK/out.bin" 2>/dev/null; }

echo "== 路由与类型 =="
check "/ 状态" 200 "$(code $B/)"
check "/ 类型" "text/html; charset=utf-8" "$(ctype $B/)"
check "/health 状态" 200 "$(code $B/health)"
check "/health 类型" "application/json" "$(ctype $B/health)"
check "/skill.md 类型" "text/markdown; charset=utf-8" "$(ctype $B/skill.md)"
check "/robots.txt 状态" 200 "$(code $B/robots.txt)"
check "/robots.txt 类型" "text/plain; charset=utf-8" "$(ctype $B/robots.txt)"
check "/llms.txt 状态" 200 "$(code $B/llms.txt)"
check "/nope 状态" 404 "$(code $B/nope)"
curl -s --max-time 5 $B/nope | grep -q "/skill.md" && ok || bad "404 文案没指向 skill.md"

echo "== 图像与缩放 =="
check "原图尺寸" "800x600" "$(dims $B/snapshot.jpg)"
check "缩放到 320" "320x240" "$(dims $B/snapshot-320.jpg)"
check "查询参数 w=640" "640x480" "$(dims "$B/snapshot.jpg?w=640")"
check "webp 类型" "image/webp" "$(ctype $B/snapshot-320.webp)"
check "非法快照名" 404 "$(code $B/snapshot.png)"

echo "== 帧龄与缓存 =="
sleep 0.5
T0=$(date +%s%N)
curl -s -o /dev/null --max-time 10 "$B/snapshot.jpg?age=5"
T1=$(date +%s%N)
MS=$(( (T1-T0)/1000000 ))
[ "$MS" -lt 200 ] && ok || bad "age=5 应命中缓存，实际 ${MS}ms"
HEALTH=$(curl -s --max-time 5 $B/health)
echo "$HEALTH" | grep -q '"ok": true' && ok || bad "health 的 ok 不是 true"
echo "$HEALTH" | grep -q '"fails": 0' && ok || bad "health 里 fails 不为 0"

echo "== 并发（应合并成一次采集）=="
BEFORE=$(curl -s --max-time 5 $B/health | grep -o '"count": [0-9]*' | grep -o '[0-9]*')
CPIDS=""
for _ in 1 2 3 4 5; do
  curl -s -o /dev/null --max-time 10 "$B/snapshot.jpg?age=0.001" &
  CPIDS="$CPIDS $!"
done
# 只等这几个 curl，别把服务进程也等进去
for p in $CPIDS; do wait "$p"; done
AFTER=$(curl -s --max-time 5 $B/health | grep -o '"count": [0-9]*' | grep -o '[0-9]*')
DELTA=$((AFTER - BEFORE))
[ "$DELTA" -le 5 ] && ok || bad "并发 5 次却采集了 $DELTA 次"

echo
echo "通过 $PASS，失败 $FAIL"
[ "$FAIL" -eq 0 ] || { echo "--- 服务日志 ---"; tail -20 "$PORT_LOG"; exit 1; }
