# moonpipewire

Linux 上从 PipeWire 取帧的最小 MoonBit 绑定，只在 native 后端可用。

取的是「一条已经存在的视频流节点」。节点怎么来由调用方负责
（通常走 xdg-desktop-portal 的 ScreenCast，见本项目的 `cmd/portal`）。

**PipeWire 本身没有按应用的授权**：能连上节点就能拿到帧。所以这里的
`app_name` 只决定这条流在 `pw-dump` / `pavucontrol` 里怎么显示。
「记住屏幕共享授权」是 portal 的事，而且身份是 portal 从调用进程的
systemd 单元 / 桌面文件推导出来的，传名字改变不了它。

## 用法

```moonbit
import "conglinyizhi/screenstream/moonpipewire" @pipewire

fn main {
  // 构造只记配置，不做 I/O
  let pw = @pipewire.PipeWire::new(app_name="my-app")
  // 连流，立刻返回：底层在 C 线程里跑 main loop
  if pw.connect(42) != 0 {
    abort()
  }
  let (w, h) = pw.size()
  let buf = Bytes::makei(w * h * 4, fn(_) { 0 })
  if pw.copy_frame(buf) > 0 {
    // buf 里是 BGRx，每行 w*4 字节
  }
  pw.disconnect()
}
```

落盘版本（给 magick 之类外部工具用）：

```moonbit
let n = pw.save_frame("/tmp/frame.bgra")
```

## 调用方必须自己加的链接参数

C stub 在库里编译，但最终链接发生在可执行文件上，所以**下游的 exe 包**要写：

```text
options(
  link: { "native": { "cc-link-flags": "-lpipewire-0.3" } },
)
```

不加会报未定义符号。头文件路径不需要下游操心。

## 边界

- 一个进程目前只能有一条流；重复 `connect` 直接返回成功
- 只做捕获侧：不做会话管理、不做格式转换；像素格式固定请求 BGRx
- 帧率跟随画面变化：静止时很慢，动起来才密集
