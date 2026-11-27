#!/usr/bin/env bash
# 验证两个具名服务并行运行时，端口状态互不覆盖，停一份不影响另一份。
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
. "$ROOT/scripts/lib.sh"
BIN=$(sk_exe "$ROOT" debug cmd/main) || {
  echo "找不到 debug 版 main.exe，先构建" >&2
  exit 1
}
WORK=$(mktemp -d)
STATE="$WORK/state"
A_PID=""
B_PID=""

cleanup() {
  [ -z "$A_PID" ] || kill "$A_PID" 2>/dev/null || true
  [ -z "$B_PID" ] || kill "$B_PID" 2>/dev/null || true
  [ -z "$A_PID" ] || wait "$A_PID" 2>/dev/null || true
  [ -z "$B_PID" ] || wait "$B_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

python3 - "$WORK/frame.png" <<'PY'
import struct, sys, zlib
w, h = 32, 24
row = b"\0" + bytes([40, 90, 160]) * w
raw = row * h
def chunk(tag, data):
    body = tag + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n"
png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(raw))
png += chunk(b"IEND", b"")
open(sys.argv[1], "wb").write(png)
PY

PORT_A=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
PORT_B=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')

XDG_STATE_HOME="$STATE" timeout 60 "$BIN" \
  --instance capture-a --port "$PORT_A" --bind 127.0.0.1 --pump 100 \
  --shm "$WORK/shm-a" --fake "$WORK/frame.png" >"$WORK/a.log" 2>&1 &
A_PID=$!
XDG_STATE_HOME="$STATE" timeout 60 "$BIN" \
  --instance capture-b --port "$PORT_B" --bind 127.0.0.1 --pump 100 \
  --shm "$WORK/shm-b" --fake "$WORK/frame.png" >"$WORK/b.log" 2>&1 &
B_PID=$!

A_PORT_FILE="$STATE/screen-kacha/instances/capture-a/port"
B_PORT_FILE="$STATE/screen-kacha/instances/capture-b/port"
for _ in $(seq 1 100); do
  [ -s "$A_PORT_FILE" ] && [ -s "$B_PORT_FILE" ] && break
  sleep 0.1
done
[ -s "$A_PORT_FILE" ] || { cat "$WORK/a.log"; echo "capture-a 没写端口状态" >&2; exit 1; }
[ -s "$B_PORT_FILE" ] || { cat "$WORK/b.log"; echo "capture-b 没写端口状态" >&2; exit 1; }

ACTUAL_A=$(cat "$A_PORT_FILE")
ACTUAL_B=$(cat "$B_PORT_FILE")
[ "$ACTUAL_A" != "$ACTUAL_B" ] || { echo "两个实例意外写入相同端口" >&2; exit 1; }
curl -fsS --max-time 5 "http://127.0.0.1:$ACTUAL_A/health" >"$WORK/a-health.json"
curl -fsS --max-time 5 "http://127.0.0.1:$ACTUAL_B/health" >"$WORK/b-health.json"
python3 - "$WORK/a-health.json" "$WORK/b-health.json" "$ACTUAL_A" "$ACTUAL_B" <<'PY'
import json, sys
for path, port in zip(sys.argv[1:3], map(int, sys.argv[3:5])):
    with open(path) as f:
        health = json.load(f)
    assert health["ok"] is True, health
    assert health["port"] == port, health
PY

# 同一实例名即使换了帧目录，也必须被实例状态锁挡住。
set +e
XDG_STATE_HOME="$STATE" timeout 20 "$BIN" \
  --instance capture-a --port "$((PORT_A + 2))" --bind 127.0.0.1 --pump 100 \
  --shm "$WORK/shm-a-duplicate" --fake "$WORK/frame.png" \
  >"$WORK/a-duplicate.log" 2>&1
DUP_RC=$?
set -e
[ "$DUP_RC" -eq 0 ] || { echo "同一实例重复启动退出码应为 0，实际 $DUP_RC" >&2; cat "$WORK/a-duplicate.log" >&2; exit 1; }
grep -q '实例 capture-a 已经被另一个' "$WORK/a-duplicate.log" || {
  echo "同一实例重复启动没有被实例锁拦截" >&2
  exit 1
}

# 不同实例名若显式共用帧目录，仍由帧目录锁挡住。
set +e
XDG_STATE_HOME="$STATE" timeout 20 "$BIN" \
  --instance capture-c --port "$((PORT_B + 2))" --bind 127.0.0.1 --pump 100 \
  --shm "$WORK/shm-b" --fake "$WORK/frame.png" \
  >"$WORK/c-shm-duplicate.log" 2>&1
SHM_RC=$?
set -e
[ "$SHM_RC" -eq 0 ] || { echo "共用帧目录重复启动退出码应为 0，实际 $SHM_RC" >&2; exit 1; }
grep -q '帧目录 .* 已经被另一个' "$WORK/c-shm-duplicate.log" || {
  echo "共用帧目录没有被帧目录锁拦截" >&2
  exit 1
}

kill "$A_PID"
wait "$A_PID" 2>/dev/null || true
A_PID=""
curl -fsS --max-time 5 "http://127.0.0.1:$ACTUAL_B/health" >/dev/null
if curl -fsS --max-time 1 "http://127.0.0.1:$ACTUAL_A/health" >/dev/null 2>&1; then
  echo "停止 capture-a 后端口仍有服务响应" >&2
  exit 1
fi
[ -s "$B_PORT_FILE" ] || { echo "停止 capture-a 误删了 capture-b 的状态" >&2; exit 1; }
echo "具名实例并行隔离通过：capture-a=$ACTUAL_A capture-b=$ACTUAL_B"
