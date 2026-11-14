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

## 依赖

`bobzhang/crescent` 锁在 0.11.2，它依赖 `moonbitlang/async@0.20.3`。0.20.3 没有 `shell` 包，所以调 magick 走文件而不是管道。

## 已知限制

- 没有托盘、没有 systemd 单元，需要手动起。
- 采集失败时 `/snapshot.jpg` 返回 503 带错误原因。
- 临时文件落在 `/tmp/screenstream-mb-*.jpg`，退出不清理。
