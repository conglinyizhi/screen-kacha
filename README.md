# screenstream-mb

本机屏幕的 HTTP 快照服务，MoonBit 重写版。版本从 v0.1 起，与 Python 版并行存在。

## 状态

v0.1，自己日常在用。核心链路（PipeWire 取帧 → HTTP 快照）、托盘指示灯、
访问控制、systemd 集成都已落地；有单元测试和端到端冒烟，CI 跑同样的命令。

还没做的：Windows / macOS 从未验证（代码只支持 native + Linux），
也没有打包成发行版包。

## 端点

| 路径 | 返回 |
| --- | --- |
| `GET /` | 网页，2 秒刷新 |
| `GET /health` | 采集状态 JSON，含 `source`、`cap_ms`、`fails`、`access` |
| `GET /skill.md` | 用法说明（读当前目录的 skill.md，缺失用内置兜底） |
| `GET /error.md` | 出错排查步骤 |
| `GET /llms.txt` | 给模型看的端点索引 |
| `GET /robots.txt` | 全站禁止索引 |
| `GET /snapshot.jpg` | 原图 |
| `GET /snapshot-1280.jpg` | 缩到宽 1280，160 到 3840 之外会被夹住 |
| `GET /snapshot-1280.webp` | 输出 WebP |
| `GET /ui/err?code=xxx` | 出错兜底页，正文由服务端按代号给出 |
| 其它 | 404 纯文本，指向 `/skill.md` |

`GET /` 按 `Accept` 分叉：带 `text/html` 给 `human.html`（页面），
不带就给 `llms.txt` 原文（agent 拿到的没有 HTML 噪音）。
`human.html` 上有「参数实验」：改 `w`、`age`、格式会实时显示实际返回的图、
尺寸、体积和耗时；带参数访问（如 `/human.html?w=640&age=0.5`）会弹框说明
这些参数发给图片端点意味着什么。

## 安装

```bash
moon build --target native --release cmd/main cmd/tray cmd/portal
./install.sh --start
```

`install.sh` 只动用户目录，不需要 sudo。它装二进制到 `~/.local/bin`、
文档到 `~/.local/share/screenstream-mb`、图标到 hicolor 主题，
并生成 systemd unit 和 portal 自启项。`--uninstall` 反向卸载，
保留配置和缓存。

unit 模板在 `contrib/`，安装时替换 `BIN`、`DATA`、`PORT`、`BIND`、`WAYLAND`。
`WAYLAND_DISPLAY` 从当前会话探测，端口默认 8930，都可以用环境变量覆盖：

```bash
PORT=9000 BIND=127.0.0.1 ./install.sh
```

### 不装 systemd，直接跑

```bash
WAYLAND_DISPLAY=wayland-1 ./_build/native/release/build/cmd/main/main.exe --port 8930
```

## 实现要点

采集走 `spectacle`，它不允许并发实例（同机同时拉起多个会互相卡死）。所以 `Store::ensure` 用一把异步互斥锁把采集串行化，并在拿到锁之后重新判一次帧龄：并发请求被合并成一次采集。实测三个并发请求 13 ms 返回，采集计数只加一。

`String::to_bytes()` 产出的是 UTF-16，文本响应必须用 `@encoding/utf8.encode`，否则浏览器收到的是一堆夹着零字节的东西。

## 静态文件

`/skill.md`、`/error.md`、`/robots.txt`、`/llms.txt` 优先读工作目录下的同名文件
（可以改，改完不用重编），读不到就用编进二进制的兜底内容。所以单文件部署也能用。

`robots.txt` 是 `Disallow: /`：这套服务只给本地 agent 用，画面是桌面内容，不该被任何爬虫索引。

没有 `sitemap.xml`。它是给搜索引擎的索引清单，规范要求填绝对地址，
而这里的地址是局域网 IP、随时可能变；再加上 robots 已经全站禁止，
放一份 sitemap 只会自相矛盾。真有公网域名了再加。

## 测试

```bash
moon fmt --check
moon check --target native --deny-warn
moon test --target native          # 单元测试
bash scripts/smoke.sh              # 端到端冒烟（默认监听路径）
ACCESS_CONF=/tmp/only-local.conf bash scripts/smoke.sh   # 受限监听路径
```

冒烟脚本用 `--fake` 指定一张图片当帧源，绕开 spectacle 和 portal，自己挑一个空闲端口
起临时实例，把路由、类型、缩放、WebP、帧龄缓存、并发合并、慢连接、并发压力都走一遍。
不需要显示器，也不碰正在运行的服务。

`serve_with_access`（启用访问限制时的监听循环）和 `serve_on` 是两条代码路径，
所以冒烟要跑两遍。CI 里也是两遍。

## 后台抓帧泵

