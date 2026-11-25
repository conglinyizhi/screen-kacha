#!/usr/bin/env bash
# 把 screen-kacha 装到当前用户：二进制、文档、图标、systemd unit、portal 自启。
#
#   ./install.sh             安装并启用（不立刻启动）
#   ./install.sh --start     安装后立刻启动
#   ./install.sh --uninstall 卸载（保留配置和缓存）
#
# 只装到用户目录，不动 /etc，不需要 sudo。
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
. "$ROOT/contrib/screen-kacha-names.sh"
PREFIX="${PREFIX:-$HOME/.local}"
BIN="$PREFIX/bin"
DATA="$PREFIX/share/screen-kacha"
UNITS="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
AUTOSTART="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/screen-kacha"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/screen-kacha"
PORT="${PORT:-8930}"
BIND="${BIND:-0.0.0.0}"

DO_START=0
DO_UNINSTALL=0
for arg in "$@"; do
  case "$arg" in
    --start) DO_START=1 ;;
    --uninstall) DO_UNINSTALL=1 ;;
    -h|--help)
      sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "不认识的参数：$arg" >&2
      exit 2
      ;;
  esac
done

say() { printf '  %s\n' "$1"; }

# ---------------------------------------------------------------------------
# 卸载
# ---------------------------------------------------------------------------
if [ "$DO_UNINSTALL" -eq 1 ]; then
  echo "== 卸载 =="
  # 只在 unit 确实落在本次的目录里才停服务。
  # systemctl 是按 unit 名字找的，不看 XDG_CONFIG_HOME；不加这层判断，
  # 在别的 PREFIX/配置目录下跑 --uninstall 会误停正在用的服务。
  for entry in "${SCREEN_KACHA_UNIT_TEMPLATES[@]}"; do
    unit="${entry##*:}"
    if [ -f "$UNITS/$unit" ]; then
      systemctl --user disable --now "$unit" 2>/dev/null || true
    fi
    rm -f "$UNITS/$unit"
  done
  rm -f "$AUTOSTART/$SCREEN_KACHA_PORTAL_DESKTOP"
  # 光标 helper 和 portal 助手都是自启拉起来的，systemctl disable 管不到它们。
  # portal 那边不收尾，桌面上会留一条活的 ScreenCast 会话（「正在共享屏幕」
  # 的指示、pw 里一条 capture 流），要等注销才消失 —— 软件已经删了，系统还在
  # 共享屏幕，观感上就是安全问题。
  # `[s]` 是为了让 pgrep 的模式不匹配到自己这条命令行。
  for process in "${SCREEN_KACHA_PROCESSES[@]}"; do
    pattern="[${process:0:1}]${process:1}"
    pkill -f "$pattern" 2>/dev/null || true
  done
  rm -f "$RUNTIME_DIR/portal.node" "$STATE_DIR/portal.token"
  for entry in "${SCREEN_KACHA_BINARIES[@]}"; do
    rm -f "$BIN/${entry##*:}"
  done
  rm -f "$BIN/$SCREEN_KACHA_PORTAL_LOOP"
  # 图标
  for sz in 22 44; do
    rm -f "$PREFIX/share/icons/hicolor/${sz}x${sz}/apps/screen-kacha-"*.png
  done
  systemctl --user daemon-reload 2>/dev/null || true
  say "已移除二进制、unit、自启和图标"
  say "配置 ${XDG_CONFIG_HOME:-$HOME/.config}/screen-kacha 与缓存 $STATE_DIR 保留"
  say "要彻底删干净：rm -rf '${XDG_CONFIG_HOME:-$HOME/.config}/screen-kacha' '$STATE_DIR'"
  exit 0
fi

# ---------------------------------------------------------------------------
# 前置检查
# ---------------------------------------------------------------------------
echo "== 检查环境 =="
missing=()
for cmd in systemctl curl; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "缺少命令：${missing[*]}" >&2
  exit 1
fi

BUILD=""
for candidate in "$ROOT/_build/native/release/build/cmd" \
                 "$ROOT/_build/native/debug/build/cmd"; do
  [ -d "$candidate" ] && BUILD="$candidate" && break
done
if [ -z "$BUILD" ]; then
  echo "找不到构建产物。先构建：" >&2
  echo "  moon build --target native --release cmd/main cmd/tray cmd/portal" >&2
  exit 1
fi
say "产物目录 $BUILD"

# 从 runtime 目录里挑 Wayland socket 名。
#
# 只认 `wayland-<数字>`：那个目录里还有 `wayland-0.lock`、`wayland-cursor.sock`
# 这类文件，`ls -1 wayland-* | head -1` 会选中它们，写进 unit 之后 Qt 连不上
# Wayland，抓帧一直失败，而 /health 里只有一个 err 字符串。多个 socket 时取
# 编号最大的（KWin 重启会往上加）。
#
# 单独成函数是为了能被 scripts/check-install.sh 抽出来测。
pick_wayland_socket() {
  local rt="$1"
  (cd "$rt" 2>/dev/null \
    && ls -1 2>/dev/null \
    | grep -E '^wayland-[0-9]+$' \
    | sort -t- -k2 -n \
    | tail -1) || true
}

