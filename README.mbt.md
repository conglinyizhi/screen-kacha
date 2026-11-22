# screenstream-mb

本机屏幕的 HTTP 快照服务，MoonBit 实现。

`GET /snapshot.jpg` 拿一张当前屏幕的 JPEG，agent 可以直接看图。附带
`/health`、`/skill.md`、`/llms.txt`，让模型自己搞清楚怎么用，不用人教。

取帧主路走 PipeWire 加 xdg-desktop-portal，不靠调用截图工具的命令行；
后台泵把帧拿到缓存里，请求侧直接读，命中时延迟 2 毫秒左右。
KDE Wayland 上另外提供托盘菜单和光标位置标记。

## 平台与依赖

编译需要 MoonBit 工具链，以及三个系统库的头文件：

```bash
# Arch
sudo pacman -S pipewire libjpeg-turbo libwebp

# Debian / Ubuntu
sudo apt install libpipewire-0.3-dev libjpeg-dev libwebp-dev
```

运行需要 PipeWire 和 xdg-desktop-portal（KDE 后端）。不依赖 ImageMagick 或任何
外部图像程序：抓帧转码、缩放、WebP、画鼠标光标都在进程内完成。

目前只在 KDE Wayland 上测过。核心链路（PipeWire 加 portal）其他桌面也能用，
KDE 特化的是托盘菜单、KWin 光标脚本和 spectacle 兜底。

## 安装

```bash
moon build --target native --release cmd/main cmd/tray cmd/portal
./install.sh --start
```

`install.sh` 只动用户目录，不需要 sudo，会装二进制、文档、图标，
生成 systemd unit 和 portal 自启项。`--uninstall` 反向卸载，保留配置和缓存。

不想装 systemd 就直接跑：

```bash
WAYLAND_DISPLAY=wayland-1 ./_build/native/release/build/cmd/main/main.exe --port 8930
```

## 端点

| 路径 | 返回 |
| --- | --- |
| `GET /snapshot.jpg` | 当前画面，原分辨率 |
| `GET /snapshot-1280.jpg` | 缩到宽 1280 |
| `GET /snapshot-1280.webp` | 同样尺寸，体积更小 |
| `GET /health` | 采集状态 JSON，含帧龄、耗时、失败计数、取帧来源 |
| `GET /skill.md` | 完整用法 |
| `GET /llms.txt` | 给模型看的端点索引 |

宽度也可以写进文件名，`/snapshot-640.jpg` 等价于 `/snapshot.jpg?w=640`，
160 到 3840 之外会被夹到边界。

## 当库用

两个子包可以单独依赖：

```mbt nocheck
import "conglinyizhi/screenstream/moonpipewire" @pipewire
import "conglinyizhi/screenstream/moonimage" @image
```

`moonpipewire` 取的是已经存在的视频流节点，节点怎么来由调用方负责，
通常走 xdg-desktop-portal 的 ScreenCast。`moonimage` 把裸 BGRA 帧缩放后
编成 JPEG 或 WebP，不做通用图像处理。

两个包都靠 C stub 链系统库。MoonBit 不会把链接参数传给下游，
所以用到它们的包要在自己的 `moon.pkg` 里补一条：

```text
link: { "native": { "cc-link-flags": "-lpipewire-0.3" } }
```

## 更多

完整说明见仓库里的 `README.md`，第三方组件与许可证见 `THIRD-PARTY.md`。
