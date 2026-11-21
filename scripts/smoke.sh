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
  # 按本次的临时目录匹配命令行，服务和它拉起的 portal 助手都会命中。
  # 只杀 PID 不够：portal 助手是 spawn_orphan 起的，会自己脱离进程组，
  # 漏掉它会一直活着抢屏幕流，把生产实例从 pipewire 挤到 spectacle。
  pkill -9 -f "$WORK" 2>/dev/null
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
# timeout：即使外层把本脚本整个杀掉（ssh 断了、CI 取消、按了 Ctrl-C），
#          服务也会在 300 秒后自己退出，不会变成抢屏幕流的孤儿进程。
timeout 300 ./_build/native/debug/build/cmd/main/main.exe \
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
# curl 不带 Accept: text/html，所以 / 应该回 llms.txt 原文而不是页面
check "/ 给 agent 的类型" "text/plain; charset=utf-8" "$(ctype $B/)"
curl -s --max-time 5 $B/ | grep -q "/snapshot.jpg" && ok || bad "/ 没给出端点索引"
curl -s --max-time 5 $B/ | grep -q "<html" && bad "/ 给 agent 回了 HTML" || ok
check "/human.html 状态" 200 "$(code $B/human.html)"
check "/human.html 类型" "text/html; charset=utf-8" "$(ctype $B/human.html)"
# 模拟浏览器
check "带 Accept 的 / 回 HTML" "text/html; charset=utf-8" \
  "$(curl -s -o /dev/null -w '%{content_type}' --max-time 5 -H 'Accept: text/html,*/*' $B/)"
check "/health 状态" 200 "$(code $B/health)"
check "/health 类型" "application/json" "$(ctype $B/health)"
check "/skill.md 类型" "text/markdown; charset=utf-8" "$(ctype $B/skill.md)"
check "/robots.txt 状态" 200 "$(code $B/robots.txt)"
check "/robots.txt 类型" "text/plain; charset=utf-8" "$(ctype $B/robots.txt)"
check "/llms.txt 状态" 200 "$(code $B/llms.txt)"
check "/error.md 状态" 200 "$(code $B/error.md)"
check "/error.md 类型" "text/markdown; charset=utf-8" "$(ctype $B/error.md)"
curl -s --max-time 5 $B/llms.txt | grep -q "/error.md" && ok || bad "llms.txt 没指向 error.md"
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

echo "== 慢连接不该拖住其他人 =="
# 连上不发数据，模拟坏客户端/扫描器。服务必须照常响应别人，
# 否则一条卡住的连接就能把整个服务拖停（这是 serve_with_access 的重点）。
python3 - "$PORT" <<'SLOW' &
import socket, sys, time
s = socket.socket()
s.connect(("127.0.0.1", int(sys.argv[1])))
time.sleep(4)          # 不写任何请求
s.close()
SLOW
SLOW_PID=$!
sleep 0.5
T0=$(date +%s%N)
check "慢连接挂起时 /health 仍 200" 200 "$(code $B/health)"
T1=$(date +%s%N)
MS=$(( (T1-T0)/1000000 ))
[ "$MS" -lt 2000 ] && ok || bad "慢连接把服务拖慢了：${MS}ms"
wait "$SLOW_PID" 2>/dev/null

echo "== 并发压一轮不该崩 =="
# 注意：这里只能等具体的 curl 进程。裸 `wait` 会把服务进程一起等进去，永远挂住。
LPIDS=""
for _ in $(seq 1 20); do
  curl -s -o /dev/null --max-time 10 "$B/health" &
  LPIDS="$LPIDS $!"
done
for p in $LPIDS; do wait "$p"; done
check "20 并发之后仍可用" 200 "$(code $B/health)"
echo "$(curl -s --max-time 5 $B/health)" | grep -q '"ok": true' \
  && ok || bad "并发之后 health 的 ok 不是 true"

echo
echo "通过 $PASS，失败 $FAIL"
[ "$FAIL" -eq 0 ] || { echo "--- 服务日志 ---"; tail -20 "$PORT_LOG"; exit 1; }
