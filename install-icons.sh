#!/bin/sh
# 安装托盘图标到 hicolor 主题。
# 三个坑：文件名必须是 <图标名>.png（不能带尺寸后缀）、PNG 必须是 8 位、
# 用户 hicolor 目录需要有 index.theme 才会被当成主题。
set -e
D="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor"
SRC="$(cd "$(dirname "$0")" && pwd)/icons"

[ -f "$D/index.theme" ] || cp /usr/share/icons/hicolor/index.theme "$D/index.theme"

for sz in 22 44; do
  mkdir -p "$D/${sz}x${sz}/apps"
  for name in ok warn dead down; do
    magick "$SRC/screenstream-$name-$sz.png" -depth 8 "PNG32:$D/${sz}x${sz}/apps/screenstream-$name.png"
  done
done
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -f -t "$D" >/dev/null 2>&1 || true
rm -f "${XDG_CACHE_HOME:-$HOME/.cache}/icon-cache.kcache"
command -v kbuildsycoca6 >/dev/null && kbuildsycoca6 >/dev/null 2>&1 || true
echo "图标已安装到 $D"
