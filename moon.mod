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

name = "conglinyizhi/screenstream"

version = "0.1.0"

readme = "README.mbt.md"

repository = ""

license = "Apache-2.0"

keywords = [ ]

preferred_target = "native"

description = "HTTP screen snapshot service for the local desktop (KDE Wayland)"

import {
  "bobzhang/crescent@0.11.2",
  "moonbitlang/async@0.20.3",
  "conglinyizhi/moondbus@0.1.2",
  "conglinyizhi/moonsni@0.1.2",
}
