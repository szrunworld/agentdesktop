# Agent Desktop

AgentDesktop 是唯一维护桌面核心的项目。App、原生显示与输入、Runtime、视觉与学习、CLI/MCP、Windows 后端、测试和发布链都在同一仓库。核心不再依赖 `szrunworld/2ndscreen` 的 checkout、tag 或发布物。

2026-10-08 并仓决定及实施边界见 [架构](docs/architecture.md)、[迁入记录](docs/migration/2026-10-08-core-consolidation.md) 和 [Agent 交接](docs/agent-handoff.md)。源码迁入与真机验收分别记录。

## 当前代码

| 路径 | 职责 |
| --- | --- |
| `Sources/AgentDesktop` | 原生 App 身份、菜单、预览和宿主生命周期 |
| `Sources/AgentDesktopRuntime` 等 | 统一 Runtime（agentdesktop.runtime/1）、Protocol、Client、CLI、AI/GUI、Service、界面 |
| `engine/Sources/SecondScreenCore` | 显示、窗口、截图、AX、输入和系统适配 |
| `engine/Sources/SecondScreenRuntime` | 当前原生控制服务与 Desktop 资源 |
| `engine/Sources/TarsAgent` | 可复用的原生视觉、解析、探索、Learning/Procedure |
| `engine/Sources/ScreenCLI` | 引擎开发用的旧 CLI/MCP（`agentdesktop-cli`），不进产品包 |
| `engine/windows` | C# 原生桌面后端、CLI、视觉、学习及测试 |
| `engine/optional/mobile` | 已保全的手机适配源码，未装配进默认 App |
| `engine/Tests` | 与核心一起迁入的原生测试 |

`engine/` 是本仓的本地 Swift package。内部模块名沿用现有代码标识，不代表第二产品或旧版本兼容承诺。完整源快照在本仓的导入提交中保全；旧 TS 宿主、Bridge、业务截图流和独立旧 App 已移出当前代码。以后复用历史语义时，从本仓导入提交提取算法和测试，不恢复旧入口。

## 构建

macOS 原生构建需要 Apple SDK；CI 使用 macOS 15。

```bash
swift build -c release --product AgentDesktopApp
swift build -c release --product agentdesktop
swift test
swift test --package-path engine
./scripts/bundle-app.sh
```

脚本做的事：核对 `engine/` 是本仓源码（`scripts/check-local-engine.sh`，解析前后各一次），以 release 构建宿主（链接本地 `engine/` 的 SecondScreenCore / SecondScreenRuntime）和 `agentdesktop` 命令行，装进 bundle，用一个专用 keychain 里的自签证书签名（`~/Library/Keychains/agentdesktop-signing.keychain-db`，首次运行创建）。签名后再在 `build/` 下生成保留完整 `.app` 结构的 zip 归档和分发清单 `Agent Desktop-<build>.manifest.json`，清单记录归档和包内每个文件的 SHA-256，可用 `scripts/verify-archive.sh` 校验。包内的 `Contents/Resources/build.json` 记录签名前的构建输入（源码提交、引擎为本地 `engine/`、二进制的签名前哈希）。macOS 把屏幕录制和辅助功能授权绑定到签名证书，所以授权在重新构建后仍然有效。正式发布改用 Developer ID 签名和公证（路线 A04）。

没有远程 Swift 包依赖，也没有 `Package.resolved`；干净 checkout 构建不需要下载任何东西。

单元测试：`swift test`（根包）与 `swift test --package-path engine`（引擎包）。CI 见 `.github/workflows/macos.yml`、`windows-native.yml`、`windows-contracts.yml`。

## 命令行

公开命令只有 `Contents/Resources/bin/agentdesktop`：产品的正式命令行（`Sources/AgentDesktopCLI`，原生 Swift），经 `agentdesktop.runtime/1` 连接宿主里的 Runtime。引擎包里的旧 CLI（`engine/Sources/ScreenCLI`，产品名 `agentdesktop-cli`）只用于引擎开发，不进产品包；包里不再有 `libexec/` 和 `2ndscreen` 别名。`scripts/verify-command-surface.py` 在 CI 里检查打包后的命令面。

```bash
CLI="build/Agent Desktop.app/Contents/Resources/bin/agentdesktop"
"$CLI" version
"$CLI" runtime start            # 没有 Runtime 应答时启动已安装的产品并等待握手
"$CLI" runtime status --format json
"$CLI" runtime capabilities     # 已实现的方法与 backend 权限/能力分开报告
"$CLI" doctor                   # 只读：endpoint、握手、版本、权限
"$CLI" desktop create --name demo --size 1280x800
"$CLI" desktop list
"$CLI" app list
"$CLI" window list --bundle-id com.apple.calculator
```

Runtime endpoint 是 `~/Library/Application Support/AgentDesktop/runtime.sock`（只允许当前用户，`runtime.sock.lock` 上的 flock 保证单实例）；测试副本用 `AGENTDESKTOP_SOCKET=<路径>` 启动，其 Runtime endpoint 是 `<AGENTDESKTOP_SOCKET 去掉扩展名>.runtime.sock`，用 `--endpoint` 或 `AGENTDESKTOP_ENDPOINT` 指过去。协议、方法表、错误码与退出码在 `contracts/runtime/v1/`，夹具在 `contracts/fixtures/runtime/v1/`。

安装、支持范围、故障处理与发布步骤见 [docs/release](docs/release/README.md)；`scripts/release-smoke.sh` 按新用户拿到归档的方式检查它（解压、来源一致、测试副本上的实际能力、未配对拒绝）。

默认包只含原生 App 和 `agentdesktop`；不安装 Node 宿主、旧 task Runtime、BOSS 业务包或 Android 工具。签名、公证、权限、真实输入与并发的发布承诺需要各自目标环境证据。

## 与正在开发的新 AI/GUI 的关系

新的合同、配置、AiService、GuiAiProvider、GuiExplorer、Runtime 和 CLI 在 `ai-gui-foundation` 分支（[PR #2](https://github.com/szrunworld/agentdesktop/pull/2)）。计划 A0 把 main 的 `engine/` 合入该分支：新 Runtime 与 App 链接本地 `engine/`，只发布 `agentdesktop` 一个 CLI。不要重新实现同名服务，也不要将桌面替身测试当作 G0 或真机通过。

BOSS 保留 Python 业务核心，Recruiting 保留服务端业务链。它们使用 AgentDesktop Runtime；招聘限额、去重、邮箱与简历入库不属于通用 GUI 核心。
