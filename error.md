# 出错了怎么查

这个服务由两部分组成：**服务**（`screen-kacha`，监听 {{PORT}}）和**托盘**
（`screen-kacha-tray`，面板上的图标）。先看是哪一半不对，再往里查。

## 一、先看服务还活着没有

```sh
curl -s http://127.0.0.1:{{PORT}}/health
```

能拿到 JSON 说明服务正常，看字段：

| 字段 | 含义 |
|---|---|
| `ok` | `false` 表示最近一次抓帧失败 |
| `fails` | 连续失败次数，一直在涨就是有问题 |
| `err` | 最后一次失败的原因原文 |
| `frame_age_ms` | 上一帧多久以前抓的，太旧说明泵停了 |
| `cap_ms` | 单次抓帧耗时，上千毫秒说明桌面卡或抓帧方式有问题 |
| `source` | 当前取帧来源：`pipewire` / `spectacle` / `fake` |
| `access` | 当前访问控制策略 |

连不上就是服务本身没起来，跳到第三节。

## 二、托盘的问题

托盘把所有失败都写到一个固定文件里，**先看它**：

```sh
cat ~/.local/state/screen-kacha/last-error.txt
```

里面按时间倒序记着最近几次失败：时间、哪个动作、退出码、原始输出。
如果是空的，说明托盘没遇到过失败。

托盘的运行日志：

```sh
journalctl --user -u screen-kacha-tray -n 50 --no-pager
```

图标右下角的灯是状态：绿=正常，黄=刚启动还没抓到帧，灰=服务没响应，
红=采集失败。

## 三、服务的问题

```sh
systemctl --user status screen-kacha
journalctl --user -u screen-kacha -n 80 --no-pager
```

常见原因：

- **`Wayland socket 还没就绪`**：桌面还没起来，服务会自动重试，不用管
- **`PipeWire 还没有可用帧`**：屏幕共享会话断了，等它自己重连；
  一直不恢复会回落到 `spectacle`
- **`portal 没有给出 node`**：屏幕共享授权被取消或过期，
  重新授权一次（托盘菜单或重新登录都会触发）
- **端口被占**：`ss -ltnp | grep {{PORT}}` 看是谁

## 四、开机启动没生效

托盘菜单里的「开机启动」只能管 **用户级** unit（`systemctl --user`）。
如果系统里存在同名的**系统级** unit，托盘管不了它：

```sh
systemctl list-unit-files 'screen-kacha*' --no-pager    # 不带 --user
```

有输出就说明需要你自己用 `sudo systemctl disable ...` 处理，
否则两者会打架。

检查用户级 unit 的实际状态：

```sh
systemctl --user is-enabled screen-kacha screen-kacha-tray
```

## 五、访问被拒（403）

`/health` 里的 `access` 字段写着当前策略。配置在
`~/.config/screen-kacha/access.conf`：

```sh
cat ~/.config/screen-kacha/access.conf
```

回环地址永远放行；局域网和公网是两档开关。改完要重启服务才生效
（从托盘菜单改会自动重启）。

## 六、抓不到画面但服务是好的

```sh
curl -s http://127.0.0.1:{{PORT}}/health | grep source
```

- `spectacle`：说明 PipeWire 那条路没通，回落到截图工具了，能用但慢
- `pipewire`：正常，抓帧跟着画面变化，静止时帧龄变旧是正常的
- `fake`：有人用了 `--fake`，这不是真实画面

## 七、还是不行

把这几样一起带上再问：

```sh
curl -s http://127.0.0.1:{{PORT}}/health
cat ~/.local/state/screen-kacha/last-error.txt 2>/dev/null
journalctl --user -u screen-kacha -u screen-kacha-tray -n 100 --no-pager
```

能复现的话，记下当时点了菜单里的哪一项。
