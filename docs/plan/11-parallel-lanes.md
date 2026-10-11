# 11 并行工作线（2026-10-11）

A5、A6 合入之后，剩下的代码工作分成以下几条线，多个 agent 同时开工。每条线只改自己负责的文件。需要改别人的文件时，在 PR 里提出，由协调者处理。

真机验收、Touch ID、合并授权不在任何一条线里，都由 Kevin 本人做。

## 工作线

| 线 | 内容 | 负责的文件 | 分支 / 目标 | 依赖 |
| --- | --- | --- | --- | --- |
| X1-3 | 恢复时提示模型；ACP 投影认识 inconclusive 和新的恢复 kind | `Sources/AgentDesktopGUI/Explorer`、`Provider`、`Codec`（只限提示词）、`Sources/AgentDesktopACP/Events` | x1-hint → x1-progress | #257、#259 |
| PR4 | `inbox.*`、`run.reconcile`、`diagnostics.export` | `Sources/AgentDesktopRuntime`（新子目录 Inbox/、Diagnostics/）、`contracts/runtime/v1` | pr4-* → main | 无 |
| A7 | MCP `--desktop-id`、CLI 只给 desktopId 就能 observe/act、`examples/neutral-agent`、SDK 一致性 | `Sources/AgentDesktopMCP`、`Sources/AgentDesktopCLI`、`sdks/`、`examples/` | a7-* → main | 无 |
| BUG | #249、#248、核对 #157 | Runtime 的 observe/act 路径、engine 的光标识别 | fix/* → main | 无 |
| UI-A | U1b-2 事件驱动 Store、U5 Runs 详情与动作记录（P19–P20）、U9 Inbox | `Store/`、`Pages/Loaders.swift`、`Pages/RunsPages.swift`、`Pages/Sections/InboxSection.swift`、`MockLanes/MockRuntime+Runs.swift`，以及新的 `Pages/Runs*.swift`、`Pages/Inbox*.swift` | ui-a-* → ui-lane-seams | 接缝；U9 等 PR4 |
| UI-B | U2b、U3 Desktop 控制（P12–P18：接管、交还、停止、控制状态） | `Pages/Desktop*.swift`、`Pages/DisplayAttach.swift`、`Pages/ScreenCaptureFrameSource.swift`、`Components/Desktop.swift`、`MockLanes/MockRuntime+Desktops.swift` | ui-b-* → ui-lane-seams | 接缝 |
| UI-C | U4 Agents（客户端、配对、授权、窗口授权、连接、撤销） | `Pages/Sections/AgentsSection.swift`、新的 `Pages/Agents*.swift`、`MockLanes/MockRuntime+Agents.swift` | ui-c-* → ui-lane-seams | 接缝 |
| UI-D | U6 设置（P21 通用、P02/P22 权限、P23–P26/P30 AI 与 GUI 配置、能力测试、用量） | `Pages/Sections/SettingsSection.swift`、新的 `Pages/Settings*.swift`、`MockLanes/MockRuntime+Settings.swift`；宿主里 settings 闭包的接线（`Sources/AgentDesktop` 中只限这一处） | ui-d-* → ui-lane-seams | 接缝 |
| UI-E | U7 Explorer 标签（P27–P29），一级 GUI Explorer 页 | `Pages/Sections/ExplorerSection.swift`、新的 `Pages/Explorer*.swift`、`MockLanes/MockRuntime+Explorer.swift` | ui-e-* → ui-lane-seams | 接缝 |

## 公共文件

下面这些文件只能在单独的 PR 里改，由协调者合并顺序：

- `Sources/AgentDesktopUI/MainWindowView.swift`
- `Sources/AgentDesktopUI/Runtime/MockRuntime.swift`
- `Sources/AgentDesktopUI/Runtime/MockLanes/MockLanes.swift`
- `Sources/AgentDesktopUI/Pages/Sections/SectionContext.swift`
- `Sources/AgentDesktopUI/Pages/Navigation.swift`
- `Components/Shell.swift`、`Basics.swift`、`Forms.swift`、`Records.swift`
- `Theme/Tokens.swift`
- `Runtime/RuntimePort.swift`
- `contracts/runtime/v1/*`：只有 PR4 线可以改。其他线需要新字段时，写进自己 PR 的“契约请求”。

UI 线需要新的通用组件时，先放在自己的文件里。几条线都要用到时，再由协调者提到公共文件。

## 模拟 Runtime 的接缝

- 每条 UI 线在 `Runtime/MockLanes/MockRuntime+<线>.swift` 里：
  - 把要模拟的方法写进 `<线>LaneMethods`；
  - 在 `<线>Lane(_:_:context:)` 里给出回答；
  - 状态放在 `Mock<线>Lane` 里。
- `MockRuntime.modeled` 会自动包含各线的方法，参数和结果仍然按契约校验。
- 各线读写 MockRuntime 已有的状态（desktops、runs、clients 等）时，都要在已持有的锁里进行。不要改 `MockRuntime.swift`。

## 共同规则

- 不合并 PR，不推 main，不 force-push，不 rebase 已推送的分支。合并按 PR + SHA，由 Kevin 授权。
- 不碰用户的屏幕：
  - 界面验收用离屏渲染（`SnapshotRenderer`），和线框图对照；
  - 不截 Kevin 的桌面，不建虚拟显示器，不启动真实应用；
  - 需要真实 Runtime 时只用测试副本（`/tmp/adt-<线>/`）。
- 不写登录钥匙串。
- 组件验收和页面验收分开记录：只有真实 Runtime、真实窗口、交互验证这一级才算页面交付（02 §2.2）。
- 每条线只用一个 worktree：磁盘紧张。
