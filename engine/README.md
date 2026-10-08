# AgentDesktop native core

This is a local package in AgentDesktop, maintained and released with the product. It is not a dependency on the retired source repository.

- `SecondScreenCore`: current native display, window, observation and input implementation.
- `SecondScreenRuntime`: current host service and desktop lifecycle.
- `TarsAgent`: reusable model, parser, planner, learning and procedure code.
- `ScreenCLI`: `agentdesktop-cli`, packaged as the public `agentdesktop` command.
- `windows`: existing C# backend and its tests, distinct from the new AI/GUI contract layer.
- `optional/mobile`: retained phone adapters; not enabled by the default product.

Internal identifiers remain implementation details. There is no old App product, Bridge command, TS task host, old CLI alias or old configuration fallback. Use root build scripts and [current architecture](../docs/architecture.md). The complete import and historical semantic tests remain available from this repository's source-import commit.

## iPhone（iPhone Mirroring 后端）

`agentdesktop iphone show|screenshot|tap|type|key|hide` 与 `agent --iphone` 通过 Mac 上的 iPhone Mirroring 操作手机。逐项能力与宿主影响以 `Sources/TarsAgent/IPhoneCapabilities.swift` 为准，设备会话契约草案见 [docs/ios](../docs/ios/README.md)。

宿主影响分项说明，不能概括为“完全后台”：

- **不移动真实指针**：所有动作都是投递给镜像进程的事件。
- **点击会短暂借用键盘焦点**：tap 先把镜像窗口设为 key window（不提升、不置前），点击后把焦点还给用户窗口。
- **⌘ 快捷键会瞬时激活镜像**：Home（⌘1）、App Switcher（⌘2）、Spotlight（⌘3）在事件入队的瞬间把 iPhone Mirroring 设为前台，随后恢复原前台应用。
- **输入占用宿主剪贴板**：type 把文本写入 Mac 剪贴板，以单独按下 ⌘ 的方式发送 ⌘V（不激活镜像），需要时点按手机上的“允许粘贴”，再把剪贴板放回。目前只备份纯文本，期间不要复制其他内容。
- 2026-10-04/07 实测：点击、按键、粘贴前后真实指针位置和前台应用未见变化。

本后端范围内的手势：后台投递的滚轮事件、触控板滚动阶段和多种写法的拖动都没有作用到手机上，方向键也无效；长按未实现。因此本后端不公布滑动、滚动、拖动、长按，模型要求拖动时直接拒绝，不降级成点击，也不借用真实鼠标。这是本后端的限制，不是 iPhone Mirroring 本身的限制：Apple 说明用户用鼠标或触控板可以在镜像里滑动和滚动。完整手势由 WDA / CoreDevice 后端另行评估。
