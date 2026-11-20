# moonpipewire

Linux 上从 PipeWire 取一帧画面的最小 MoonBit 绑定。只在 native 后端可用。

取的是「一条已经存在的视频流节点」：怎么拿到节点由调用方负责
（通常走 xdg-desktop-portal 的 ScreenCast，见本项目的 `cmd/portal`）。

## 用法

```moonbit
import "conglinyizhi/screenstream/moonpipewire" @pipewire

fn main {
  // 构造只是记住配置，不做 I/O；和官方 http 的 Server::Server 一样分两步
  let pw = @pipewire.PipeWire::new(app_name="my-app")
  // node id 由 portal 或 pw-dump 给出来；start 立刻返回，底层在 C 线程里跑
  if pw.start(42) != 0 {
    abort()
  }
  let (w, h) = pw.size()
  // 取最新一帧的原始字节：BGRx，每行 w*4 字节
  let n = pw.save_raw("/tmp/frame.bgra")
  println("\{n} 字节，\{w}x\{h}")
  pw.stop()
}
```

## 调用方必须自己加的链接参数

C stub 在库里编译，但最终链接发生在可执行文件上，所以**下游的 exe 包**要写：

```text
options(
  link: { "native": { "cc-link-flags": "-lpipewire-0.3" } },
)
```

不加这条会报未定义符号。头文件路径不需要下游操心。

## 边界

- 一个进程只能开一条流（C 侧是单例），重复 `pipewire_start` 直接返回成功
- 只做捕获侧，不做会话管理、不做格式转换；像素格式固定请求 BGRx
- 帧率跟随画面变化：静止时很慢，动起来才密集