默认每 500 ms 抓一帧放到缓存里，请求侧直接读缓存，不再每次等 spectacle 那 0.6 秒。
`--pump 0` 关掉它，回到按需抓取。

十秒没人取图时会自动降到 `--pump-idle`（默认 3 秒）的节奏，避免一直空转烧 CPU。
`/health` 里的 `idle_ms` 能看出上一次取图距今多久。

`?age=` 是能接受的最大帧龄，默认 1.5 秒；要更甜的帧就用 `?age=0.1`，代价是当场触发一次抓取。

抓帧带超时（3 秒）和失败退避：spectacle 是单实例的，被别的抓帧客户端占着时会一直等，
没有超时就会永久卡住并一直握着采集锁。

## moonimage：自带的图像编解码

`moonimage` 子库把「BGRA 原始帧 → 缩放 → JPEG/WebP」这套做进进程内，
不再为每帧 fork 一个 ImageMagick。

| 场景 | moonimage | ImageMagick |
| --- | --- | --- |
| 原尺寸重编码 | 19 ms | 53 ms |
| 缩到 640 宽 | 13 ms | 60 ms |
| 缩到 1280 宽 | 22 ms | 78 ms |

抓帧耗时从 62 ms 降到 23 ms。内存峰值从 magick 的 83 MB 降到 18 MB。

缩小用的是自写的**面积平均**，不是 Lanczos：截图里全是小字，
面积平均不会像 Lanczos 那样加锐化光晕。代价是和大尺寸输出对比
PSNR 在 33–37（原尺寸 49），视觉上基本看不出，文件反而略大几 KB。

依赖只有 libjpeg（BSD/IJG）和 libwebp（BSD-3），都不传染。
**没有用 libswscale**：部分发行版的 ffmpeg 是 GPL-3.0，会带来许可证问题，
那点像素算术自己写更省心。详见 `THIRD-PARTY.md`。

## 依赖

编译需要：

- MoonBit 工具链
- libpipewire 头文件（`pipewire-0.3`、`spa-0.2`）
- **libjpeg** 和 **libwebp**（moonimage 用）

运行需要：

- PipeWire（取帧）
- xdg-desktop-portal + KDE 后端（屏幕共享授权）
- ImageMagick：**可选**，只在少数后备路径用到

## ImageMagick 是可选的

启动时按 `/usr/bin/magick`、`/usr/bin/convert`、`/usr/bin/gm` 的顺序探测一次，结果写进 `/health` 的 `magick` 字段。

没有 ImageMagick 也能跑：`/snapshot.jpg` 原样返回，需要缩放或 WebP 的请求退回原始 JPEG，并带 `X-Screenstream-Fallback: no-magick` 头，方便调用方知道拿到的不是所请求的尺寸。

## 已知限制

- 只在 Linux + KDE Wayland 上验证过。代码走 native 目标，其它平台没试，
  `moonpipewire` 的 C shim 依赖 PipeWire。
- 缺 ImageMagick 时缩放与 WebP 降级为原图，不会报错。
- 采集失败时 `/snapshot.jpg` 返回 503 带错误原因。
- 启用访问控制后走 `serve_with_access`（自己写的 accept 循环），它和
  `serve_on` 行为基本对齐，但少了请求体大小上限——本服务只收 GET，
  不影响使用，换成支持 POST 时要补。
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

## 托盘图标

图标是「显示器 + 右下角指示灯」，四态：

| 图标 | 灯色 | 含义 |
|---|---|---|
| `screenstream-ok` | 绿 | 服务正常 |
| `screenstream-warn` | 黄 | 已启动，还没抓到帧 |
| `screenstream-dead` | 灰 | 服务没响应 |
| `screenstream-down` | 红 | 采集失败并记了错 |

托盘每 5 秒查一次 `/health`，按结果换图标名。

安装：`./install-icons.sh`。三个必踩的坑——文件名必须是 `<图标名>.png`
（不能带 `-22` 这种尺寸后缀，否则主题按名找不到）、PNG 必须是 8 位深
（16 位 KDE 加载不了，图标位置会留空）、用户 hicolor 目录要有 `index.theme`。

## 访问控制

配置放在 `~/.config/screenstream-mb/access.conf`（或 `--access <path>`）：

```text
allow_lan    = true    # 局域网放行
allow_public = false   # 非局域网放行 —— 危险
allow =                # 预留：显式放行名单
```

回环地址永远放行。被拒的连接会读到 403 和一行说明，日志里记一条「拒绝 <peer>」。

托盘菜单里有两个开关直接改这个文件并重启服务：**放行局域网请求**（默认开）、
**[危险] 放行非局域网请求**（默认关）。`/health` 的 `access` 字段写明当前策略。

实现上，公网不放行时服务自己收连接（crescent 的 `serve_on` 把对端地址丢了，
拿不到 IP），每条连接处理一个请求就关；公网放行时仍走原来的 `serve_on`。


