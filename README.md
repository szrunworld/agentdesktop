# Agent Desktop

AgentDesktop 是唯一维护桌面核心的项目。App、原生显示与输入、Runtime、视觉与学习、CLI/MCP、Windows 后端、测试和发布链都在同一仓库。核心不再依赖 `szrunworld/2ndscreen` 的 checkout、tag 或发布物。

2026-10-08 并仓决定及实施边界见 [架构](docs/architecture.md)、[迁入记录](docs/migration/2026-10-08-core-consolidation.md) 和 [Agent 交接](docs/agent-handoff.md)。源码迁入与真机验收分别记录。

## 当前代码

| 路径 | 职责 |
| --- | --- |
| `Sources/AgentDesktop` | 原生 App 身份、菜单、预览和宿主生命周期 |
| `engine/Sources/SecondScreenCore` | 显示、窗口、截图、AX、输入和系统适配 |
| `engine/Sources/SecondScreenRuntime` | 当前原生控制服务与 Desktop 资源 |
| `engine/Sources/TarsAgent` | 可复用的原生视觉、解析、探索、Learning/Procedure |
| `engine/Sources/ScreenCLI` | 原生 CLI 和 MCP 的现有工具 |
| `engine/windows` | C# 原生桌面后端、CLI、视觉、学习及测试 |
| `engine/optional/mobile` | 已保全的手机适配源码，未装配进默认 App |
| `engine/Tests` | 与核心一起迁入的原生测试 |

`engine/` 是本仓的本地 Swift package。内部模块名沿用现有代码标识，不代表第二产品或旧版本兼容承诺。完整源快照在本仓的导入提交中保全；旧 TS 宿主、Bridge、业务截图流和独立旧 App 已移出当前代码。以后复用历史语义时，从本仓导入提交提取算法和测试，不恢复旧入口。

## 构建

macOS 原生构建需要 Apple SDK；CI 使用 macOS 15。

```bash
swift build -c release --product AgentDesktop
swift build --package-path engine -c release --product agentdesktop-cli
swift test
swift test --package-path engine
./scripts/bundle-app.sh
```

公开命令只有 `Agent Desktop.app/Contents/Resources/bin/agentdesktop`，实际二进制为 `Resources/libexec/agentdesktop-cli`。默认 endpoint 是 `~/Library/Application Support/AgentDesktop/control.sock`；隔离测试实例显式设置 `AGENTDESKTOP_SOCKET`。不创建 `2ndscreen` 别名，不发现旧 App。

```bash
CLI="build/Agent Desktop.app/Contents/Resources/bin/agentdesktop"
"$CLI" screen create --name demo --size 1280x800
"$CLI" screen list
"$CLI" screenshot --screen demo --output demo.png
"$CLI" screen destroy demo
```

默认包包含原生 App 和 CLI；不安装 Node 宿主、旧 task Runtime、BOSS 业务包或 Android 工具。根工作流验证本仓 Swift、Windows 后端和新包的真实 CLI/MCP 表面。签名、公证、权限、真实输入与并发的发布承诺需要各自目标环境证据。

## 与正在开发的新 AI/GUI 的关系

[PR #2](https://github.com/szrunworld/agentdesktop/pull/2) 在独立分支已有新的合同、配置、AiService、GuiAiProvider、GuiExplorer、运行库和 CLI。该分支的 T00 单仓迁移和 T01 原生执行边界尚未由其完成；本次保全这些新模块，后续在同一 Runtime 契约上接入当前核心。不要重新实现同名服务，也不要将桌面替身测试当作 G0 或真机通过。

BOSS 保留 Python 业务核心，Recruiting 保留服务端业务链。它们使用 AgentDesktop Runtime；招聘限额、去重、邮箱与简历入库不属于通用 GUI 核心。
