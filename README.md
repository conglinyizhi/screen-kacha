# screenstream-mb

本机屏幕的 HTTP 快照服务，MoonBit 重写版。版本从 v0.1 起，与 Python 版并行存在。

## 状态

v0.1 骨架：全路由 + 采集状态机已经跑通，可以自己用起来。托盘、systemd 注入、状态文件尚未移植。

## 端点

| 路径 | 返回 |
| --- | --- |
| `GET /` | 网页，2 秒刷新 |
| `GET /health` | 采集状态 JSON |
| `GET /skill.md` | 用法说明（读当前目录的 skill.md，缺失用内置兜底） |
| `GET /snapshot.jpg` | 原图 |
| `GET /snapshot-1280.jpg` | 缩到宽 1280，160 到 3840 之外会被夹住 |
| `GET /snapshot-1280.webp` | 输出 WebP |
| 其它 | 404 纯文本，指向 `/skill.md` |

## 构建与运行

```bash
moon build cmd/main --target native --release
WAYLAND_DISPLAY=wayland-1 ./_build/native/release/build/cmd/main/main.exe
```

端口写死在 `cmd/main/main.mbt` 的 `18940`，v0.1 不做参数解析。

## 实现要点

采集走 `spectacle`，它不允许并发实例（同机同时拉起多个会互相卡死）。所以 `Store::ensure` 用一把异步互斥锁把采集串行化，并在拿到锁之后重新判一次帧龄：并发请求被合并成一次采集。实测三个并发请求 13 ms 返回，采集计数只加一。

`String::to_bytes()` 产出的是 UTF-16，文本响应必须用 `@encoding/utf8.encode`，否则浏览器收到的是一堆夹着零字节的东西。

## 静态文件

`/skill.md`、`/robots.txt`、`/llms.txt` 优先读工作目录下的同名文件（可以改，改完不用重编），
读不到就用编进二进制的兜底内容。所以单文件部署也能用。

`robots.txt` 是 `Disallow: /`：这套服务只给本地 agent 用，画面是桌面内容，不该被任何爬虫索引。

没有 `sitemap.xml`。它是给搜索引擎的索引清单，规范要求填绝对地址，
而这里的地址是局域网 IP、随时可能变；再加上 robots 已经全站禁止，
放一份 sitemap 只会自相矛盾。真有公网域名了再加。

## 测试

```bash
moon test --target native      # 单元测试
bash scripts/smoke.sh          # 端到端冒烟
```

冒烟脚本用 `--fake` 指定一张图片当帧源，绕开 spectacle，自己挑一个空闲端口起临时实例，
把路由、类型、缩放、WebP、帧龄缓存、并发合并都走一遍，跑完就退出。
不需要显示器，也不碰正在运行的服务。

## 后台抓帧泵

默认每 500 ms 抓一帧放到缓存里，请求侧直接读缓存，不再每次等 spectacle 那 0.6 秒。
`--pump 0` 关掉它，回到按需抓取。

十秒没人取图时会自动降到 `--pump-idle`（默认 3 秒）的节奏，避免一直空转烧 CPU。
`/health` 里的 `idle_ms` 能看出上一次取图距今多久。

`?age=` 是能接受的最大帧龄，默认 1.5 秒；要更甜的帧就用 `?age=0.1`，代价是当场触发一次抓取。

抓帧带超时（3 秒）和失败退避：spectacle 是单实例的，被别的抓帧客户端占着时会一直等，
没有超时就会永久卡住并一直握着采集锁。

## 依赖

`bobzhang/crescent` 锁在 0.11.2，它依赖 `moonbitlang/async@0.20.3`。0.20.3 没有 `shell` 包，所以调 magick 走文件而不是管道。

### ImageMagick 是可选的

启动时按 `/usr/bin/magick`、`/usr/bin/convert`、`/usr/bin/gm` 的顺序探测一次，结果写进 `/health` 的 `magick` 字段。

没有 ImageMagick 也能跑：`/snapshot.jpg` 原样返回，需要缩放或 WebP 的请求退回原始 JPEG，并带 `X-Screenstream-Fallback: no-magick` 头，方便调用方知道拿到的不是所请求的尺寸。

## 已知限制

- 没有托盘、没有 systemd 单元，需要手动起。
- 缺 ImageMagick 时缩放与 WebP 降级为原图，不会报错。
- 采集失败时 `/snapshot.jpg` 返回 503 带错误原因。
- 临时文件落在 `/tmp/screenstream-mb-*.jpg`，退出不清理。

## 取帧来源

默认 `--source auto`：先按 spectacle 提供服务，同时在后台通过 xdg-desktop-portal
获取一条屏幕流，拿到就切到 PipeWire。

- PipeWire 模式下不再反复启动 spectacle，空闲时 CPU 基本为零
- 首次需要人工确认一次屏幕共享授权；确认后 portal 会发 restore token，
  存在帧目录的 `portal.token` 里，之后重启不再询问
- 会话由 `screenstream-portal` 助手进程保持，node 随会话存活
- PipeWire 连续失败 3 次会自动切回 spectacle，`/health` 的 `source` 字段
  标明当前实际来源
- 已知代价：PipeWire 抓屏期间桌面会一直显示「正在共享屏幕」的指示

只想用老办法就加 `--source spectacle`；想跳过 portal 直接指定节点用 `--pw-node <id>`。
