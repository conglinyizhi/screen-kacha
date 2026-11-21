# 第三方组件

本项目以 Apache-2.0 发布（见 `LICENSE`）。下面这些第三方组件被链接或调用，
它们各自的许可证和本项目兼容，不需要改变本项目的许可证。

## 运行时链接

### libjpeg-turbo

- 用途：JPEG 编码（`moonimage` 子库）
- 许可证：IJG License + BSD-3-Clause（双重，取其一即可）
- 兼容性：宽松许可，与 Apache-2.0 兼容，无传染性
- 主页：https://libjpeg-turbo.org/

### libwebp

- 用途：WebP 编码（`moonimage` 子库）
- 许可证：BSD-3-Clause
- 兼容性：宽松许可，与 Apache-2.0 兼容，无传染性
- 版权：Copyright (c) 2010, Google Inc.
- 主页：https://chromium.googlesource.com/webm/libwebp

### libpipewire

- 用途：屏幕捕获（`moonpipewire` 子库）
- 许可证：MIT
- 兼容性：与 Apache-2.0 兼容
- 主页：https://pipewire.org/

## 构建时依赖

### MoonBit 工具链

- 许可证：Apache-2.0
- 主页：https://www.moonbitlang.com/

## 运行时可选

### ImageMagick

- 用途：**可选**。缩放、WebP、光标叠加有 `moonimage` 的原生实现；
  ImageMagick 只在需要「从已有 JPEG 再缩放」等边角场景下作为后备调用。
  通过子进程调用，不链接、不包含其代码。
- 许可证：ImageMagick License（Apache-2.0 风格，非 copyleft）
- 主页：https://imagemagick.org/

## 说明

`moonimage` 的缩放是自己实现的面积平均（`moonimage/image_shim.c`），
**没有使用** libswscale 或任何 ffmpeg 组件 —— 部分发行版的 ffmpeg 是
GPL-3.0，引入会带来传染性，这里刻意避开了。
