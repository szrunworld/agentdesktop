# 首发支持矩阵

只写已实现并有证据的范围。「默认」= 安装后不改任何设置即可用；「开关」= 需要用户显式打开；「不支持」= 本版本明确不提供，调用会被拒绝或入口不存在。证据列给出在哪里验证。

## 平台

| 项目 | 首发范围 | 证据 / 说明 |
| --- | --- | --- |
| 操作系统 | macOS 14 及以上（`LSMinimumSystemVersion` 14.0） | CI 在 macOS 15 构建与测试；实机验收在 macOS 15.1 |
| CPU 架构 | **仅 Apple 芯片（arm64）** | `scripts/release-smoke.sh` 报告宿主与 CLI 都是 `arm64`；`bundle-app.sh` 只构建本机架构。Intel 需要先做 universal 构建（见 [发布总览](README.md) 的未完成项） |
| Windows | **不在首发包内** | `windows/` 只有 ai/1 契约层与配置；`engine/windows` 是旧引擎的 C# 后端（CI 产出单文件可执行，不说 runtime/1）。Windows 原生 Runtime 未实现 |
| iPhone 镜像、Android | **不在首发包内** | 安卓工具不打包（`docs/boundaries.md`）；iPhone 镜像在 runtime/1 上被拒绝（`permission_denied / iphone_mirroring_blocked`） |

## 入口

| 入口 | 首发范围 | 说明 |
| --- | --- | --- |
| `agentdesktop` CLI | 默认，随包 | 包内唯一命令行：`Contents/Resources/bin/agentdesktop`。命令面由 `scripts/verify-command-surface.py` 检查 |
| MCP（stdio） | 默认，随包 | `agentdesktop mcp`；需先以 `--profile mcp` 配对。`--desktop-id` 限定单个 Desktop |
| Python / TypeScript SDK | 源码提供，未上架 | `sdks/python`、`sdks/typescript` 在仓库内，CI 跑单元测试；未发布到 PyPI / npm，不在 App 包内 |
| ACP | 不在首发包内 | 开发版桥与验收工具在 `scripts/acp/`，见 `docs/acp/` |
| AI/GUI 服务（`agentdesktop.ai/1`，`ai.sock`） | 诊断用，随宿主 | `agentdesktop ai`、`agentdesktop rpc` 命令组；首发界面里是可选诊断（设计 v2.0） |

## Runtime 能力（`agentdesktop.runtime/1`）

冻结契约 `contracts/runtime/v1/methods.json` 中标为 implemented 的方法共 96 个。打包后的 Runtime 实际提供：

| 状态 | 方法 | 证据 |
| --- | --- | --- |
| 默认提供 | 95 个：握手、状态、能力；Desktop 创建/列出/销毁、绑定状态与恢复；应用启动与列表；窗口列表、绑定与解绑；Session；observe / observe.region / observe.subscribe；act；wait；Run（start/attach/finish/show/events/wait/cancel/list）；stopAll / enableInput；artifact；events；Hub（配对、授权、窗口授权、物理显示器）；ai.* 配置 | `release-smoke.sh`：`methods.served = 95`，`notServed = [unit.run]` |
| 开关 | `unit.run`（GUI 单元执行） | 只在开启 GUI 执行器时提供：`defaults write com.agentdesktop.app guiExecution -bool true` 后重启 Agent Desktop。还需要在设置里配置模型连接（`directApiWithoutAi = false`）。`release-smoke.sh --gui-execution`：96/96 |
| 契约外 | 无 | 冒烟检查 Runtime 不提供契约之外的方法 |

调用任何方法前，客户端必须先**配对**并获得授权（A4）。未配对的客户端只能握手、读 `runtime.capabilities` 和做 `doctor` 诊断；`runtime status`、`desktop list`、`desktop create` 等都返回 `pairing_required`（退出码 4），冒烟逐条验证。

## 动作与观察

| 能力 | 首发范围 | 说明 |
| --- | --- | --- |
| 点击、按下（AX press）、输入文字、按键、滚动 | 默认 | 在虚拟 Desktop 上后台执行，不移动用户指针、不抢焦点 |
| 输入经剪贴板 | 不支持 | Runtime 强制拒绝（G2，#150）；系统剪贴板是共享资源，不做隔离 |
| 拖拽 | 不支持（macOS） | `unsupported_backend / background_drag_unsupported` |
| 悬停 | 不支持（macOS） | 后台悬停只能实现为中键点击，`unsupported_backend / background_hover_unsupported`（#263 方案 B） |
| 截图范围 | 只截绑定的窗口 | 被遮挡时 observe 与输入都拒绝（G0）；动作回执 `businessResult = not_evaluated`，业务是否成功由调用方观察判断 |
| 物理显示器（你自己的屏幕） | 默认关闭，用户逐个开放 | 只能在主窗口里开放给已配对程序并用 Touch ID 确认；每个窗口还要单独授权（`windows request`） |
| 主窗口实时预览 | 整个显示器 | ScreenCaptureKit 整屏预览并明确标注（D48 过渡方案）；窗口级采集为后续任务 |

## 安全与签名

| 项目 | 当前开发包 | 正式发布要求 |
| --- | --- | --- |
| 签名 | 本地自签证书（`Agent Desktop Local Signing`），无 Team ID，未开 hardened runtime | Developer ID + hardened runtime + 公证，见 `docs/release/a4-release-gate.md`（S4，发布阻断项）与 PR #300 |
| Gatekeeper | 拒绝（`spctl` rejected）：从网上下载的 zip 会被隔离，双击打不开 | 公证并 staple 后通过 |
| CLI 身份级别 | `same_user` | `verified` |
| 凭据存放 | 传统钥匙串（测试副本用独立钥匙串文件） | Data Protection 钥匙串 + 产品 access group（#300） |

开发包可以用于内部测试；**不得作为正式版本分发**，直到 S4 七项全部勾选。
