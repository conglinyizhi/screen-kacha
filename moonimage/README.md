# moonimage

BGRA 原始帧 → JPEG / WebP，带缩放。只在 native 后端可用。

只做本项目实际用到的两件事：输入是一个裸 BGRA 文件，输出是一个文件。
没有内存缓冲版本，不做解码，也不做通用图像处理。

底层是 `image_shim.c`，依赖 libjpeg（BSD/IJG 许可）、libwebp（BSD-3 许可）和
libpng（libpng License）。三者都允许静态或动态链接进闭源程序。

## 链接参数

MoonBit 不会把链接参数传给下游，所以用到这个包的包要在自己的
`moon.pkg` 里补一条：

```text
link: { "native": { "cc-link-flags": "-ljpeg -lwebp" } }
```

本包自己的 `moon.pkg` 里已经写了这一条，它只对编译本包生效，
对依赖你的包不生效。漏掉会在链接阶段报未定义符号。

## 用法

```mbt nocheck
import "conglinyizhi/screen-kacha/moonimage" @image

fn save(w : Int32, h : Int32) -> Unit {
  // 原尺寸存 JPEG，质量 80
  let ok = @image.bgra_to_jpeg("/tmp/frame.bgra", w, h, 0, 80, "/tmp/out.jpg")
  // 缩到宽 1280 存 WebP，质量 75
  let ok2 = @image.bgra_to_webp("/tmp/frame.bgra", w, h, 1280, 75, "/tmp/out.webp")
  println("jpg=\{ok} webp=\{ok2}")
}
```

## 参数

```text
bgra_to_jpeg(src, w, h, dst_w, quality, out) -> Bool
bgra_to_webp(src, w, h, dst_w, quality, out) -> Bool
```

- `src`：BGRA 文件路径，每像素 4 字节，顺序是蓝、绿、红、alpha
- `w`、`h`：源图宽高，必须和文件实际大小对得上，否则读越界
- `dst_w`：目标宽度。传 0 或大于等于源宽都表示不缩放
- `quality`：1 到 100
- `out`：输出文件路径
- 返回值：成功为 true。失败不抛异常，调用方自己决定怎么记错

## 缩放

按面积平均（box filter）。目标宽高按源图宽高比算，高度由宽度推出来：

```text
dh = (h * dw + w / 2) / w，且至少为 1
```

宽高比接近时，这比最近邻扎实得多，缩到一半以下也不会丢细节。
权重表在 C 里预先算好，内层循环用乘倒数代替整数除法。

## 线程

没有全局状态，同进程里多个线程各调各的没问题。传进来的路径由调用方负责，
本包不删任何文件。
