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

### MoonBit 包依赖

打包进二进制的源码依赖，全部与本项目的 Apache-2.0 兼容。

| 包 | 用途 | 许可证 |
|---|---|---|
| `moonbitlang/async` | 异步运行时、HTTP、socket | Apache-2.0 |
| `colmugx/mcp` | MCP 服务端 | Apache-2.0 |
| `cc06b/mooncry` | 上面这个包的依赖 | Apache-2.0 |
| `gmlewis/base64` | 上面这个包的依赖 | Apache-2.0 |
| `colmugx/json-schema` | 上面这个包的依赖，校验工具入参 | Apache-2.0 |
| `conglinyizhi/moondbus` | D-Bus 客户端 | Apache-2.0 |
| `conglinyizhi/moonsni` | 托盘 StatusNotifierItem | Apache-2.0 |
| `conglinyizhi/moon-embed` | 把静态资源嵌进二进制 | MIT |

## 运行时可选

### libpng

- 用途：读光标箭头素材（PNG）。合成和编码都在进程内完成，不再调外部程序
- 许可证：libpng License（permissive，允许闭源分发）

