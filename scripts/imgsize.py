#!/usr/bin/env python3
"""读图片的宽高，输出 `宽x高`。

冒烟脚本原来用 `magick identify`，那等于把 ImageMagick 变成测试依赖。
其实只管 JPEG 和 PNG 两个格式的尺寸，几十行就够。

用法：imgsize.py <path>
读不出来什么都不打印，退出码非零。
"""

import struct
import sys


def png_size(data):
    # IHDR 永远是第一个块，宽高在固定偏移上
    if len(data) < 24:
        return None
    w, h = struct.unpack(">II", data[16:24])
    return w, h


def jpeg_size(data):
    # 顺着标记段走，直到碰上 SOFn。尺寸就在它后面。
    i = 2
    n = len(data)
    while i + 4 <= n:
        if data[i] != 0xFF:
            i += 1
            continue
        marker = data[i + 1]
        # 这些标记没有长度字段，跳过就行
        if marker == 0xD8 or marker == 0x01 or 0xD0 <= marker <= 0xD7:
            i += 2
            continue
        if marker == 0xD9 or marker == 0xDA:
            return None
        seg_len = struct.unpack(">H", data[i + 2:i + 4])[0]
        if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
            if i + 9 > n:
                return None
            h, w = struct.unpack(">HH", data[i + 5:i + 9])
            return w, h
        i += 2 + seg_len
    return None


def main():
    if len(sys.argv) < 2:
        return 2
    with open(sys.argv[1], "rb") as f:
        data = f.read()
    size = None
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        size = png_size(data)
    elif data[:2] == b"\xff\xd8":
        size = jpeg_size(data)
    if size is None:
        return 1
    print(f"{size[0]}x{size[1]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
