# Agent Desktop

Agent Desktop 是面向用户的独立桌面产品：把支持范围内的桌面任务交给 Agent，看见执行过程，控制权限与成本，随时暂停接管，并确认交付结果。

本仓库只放产品：App 宿主、品牌、界面、安装更新和发布材料。虚拟显示、窗口、输入、截图、Agent 屏幕和控制协议来自引擎仓 [szrunworld/2ndscreen](https://github.com/szrunworld/2ndscreen)，以固定版本依赖，不在这里复制或修改。边界见 [docs/boundaries.md](docs/boundaries.md)，路线见 [docs/roadmap](docs/roadmap/)。

当前状态：阶段 0「宿主骨架」。产品能构建、能被识别、路由正确；任务工作台、审批、模型配置等产品功能尚未开始，见 [docs/features.md](docs/features.md)。

## 构建

要求 macOS 14 以上（在 macOS 15 Apple silicon 上开发）和 Xcode Command Line Tools。

```bash
./scripts/bundle-app.sh          # 产出 "build/Agent Desktop.app"
open "build/Agent Desktop.app"   # 菜单栏图标；首次启动会打开一个虚拟显示
```

脚本做的事：以 release 构建宿主和引擎的 `2ndscreen` 命令行，装进 bundle，用一个专用 keychain 里的自签证书签名（`~/Library/Keychains/agentdesktop-signing.keychain-db`，首次运行创建），并把产物来源写进 `Contents/Resources/build.json`。macOS 把屏幕录制和辅助功能授权绑定到签名证书，所以授权在重新构建后仍然有效。正式发布改用 Developer ID 签名和公证（路线 A04）。

脚本会拒绝本地覆盖的依赖：`Packages/` 目录、`swift package edit` 状态，或 `.build/checkouts/2ndscreen` 里有改动时都不打包。

单元测试：`swift test`。本机只装 Command Line Tools 时没有 XCTest，测试由 CI（`.github/workflows/macos.yml`，macOS runner）运行。

## 命令行

包内有两个入口：

| 路径 | 作用 |
| --- | --- |
| `Contents/Resources/bin/agentdesktop` | 产品的命令行：同一个 `2ndscreen` CLI，默认连到本产品的 endpoint |
| `Contents/Resources/bin/2ndscreen` | 引擎的 CLI 本体，按 `SECONDSCREEN_SOCKET` 选择连接目标 |

```bash
CLI="build/Agent Desktop.app/Contents/Resources/bin/agentdesktop"
"$CLI" screen create --name demo --size 1280x800
"$CLI" screen list
"$CLI" screenshot --screen demo --output demo.png    # 需要给 Agent Desktop 屏幕录制权限
"$CLI" screen destroy demo
```

命令的完整说明在引擎仓 README。`2ndscreen task …` 在本阶段报「runtime 未安装」：task runtime 要等引擎发布不带业务 skills 的版本后再装进产品包（路线 C01）。`2ndscreen android …` 在产品里明确返回不支持。

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

- 产品版本独立于引擎版本。内部构建从 0.1.0-dev 开始。
- 引擎用 `exact` 固定在已发布 tag，`Package.resolved` 记录解析到的提交，一起提交。
- 引擎的脚本或接口改动先在引擎仓合并、发布新 tag，再改这里的依赖版本。不改旧 tag，不改 `.build/checkouts`。
- 本地试未发布的引擎改动只在开发时做，并且不进 CI 和发布构建。

## 文档

- [docs/boundaries.md](docs/boundaries.md)：组件边界、依赖方向、不进本仓的内容
- [docs/features.md](docs/features.md)：首发功能矩阵 F01–F12 与各项状态
- [docs/acceptance/](docs/acceptance/)：各阶段验收记录
- [docs/roadmap/](docs/roadmap/)：产品规划与路线图