# Wayland 显示名要从当前会话猜，写死 wayland-1 换台机器就起不来。
#
# 只认 `wayland-<数字>`：那个目录里还有 `wayland-0.lock`、`wayland-cursor.sock`
# 这类文件，`ls -1 wayland-* | head -1` 会选中它们，写进 unit 之后 Qt 连不上
# Wayland，抓帧一直失败，而 /health 里只有一个 err 字符串，没人知道是安装时
# 猜错了一个环境变量。多个 socket 时取编号最大的那个（KWin 重启会往上加）。
WAYLAND="${WAYLAND_DISPLAY:-}"
if [ -z "$WAYLAND" ]; then
  rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  WAYLAND=$(pick_wayland_socket "$rt")
fi
if [ -z "$WAYLAND" ]; then
  echo "找不到 Wayland socket（在 ${XDG_RUNTIME_DIR:-/run/user/$(id -u)} 下没有 wayland-<数字>）。" >&2
  echo "请确认在图形会话里执行，或者用 WAYLAND_DISPLAY=wayland-N 显式指定。" >&2
  exit 1
fi
say "Wayland 显示 $WAYLAND"

# ---------------------------------------------------------------------------
# 安装
# ---------------------------------------------------------------------------
echo "== 装二进制 =="
mkdir -p "$BIN" "$DATA" "$UNITS" "$AUTOSTART"
for exe in "${SCREEN_KACHA_BINARIES[@]}"; do
  src="${exe%%:*}"
  dst="${exe##*:}"
  install -m 0755 "$BUILD/$src/$(basename "$src").exe" "$BIN/$dst"
  say "$dst"
done
install -m 0755 "$ROOT/contrib/$SCREEN_KACHA_PORTAL_LOOP" "$BIN/$SCREEN_KACHA_PORTAL_LOOP"
say "$SCREEN_KACHA_PORTAL_LOOP"

echo "== 装文档 =="
for f in README.md error.md skill.md llms.txt robots.txt human.html; do
  [ -f "$ROOT/$f" ] && install -m 0644 "$ROOT/$f" "$DATA/$f" && say "$f"
done

echo "== 装光标素材 =="
for f in cursor-arrow.png cursor-mask.png cursor-arrow-classic.png cursor-mask-classic.png; do
  [ -f "$ROOT/contrib/$f" ] && install -m 0644 "$ROOT/contrib/$f" "$DATA/$f" && say "$f"
done

echo "== 装图标 =="
if [ -x "$ROOT/install-icons.sh" ]; then
  XDG_DATA_HOME="$PREFIX/share" "$ROOT/install-icons.sh"
else
  say "跳过（没有 install-icons.sh）"
fi

echo "== 装 systemd unit =="
render() { # 模板 → 目标
  sed -e "s|@BIN@|$BIN|g" \
      -e "s|@DATA@|$DATA|g" \
      -e "s|@WAYLAND@|$WAYLAND|g" \
      -e "s|@PORT@|$PORT|g" \
      -e "s|@BIND@|$BIND|g" \
      "$1" > "$2"
}
for entry in "${SCREEN_KACHA_UNIT_TEMPLATES[@]}"; do
  template="${entry%%:*}"
  unit="${entry##*:}"
  render "$ROOT/contrib/$template" "$UNITS/$unit"
  say "$UNITS/$unit"
done

echo "== 装 portal 自启 =="
render "$ROOT/contrib/$SCREEN_KACHA_PORTAL_DESKTOP.in" "$AUTOSTART/$SCREEN_KACHA_PORTAL_DESKTOP"
say "$AUTOSTART/$SCREEN_KACHA_PORTAL_DESKTOP"

# 配置文件只在缺失时放一份样例，不覆盖用户已经改过的
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/screen-kacha"
if [ ! -f "$CONF_DIR/access.conf" ] && [ -f "$ROOT/access.conf.example" ]; then
  mkdir -p "$CONF_DIR"
  install -m 0644 "$ROOT/access.conf.example" "$CONF_DIR/access.conf"
  say "配置样例 $CONF_DIR/access.conf"
fi

echo "== 启用 =="
systemctl --user daemon-reload
systemctl --user enable screen-kacha.service screen-kacha-tray.service >/dev/null
say "两个 unit 已 enable（开机随图形会话启动）"

if [ "$DO_START" -eq 1 ]; then
  systemctl --user restart screen-kacha.service
  sleep 2
  systemctl --user restart screen-kacha-tray.service
  sleep 1
  say "已启动，健康检查："
  # 端口被占时服务会往上挪，挪完把实际端口写进状态目录。死认 $PORT 的话，
  # 这里会对着一个空端口报「服务还没起来」，而服务其实好好跑在隔壁。
  ACTUAL=$(cat "$STATE_DIR/port" 2>/dev/null || true)
  ACTUAL=${ACTUAL:-$PORT}
  [ "$ACTUAL" != "$PORT" ] && say "（$PORT 被占，实际监听 $ACTUAL）"
  curl -s --max-time 5 "http://127.0.0.1:$ACTUAL/health" || echo "  服务还没起来，看 journalctl --user -u screen-kacha"
else
  say "没有立刻启动。要现在启动：systemctl --user start screen-kacha screen-kacha-tray"
  say "或者重新运行：$0 --start"
fi

echo
echo "装好了。出错先看 $DATA/error.md，或用托盘菜单里的兜底页面。"
