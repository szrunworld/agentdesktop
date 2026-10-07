# Agent Desktop

Agent Desktop 是面向用户的独立桌面产品：把支持范围内的桌面任务交给 Agent，看见执行过程，控制权限与成本，随时暂停接管，并确认交付结果。

本仓库只放产品：App 宿主、品牌、界面、安装更新和发布材料。虚拟显示、窗口、输入、截图、Agent 屏幕和控制协议来自引擎仓 [szrunworld/2ndscreen](https://github.com/szrunworld/2ndscreen)，以固定版本依赖，不在这里复制或修改。边界见 [docs/boundaries.md](docs/boundaries.md)，路线见 [docs/roadmap](docs/roadmap/)。

当前状态：阶段 0「宿主骨架」已于 2026-10-07 在目标机验收关闭，A02 前置已有主窗口、权限向导、任务界面结构和 TaskClient 类型；真实任务数据要等引擎的 C03 任务视图接口。各项进度见 [docs/features.md](docs/features.md)。

## 构建

要求 macOS 14 以上（在 macOS 15 Apple silicon 上开发）和 Xcode Command Line Tools。

```bash
./scripts/bundle-app.sh          # 产出 "build/Agent Desktop.app"
open "build/Agent Desktop.app"   # 菜单栏图标；首次启动会打开一个虚拟显示
```

脚本做的事：解析依赖并核对引擎 checkout 与锁定提交完全一致，以 release 构建宿主和引擎的 `2ndscreen` 命令行，装进 bundle，用一个专用 keychain 里的自签证书签名（`~/Library/Keychains/agentdesktop-signing.keychain-db`，首次运行创建）。签名后再在 `build/` 下生成保留完整 `.app` 结构的 zip 归档和分发清单 `Agent Desktop-<build>.manifest.json`，清单记录归档和包内每个文件的 SHA-256，可用 `scripts/verify-archive.sh` 校验。包内的 `Contents/Resources/build.json` 记录的是签名前的构建输入（引擎版本与提交、二进制的签名前哈希），用于追溯，不用于校验最终文件。macOS 把屏幕录制和辅助功能授权绑定到签名证书，所以授权在重新构建后仍然有效。正式发布改用 Developer ID 签名和公证（路线 A04）。

脚本会拒绝本地覆盖的依赖：`Packages/` 目录、`swift package edit` 状态，或 `.build/checkouts/2ndscreen` 不在锁定提交、有工作区改动、有暂存改动或有未跟踪文件时都不打包（`scripts/check-engine-checkout.sh`，回归用例在 `scripts/test-check-engine-checkout.sh`）。

单元测试：`swift test`（swift-testing，只装 Command Line Tools 也能跑）。CI 见 `.github/workflows/macos.yml`。

## 主窗口

产品宿主有 Dock 图标和主窗口，侧栏四个入口对应路线文档第五节的界面组织表：

| 入口 | 现在有什么 |
| --- | --- |
| 任务主页 | 当前、历史列表与任务详情：当前步骤、等待原因、心跳、执行者、结果与验证、产物、用量，以及服务此刻允许的操作按钮 |
| Agent | 官方参考 Agent 占位、已导入列表（空）、本 runtime 托管过任务的 agent |
| 待处理 | 等待审批、提问、登录、中断核对与结果不明的任务，在详情里处理 |
| 设置 | 权限向导（屏幕录制、辅助功能、task runtime 的真实检测与申请入口）、任务数据来源、构建来源 |

关闭主窗口不退出 App，宿主、工作屏和任务继续；菜单栏的 **Open Agent Desktop** 或点 Dock 图标重新打开。菜单栏还有 **Emergency Stop (agent screens only)**：销毁全部工作屏，这只是按任务取消落地前的占位，按钮名里写明了范围。测试副本没有主窗口和 Dock 图标。

任务数据来自 `Sources/AgentDesktop/TaskClient` 的薄客户端，类型按引擎仓 `docs/task-client-contract.md`（C03 草案，版本 0）翻译：

- `CLITaskClient`：产品默认，调包内 `bin/agentdesktop task service|views|view|control`。当前 runtime 还没有这些子命令、产品包里也没有 runtime，所以界面显示「未安装 Runtime」或「服务缺少这项能力」，并给出下一步。
- `SampleTaskClient`：覆盖契约全部状态与操作组合的样例数据，只用于界面开发。设置页可切换，或启动时设 `AGENTDESKTOP_TASK_CLIENT=sample`。
- 停止与暂停按契约区分「请求已受理」与「执行者已停止」：收到回执只显示停止中，视图里 `executor.stopped` 为真才显示已停止；没有执行者记录时继续显示停止中，并标注「缺少执行端停止证据」。
- 点击操作按钮时重新核对服务状态、`task.control` 能力和该任务最新的 `allowed`，不只看缓存的按钮列表。批准、拒绝、绑定账号、重新提交需要契约固定的输入（待处理条目、账号作用域、原任务输入），服务提供前按钮禁用并说明。
- 服务身份分两层：`host`（产品、bundle id、pid、原生控制协议版本、引擎提交）和 `task`（本契约版本、runtime 版本、能力）。
- `Tests/AgentDesktopTests/Fixtures/task-view-sample.json` 是与契约文档一致的共享样本，两端都用它做解码测试。

## 命令行

受支持的入口只有 `Contents/Resources/bin` 下的两个名字，它们是同一个脚本：

| 路径 | 作用 |
| --- | --- |
| `Contents/Resources/bin/agentdesktop` | 产品的命令行 |
| `Contents/Resources/bin/2ndscreen` | 同一个命令，沿用引擎的命令名 |
| `Contents/Resources/libexec/2ndscreen` | 引擎 CLI 的二进制本体，不作为入口使用 |

入口脚本把 `SECONDSCREEN_SOCKET` 默认指到本产品的 endpoint（测试副本时可以自己指定），并把 `SECONDSCREEN_TASK_RUNTIME` 固定绑定到本产品包内的 `Contents/Resources/task-runtime`。这样 `task` 命令和 MCP 里派生 task 子进程的工具只会用产品自己的 runtime；目录还不存在时直接返回 `capability_missing`，不会退回到正在运行的 2ndscreen.app 里的 runtime。直接执行 `libexec` 里的二进制不在支持范围内，它会按引擎自己的规则去找 runtime。

```bash
CLI="build/Agent Desktop.app/Contents/Resources/bin/agentdesktop"
"$CLI" screen create --name demo --size 1280x800
"$CLI" screen list
"$CLI" screenshot --screen demo --output demo.png    # 需要给 Agent Desktop 屏幕录制权限
"$CLI" screen destroy demo
```

命令的完整说明在引擎仓 README。`agentdesktop task …` 在本阶段返回 `capability_missing`，消息里是产品包内尚不存在的 runtime 路径：task runtime 要等引擎发布不带业务 skills 的版本后再装进产品包（路线 C01）。`agentdesktop android …` 在产品里明确返回不支持。

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
