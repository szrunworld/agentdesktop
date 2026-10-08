# A0 仓库收敛验收记录（2026-10-08）

对应：docs/plan/02-implementation-plan.md §2.4 A0。做法：把 main@501ff01（含 #20 迁入的 `engine/`）**合并**进 ai-gui-foundation@b2a8fc0（不改写 foundation 历史）。

## 冲突与处理

| 文件 | 处理 |
| --- | --- |
| `Package.swift` | 保留 foundation 的全部 target/产品/测试；依赖改为 `.package(path: "engine")`，`AgentDesktop` 与 `AgentDesktopRuntime` 的 `SecondScreenCore`/`SecondScreenRuntime` 来自 package `engine`；远程 2ndscreen 0.2.0 pin 与 `Package.resolved` 删除 |
| `scripts/bundle-app.sh` | 采用 main 的本地引擎流程（`check-local-engine.sh` 解析前后各一次，build.json 记录 `engine.kind=local`）；产品包只放宿主与 foundation 的 `agentdesktop`；不再构建/打包 `agentdesktop-cli`（engine ScreenCLI）或 `2ndscreen` 别名，出现即拒绝 |
| `.github/workflows/macos.yml` | 保留 main 的「Core is local」与 `swift test --package-path engine`；保留 foundation 的原生 CLI 检查；删除旧 `bin/2ndscreen task` 检查；命令面检查改用更新后的 `verify-command-surface.py` |
| `README.md` | 以 main 为底，命令行一节换成新 `agentdesktop`；测试副本变量改为 `AGENTDESKTOP_SOCKET` |
| `scripts/verify-command-surface.py` | 改为新命令面：help 列出当前命令；旧入口（screen/screenshot/task/agent-bridge/agent/mcp）以参数错误（退出 2）拒绝且不连接；包内没有第二个命令行、没有 `libexec/` |
| `Sources/AgentDesktopCLI/ContractCLI.swift` | 语义冲突：main 把测试副本变量从 `SECONDSCREEN_SOCKET` 改为 `AGENTDESKTOP_SOCKET`（`HostRole`），这里同步改读 `AGENTDESKTOP_SOCKET`（一行） |
| `docs/boundaries.md` | 以 main 为底，追加 A0 的构建与发布规则 |

main 删除的旧入口（80e0ed4：engine 内的 SecondScreen App、Bridge、TS task host、TaskCommand 等）保持删除；foundation 代码不依赖它们。

## 验证（直接看退出码）

| 项目 | 结果 |
| --- | --- |
| `scripts/check-local-engine.sh` | 0 |
| `swift package resolve` | 0；无 `Package.resolved`，无 `.build/checkouts/2ndscreen` |
| `swift build` | 0 |
| `swift test`（根包） | 0；355 通过，2 个按设计跳过（Live model） |
| `swift test --package-path engine` | 0；127 通过 |
| `scripts/bundle-app.sh` | 0；包内 5 个文件：`MacOS/Agent Desktop`、`bin/agentdesktop`、`build.json`、`Info.plist`、`CodeResources` |
| `codesign --verify --strict`、`verify-archive.sh` | 通过（5 个文件） |
| `verify-command-surface.py` | `{"commands": 16, "oldEntries": "refused", "otherCommandLines": 0}` |

## 测试副本真机冒烟（/tmp/adt-eng-a0，未触碰产品 endpoint）

`open -n --env AGENTDESKTOP_SOCKET=/tmp/adt-eng-a0/side.sock`，Runtime endpoint `/tmp/adt-eng-a0/side.runtime.sock`。

| 步骤 | 结果 |
| --- | --- |
| `desktop create --size 1280x800` | ready，displayId 13 |
| `app launch --bundle-id com.apple.calculator --new-instance` | pid 70266，窗口 2375 在该 Desktop 上 |
| `window bind` + `observe --image-output` | 2560x1600 截图（scale 2）与元素 |
| `session open` + `act click`（按钮 7） | `dispatched/completed`，route `ax.press`；再次 observe 显示值为 `7` |
| `runtime stop-all` 后再 `act click` | 退出 5，`input_disabled`，`notSent: true` |
| `session close`、`desktop destroy` | 计算器随 Desktop 退出（`quitApps` 含 70266） |
| 收尾 | SIGTERM 结束副本，删除 `/tmp/adt-eng-a0` |

## SEC-01…SEC-05

| 项 | 结果 |
| --- | --- |
| SEC-01 文件权限 | **未通过**：新实例的 socket、`runs.sqlite`、`requests.sqlite` 为 0600，目录 0700；但 `ai.sqlite`（及 -wal/-shm）为 **0644**。目录 0700 挡住了他人访问，但不满足「文件 0600」。属于 A3「存储权限」范围，本 PR 未改 |
| SEC-02 凭据存放 | 未验证（需要写入一个凭据后检查数据库与日志） |
| SEC-03 测试副本隔离 | 部分验证：副本的 socket、数据库、记录目录都在 `/tmp/adt-eng-a0` 下，凭据目录为 `side.runtime/test-credentials`（文件凭据，`HostRole.credentialBackend`），未读写登录钥匙串 |
| SEC-04 其他本机用户 | 未用另一用户验证；仅从权限位推断（目录 0700） |
| SEC-05 产品与副本同时运行 | 未验证（按要求不启动产品实例） |

## 未完成 / 待决

- **唯一 Runtime 入口未完成**：宿主仍在 `Sources/AgentDesktop/AppController.swift` 的 `applicationDidFinishLaunching` 里调用 `runtime.start(socketPath: endpoint.path)`（约第 145 行），为引擎 `AgentRuntime` 打开旧控制 socket `control.sock`；同时 `startRuntimeServer()` 打开 `runtime.sock`，`startAIService` 打开 `ai.sock`。`AgentRuntime` 还是 `EnginePlatform` 的进程内后端（`AgentRuntime.handle`），所以不能直接删对象，只能停掉其 socket（`start` 只负责 ControlServer，需确认 `hostScreens`/`onScreensChanged` 等不依赖它）。本 PR 未改。
- `engine/Package.swift` 仍声明 `agentdesktop-cli`（ScreenCLI）与 `vdisplay` 产品，供引擎开发和测试；它们已退出发布路径。
- `docs/plan/02` 写的是「foundation rebase 到 main」，本 PR 按协调者要求改为把 main 合并进 foundation。
