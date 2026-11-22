// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "conglinyizhi/screen-kacha"

version = "0.1.0"

readme = "README.mbt.md"

repository = "https://github.com/conglinyizhi/screen-kacha"

license = "Apache-2.0"

keywords = [
  "screenshot",
  "screen-capture",
  "pipewire",
  "wayland",
  "jpeg",
  "webp",
]

preferred_target = "native"

description = "HTTP screen snapshot service for the local desktop (KDE Wayland)"

import {
  "conglinyizhi/moon-embed@0.3.0",
  "moonbitlang/async@0.22.10",
  "conglinyizhi/moondbus@0.1.6",
  "conglinyizhi/moonsni@0.1.5",
}
