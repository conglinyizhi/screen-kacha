#!/bin/sh
# 安装托盘图标到 hicolor 主题。
#
# 三个坑，都是踩过的：
#   1. 文件名必须是 <图标名>.png，不能带 `-22` 这种尺寸后缀，
#      主题是按「图标名.png」查的，带后缀就找不到、图标位置留空。
#   2. PNG 必须是 8 位深。16 位 KDE 的图标加载器认不出来，同样留空。
#      （仓库里的源文件已经转好 8 位，所以这里可以直接 cp，不依赖 magick）
#   3. 用户目录下的 hicolor 必须有自己的 index.theme，否则整个目录
#      不会被当成一个主题。
set -e
D="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor"
SRC="$(cd "$(dirname "$0")" && pwd)/icons"

if [ ! -f /usr/share/icons/hicolor/index.theme ]; then
  echo "找不到 /usr/share/icons/hicolor/index.theme，无法准备图标主题" >&2
  exit 1
fi
[ -f "$D/index.theme" ] || cp /usr/share/icons/hicolor/index.theme "$D/index.theme"

for sz in 22 44; do
  mkdir -p "$D/${sz}x${sz}/apps"
  for name in ok warn dead down; do
    cp "$SRC/screen-kacha-$name-$sz.png" "$D/${sz}x${sz}/apps/screen-kacha-$name.png"
  done
done

# 重建缓存；工具不在就跳过，Plasma 下次登录会自己扫
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -f -t "$D" >/dev/null 2>&1 || true
rm -f "${XDG_CACHE_HOME:-$HOME/.cache}/icon-cache.kcache"
command -v kbuildsycoca6 >/dev/null && kbuildsycoca6 >/dev/null 2>&1 || true

echo "图标已安装到 $D"
