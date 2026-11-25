# screen-kacha 开发指南

本机屏幕的 HTTP 快照服务，MoonBit 实现。取一张 JPEG 就能看见屏幕现状，给本地 agent 用。
只在 Linux 桌面跑：抓屏走 PipeWire 加 xdg-desktop-portal，KDE Wayland 上额外有托盘和光标标记。

## 先看这几条

1. 冒烟脚本读的是 `_build/native/debug` 下的二进制。只编 release 会直接 FAIL，
   两个 target 都得编
2. 改 `.mbt` 要重编；改 `human.html`、`*.md`、`*.txt` **不用**，服务是运行时读文件的
3. 手动跑二进制必须带 `--port`，代码里没有默认端口（免得和常驻服务撞端口）

## 开发流程

改完代码按这个顺序走一遍，全绿再提交：

```bash
# 1. 格式化与接口。先清构建缓存：moon fmt 按 mtime 判断要不要处理，
#    检出或 rsync 之后可能静默跳过，清掉才能保证真的格式化过
rm -rf _build && moon fmt && moon info

# 2. 编译与单测
moon check --target native --deny-warn     # 警告即失败，别放着
moon test --target native

# 3. 冒烟：端到端，假帧源，不需要显示器
moon build --target native cmd/main cmd/tray cmd/portal cmd/cursor
moon build --release --target native cmd/main cmd/tray cmd/portal cmd/cursor
bash scripts/smoke.sh
bash scripts/smoke-instances.sh
```

`moon build --target native` **不带目标**会把库包也当可执行文件链接，报 undefined main。
永远显式写目标。

`scripts/smoke.sh` 起一个临时实例走完整 HTTP 全链路，退出码非零表示失败。
它也支持 `ACCESS_CONF=<path> bash scripts/smoke.sh` 验证受限访问策略，两种策略都要过。
`scripts/smoke-instances.sh` 另外验证具名实例并行、实例状态隔离及帧目录锁。

部署：

```bash
install -m 0755 _build/native/release/build/cmd/main/main.exe ~/.local/bin/screen-kacha
systemctl --user restart screen-kacha.service
```

## 代码地图

```text
根包              对外网关。app.mbt 定路由，store.mbt 管帧缓存和采集，
                  access.mbt 访问控制，cursor.mbt 画鼠标指针，
                  pages.mbt 是各种文本页面和 `/` 的外壳
moonpipewire/     PipeWire 取帧的 C 绑定，pw_shim.c 里自己起线程跑 main loop
moonimage/        BGRA 到 JPEG/WebP，image_shim.c 里是面积平均缩放
cmd/main/         服务本体
cmd/tray/         StatusNotifierItem 托盘菜单
cmd/portal/       xdg-desktop-portal 的 ScreenCast 授权，必须独立进程
cmd/cursor/       收 KWin 脚本发来的光标坐标，写 cursor.pos
cmd/imgtest/      手动比对编码器输出的小工具
```

`cmd/portal` 和 `cmd/cursor` 为什么是独立进程：MoonBit 的 async 是单线程事件循环，
而 moondbus 是同步阻塞的。塞进主服务会把整个事件循环卡死。

## 会咬人的地方

**白盒测试里任何会触发抓帧的路径都必须给 `fake=`。** 不给的话 `capture()` 会去调
真实的抓屏：有 PipeWire 就走 PipeWire，否则拉起 spectacle。测试进程通常没有
`DISPLAY`，spectacle 的 Qt 初始化会直接 `abort()`，每跑一次测试就在系统里留一个
核心转储（用户那边会看到一串崩溃提示）。

**临时测试必须与生产状态目录隔离。** 端口文件、portal 记录和错误日志都写入
`$XDG_STATE_HOME/screen-kacha`（默认是 `~/.local/state/screen-kacha`）。手动启动临时
服务时，应将 `XDG_STATE_HOME` 指向本次测试的临时目录，避免覆盖生产状态。现有
`smoke.sh` 和 `smoke-instances.sh` 会自行创建并清理临时状态目录。多实例并发测试中，
同一轮的实例应共用这个临时 `XDG_STATE_HOME`，由 `instances/<名称>` 验证实例状态隔离；
不要把测试状态写入生产目录。

**光标合成在 C 里，尺寸从 PNG 头里读。** 两套素材（无尾巴 / 带尾巴）尺寸不同，
但代码里不写死宽高，换素材不用改常量。合成走 `moonimage` 的 `cursor_overlay`。

**libpng 要绕开 gamma 转换。** 它的简化接口（`png_image_*`）读出来会做 gamma 校正，
128 变成 186，整张图亮一档，而且 `PNG_IMAGE_FLAG_COLORSPACE_NOT_sRGB` 关不掉。
必须用完整接口，只要不调 `png_set_gamma`，值就和文件里写的一致。

**C 不能往 MoonBit 的 `Bytes` 里写。** `Bytes` 是不可变的，C 侧写进去会 SIGSEGV。
需要 C 回填数据就走静态变量加 getter，见 `pw_shim.c` 的 `moonbit_pw_saved_w`。

**FFI 返回 `int32_t` 必须声明成 `Int32`。** MoonBit native 的 `Int` 是 64 位，
声明成 `Int` 会把高 32 位读成垃圾。

**每个 `moon.pkg` 只能有一个 `options(...)` 块。** 写两个包发现会直接失败。

**链接参数不向下游传递。** `moonimage` 的 `-ljpeg -lwebp -lpng` 只对编译它自己生效，
用到它的包要在自己的 `moon.pkg` 里补一条。CI 少装 `libjpeg-dev` 或 `libpng-dev` 就会在链接阶段挂。

**`human.html` 的加载方式。** `/` 返回一个外壳，加一行指向
`/for_human_use_browser.js` 的脚本；那段 JS 由服务端现场生成，把整份 `human.html`
转义进模板字符串，再用 `createContextualFragment` 插进文档。用
`innerHTML` 的话页面里的 `<script>` 不会执行，这是两者的关键区别。

**页面对 agent 不可见是设计。** 不执行 JS 的客户端只拿到外壳里那段说明文字，
不会下载十几 KB 界面。改外壳时别把界面内容塞回去。

## MoonBit 惯例

- 代码按块组织，每块用 `///|` 分隔，块之间顺序无关，可以逐块重构
- 测试文件：黑盒 `_test.mbt`，白盒 `_wbtest.mbt`
- 稳定的结果用 `assert_eq`；记录结构化调试输出才用 `debug_inspect`
- 生成物 `pkg.generated.mbti` 要跟着提交，`.mbti` 没变说明是纯重构
- 废弃块集中放同目录的 `deprecated.mbt`

工具链：`moon fmt` 格式化，`moon info` 更新接口，`moon ide peek-def` 跳定义，
`moon coverage analyze > uncovered.log` 看没覆盖到的部分。
