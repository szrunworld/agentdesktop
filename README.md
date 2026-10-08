# Agent Desktop

Agent Desktop 是面向用户的独立桌面产品：把支持范围内的桌面任务交给 Agent，看见执行过程，控制权限与成本，随时暂停接管，并确认交付结果。

本仓库是单仓：App 宿主、Runtime、CLI、AI/GUI、界面、安装更新和发布材料，以及原生引擎（虚拟显示、窗口、输入、截图、AX、Agent 屏幕和控制协议，`Sources/Engine`）。引擎源码于 2026-10-08 从 [szrunworld/2ndscreen](https://github.com/szrunworld/2ndscreen) v0.2.0 迁入，逐文件来源记在 [docs/migration/source-map.csv](docs/migration/source-map.csv)；构建不再拉取 2ndscreen。边界见 [docs/boundaries.md](docs/boundaries.md)，路线见 [docs/roadmap](docs/roadmap/)。

当前状态：阶段 0「宿主骨架」已于 2026-10-07 在目标机验收关闭。首发方向以 [docs/product-baseline.md](docs/product-baseline.md) 为准：供外部 Agent 调用、多 desktop 真并发的桌面执行工具；下一里程碑是 M0 并发验证（[docs/acceptance/m0-concurrency-plan.md](docs/acceptance/m0-concurrency-plan.md)）。任务工作台等界面退出首发主界面，[docs/features.md](docs/features.md) 保留为旧矩阵。

## 构建

要求 macOS 14 以上（在 macOS 15 Apple silicon 上开发）和 Xcode Command Line Tools。

```bash
./scripts/bundle-app.sh          # 产出 "build/Agent Desktop.app"
open "build/Agent Desktop.app"   # 菜单栏图标；首次启动会打开一个虚拟显示
```

脚本做的事：核对引擎源码与来源清单一致（`scripts/verify-engine-source-map.sh`）、确认没有外部依赖，以 release 构建宿主（内含引擎）和 `agentdesktop` 命令行，装进 bundle，用一个专用 keychain 里的自签证书签名（`~/Library/Keychains/agentdesktop-signing.keychain-db`，首次运行创建）。签名后再在 `build/` 下生成保留完整 `.app` 结构的 zip 归档和分发清单 `Agent Desktop-<build>.manifest.json`，清单记录归档和包内每个文件的 SHA-256，可用 `scripts/verify-archive.sh` 校验。包内的 `Contents/Resources/build.json` 记录的是签名前的构建输入（引擎的迁入来源 tag 与提交、二进制的签名前哈希），用于追溯，不用于校验最终文件。macOS 把屏幕录制和辅助功能授权绑定到签名证书，所以授权在重新构建后仍然有效。正式发布改用 Developer ID 签名和公证（路线 A04）。

脚本会拒绝：`Sources/Engine`、`Tests/Engine` 下有文件与来源清单不符（标为 `copied` 的行字节必须一致；改过的文件要标 `modified` 并写明原因），有不在清单里的文件，或出现 `Package.resolved`、`Packages/`（回归用例在 `scripts/test-verify-engine-source-map.sh`）。第三方声明见 [docs/engine/THIRD_PARTY_NOTICES.md](docs/engine/THIRD_PARTY_NOTICES.md)，也随包放在 `Contents/Resources/THIRD_PARTY_NOTICES.md`。

单元测试：`swift test`（swift-testing，只装 Command Line Tools 也能跑）。CI 见 `.github/workflows/macos.yml`。

## 命令行

| 路径 | 作用 |
| --- | --- |
| `Contents/Resources/bin/agentdesktop` | 产品的正式命令行（`Sources/AgentDesktopCLI`，原生 Swift），经 `agentdesktop.runtime/1` 连接宿主里的 Runtime |

`agentdesktop` 按 CLI 方案 v1.2 逐步开放命令；目前是 PR1 的只读面：

```bash
CLI="build/Agent Desktop.app/Contents/Resources/bin/agentdesktop"
"$CLI" version
"$CLI" runtime start            # 没有 Runtime 应答时启动已安装的产品并等待握手
"$CLI" runtime status --format json
"$CLI" runtime capabilities     # 已实现的方法与 backend 权限/能力分开报告
"$CLI" doctor                   # 只读：endpoint、握手、版本、权限
"$CLI" desktop list
"$CLI" app list
"$CLI" window list --bundle-id com.apple.calculator
```

Runtime endpoint 是 `~/Library/Application Support/AgentDesktop/runtime.sock`（只允许当前用户，`runtime.sock.lock` 上的 flock 保证单实例）；测试副本的是 `<SECONDSCREEN_SOCKET 去掉扩展名>.runtime.sock`，用 `--endpoint` 或 `AGENTDESKTOP_ENDPOINT` 指过去。协议、方法表、错误码与退出码在 `contracts/runtime/v1/`，夹具在 `contracts/fixtures/runtime/v1/`。

屏幕、观察与输入等写操作已经在 `agentdesktop` 里（PR2）。旧引擎的 `2ndscreen` 命令行（以前装在 `bin/2ndscreen` 与 `libexec/2ndscreen`）随引擎迁入一起退出产品包：它是 2ndscreen 仓的 ScreenCLI，没有迁入本仓。宿主进程里的引擎控制 socket（`control.sock`）仍然存在。

## 角色、endpoint 与编号

| 角色 | 启动方式 | endpoint | 行为 |
| --- | --- | --- | --- |
| 产品宿主 | `open "build/Agent Desktop.app"` | `~/Library/Application Support/AgentDesktop/control.sock` | 菜单栏、主虚拟显示、⌃⌥⌘M 热键 |
| 测试副本 | `SECONDSCREEN_SOCKET=路径 open -n --env SECONDSCREEN_SOCKET=路径 "build/Agent Desktop.app"` | 环境变量指定 | 只在后台提供 Agent 屏幕，30 分钟空闲自动退出，产品宿主菜单的 Test Copies 可以退出它 |

endpoint 由 `Sources/AgentDesktop/HostRole.swift` 决定并显式传给引擎的 `AgentRuntime.start(socketPath:)`，不是从环境变量猜的。产品宿主和引擎的开发宿主 2ndscreen.app 用不同的 endpoint 与显示序列号（主屏 5，Agent 屏从 500 起；测试副本从 950 起），可以同机共存。两者目前各管各的屏幕，没有仲裁；共享协调者是路线 C02 的内容。产品宿主启动时的单实例检查只是「有人在监听就退出」，不是原子的所有权获取。

## 权限

| 权限 | 用途 | 何时申请 |
| --- | --- | --- |
| 屏幕录制 | 预览、截图 | 菜单里选 Show Preview；CLI 截图不会弹窗，需要在系统设置里授予 |
| 辅助功能 | 移动其他应用的窗口、`app launch` | 菜单里选 Grant Accessibility to Move Windows… |

授权归属 Agent Desktop 自己的身份，和 2ndscreen.app 的授权互不通用。新的屏幕录制授权在重新启动 App 后生效。

## 版本策略

- 产品版本是唯一的版本线。内部构建从 0.1.0-dev 开始。
- 引擎代码在本仓 `Sources/Engine` 里随产品一起改、一起评审、一起测试；没有外部 Swift 包依赖，也没有 `Package.resolved`。
- 改动迁入的引擎文件时，同一个 PR 把 `docs/migration/source-map.csv` 对应行改为 `modified` 并写明原因（`semanticChanges`），否则 CI 和打包都会拒绝。
- 从 2ndscreen 补迁后来的修复，按文件追加或更新来源行（来源仓、tag/提交、blob、sha256）。

## 文档

- [docs/boundaries.md](docs/boundaries.md)：组件边界、依赖方向、不进本仓的内容
- [docs/migration/source-map.csv](docs/migration/source-map.csv)：迁入源码的逐文件来源
- [docs/features.md](docs/features.md)：首发功能矩阵 F01–F12 与各项状态
- [docs/acceptance/](docs/acceptance/)：各阶段验收记录
- [docs/roadmap/](docs/roadmap/)：产品规划与路线图
