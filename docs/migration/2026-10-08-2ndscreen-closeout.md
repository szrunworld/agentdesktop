# 2ndscreen 冻结与收尾 — 2026-10-08

Kevin 2026-10-08 批准：冻结 2ndscreen 的引擎开发，AgentDesktop 是唯一的代码真源；不再维护 2ndscreen，不再兼容未发布的旧架构，不再为历史设计保留第二套 Runtime。本文记录对 2ndscreen 当时开着的 7 个 PR 的处置，以及由此转入本仓库的待办。源 PR 的固定 head 与补丁摘要见 [2ndscreen-open-prs.json](2ndscreen-open-prs.json)；引擎导入见 [2026-10-08-core-consolidation.md](2026-10-08-core-consolidation.md)。

## 一、前提

引擎在 [`49218be`](https://github.com/szrunworld/agentdesktop/commit/49218be42ed0af1cdaeee424d684103551d79a31) 从 2ndscreen `da5677c` 完整导入 `engine/`，`da5677c` 即 2ndscreen 主线当时的 tip。导入后本仓库改了 29 个引擎文件、新增 8 个；2ndscreen 侧没有新的引擎改动。漂移是单向的，`engine/` 的真源只在本仓库。

## 二、7 个 PR 的处置

状态用三档：**已合入 foundation**（在 `ai-gui-foundation` 上，尚未合入 `main`，真机验收以 `docs/acceptance/` 的记录为准）、**开发中**（有草案或工作分支，未合入 foundation）、**仅草案**（只有文档）。有代码不等于已验收。

| 2ndscreen PR | 决定 | 本仓库的对应物 | 状态 |
| --- | --- | --- | --- |
| #69 RFC 0003 视觉与 Agent 核心重写进 Runtime | 关闭 | `Sources/AgentDesktopGUI`（`Codec/UITarsCodec`、`Explorer/GuiRunDriver`、`Explorer/RunRecorder`）与 `Sources/AgentDesktopAI`；路线见 `docs/plan/05-gui-explorer-roadmap.md` | 编解码、探索循环、记录：已合入 foundation。unit.run 的 suggest / explore 两模式：开发中（#50 草案，A6 / PR2d）。手机适配：开发中（iOS 各线）。学习流程：仅预留（PR7） |
| #64 C03 任务客户端契约 | 关闭 | `contracts/runtime/v1`：`Run`、`RuntimeIdentity` + `Principal`、`CancelReceipt`、`RequestRecord`；`InboxItem` 预留在 PR4 | Run / 身份 / 回执：已合入 foundation。Inbox：仅预留。第三节的五项裁决转入 PR4 / PR6 设计评审 |
| #65 C01b 通用 task runtime 构建 | 关闭 | 无。本仓库没有 TypeScript 宿主（DEV-SPEC v1.0）；"产品包不含业务包"由 ADR v2.2 的独立 Agent App 架构满足 | 废弃 |
| #66 C02 端点所有权与 host.info | 关闭 | `Sources/AgentDesktopRuntime/IPC/RuntimeServer.swift` 的 flock 所有权；`runtime.handshake` 返回的 `RuntimeIdentity` | 已合入 foundation。诊断部分转为第四节的新 PR |
| #56 RFC 0002 ACP 双向集成 | 关闭 | `docs/acp/01-rfc-0002-revised.md`（acp-skeleton 分支，草案 PR #53） | 开发中：七条工作线已合入 acp-skeleton，全部在假 Runtime 上通过，不算端到端；ACP 不进首版（Kevin 裁决 K3） |
| #67 login_required 时记住 runtime 启动的应用 | 关闭 | `Sources/AgentDesktopRuntime/RuntimeService+Desktops.swift`：`app.launch` 时记入 desktop 的 `launched`，`desktop.destroy` 退出并回报 `quitApps`，不依赖 session 是否打开成功 | 已合入 foundation。对应的真机回归用例见第五节 |
| #68 2ndscreen macOS CI | 关闭 | `.github/workflows/macos.yml` 的 `swift test --package-path engine` | 已合入 foundation |

### 彻底废弃

`packages/task-runtime` 的 TS 宿主；旧版 Agent Bridge（`ScreenCLI/AgentBridge.swift`、`TarsAgent/Bridge.swift`）；2ndscreen 专属的 `task` / `acp` / `host info` 命令；已被 AgentDesktopGUI 取代的旧探索桥；C01 / C02 / C03 / C05 旧路线的后续开发。

废弃 TS Runtime 宿主不等于废弃薄 SDK。产品架构不变：AgentDesktop Runtime → 通用 CLI / API / SDK → 独立 Agent App。Python Agent Hub 与 TypeScript 薄 SDK 可以并存、各担其责，但不能形成第二套执行引擎。

## 三、#64 五项架构问题的裁决（Kevin，2026-10-08）

| 能力 | 决定 | 原因 |
| --- | --- | --- |
| `allowed` | 保留，P1 | UI 必须知道当前允许执行什么操作 |
| `settlesTo` | 保留语义，P1 | 用户需要知道控制命令受理后预期进入什么状态 |
| `heartbeat.stale` | 保留，P1 | 连接异常不能错误显示为正常执行 |
| `pause` / `resume` | 暂缓，P2 | 先明确哪些运行类型真正支持安全暂停 |
| `partial` outcome | 暂缓，P2 | 不宜立即扩展通用 Runtime 的最终结果模型 |

约束：

1. `allowed` 由 Runtime 按实际状态、权限和能力计算，前端不猜。BOSS 等业务专属操作不进通用契约。
2. `settlesTo` 是预期状态，不是执行成功的证明。控制回执继续区分已受理、已完成、结果未知，不破坏 ADR v2.2 的语义。
3. heartbeat 过期不代表 Run 已停止。UI 可以显示连接状态未知，但必须重新查询 Runtime 判断运行结果。

这三项进入 PR4 / PR6 的设计评审，不要求立刻扩展 `runtime/1`。

## 四、新 PR：Runtime Endpoint Ownership & Diagnostics

从 #66 提取。范围严格限定为：

- 锁文件增加运行实例身份信息（product、pid、instanceId、listening、since）。
- CLI 增加只读的 Runtime 状态诊断：端点离线时报告锁文件里的持有者。
- 迁移 #66 `EndpointOwnershipTests` 的 10 个端点所有权测试场景。
- 增加进程崩溃、残留锁文件、持锁者异常退出的测试。

锁文件记录是诊断线索，不是在线状态的权威证明：不能仅凭记录中的 PID 或 `listening = true` 断言 Runtime 仍在运行，必须考虑 PID 复用、进程异常退出和残留文件。不恢复 `host.info`，不恢复 TS bootstrap。本 PR 不阻塞 foundation 合并 main。

## 五、真机回归用例（来自 #67）

`app.launch` 启动应用 → session 因 `login_required` 打开失败 → `desktop.destroy` 仍退出该应用，并且不碰用户自己打开的应用。加入 `docs/plan/08-e2e-acceptance-plan.md` 的用例集。

## 六、对计划的影响

- 顺序不变：A0 → G0 → AX → PR2b → A6。第四节是新增小 PR，第三节只是把议题提前摆上桌。
- foundation 合并 main 的门槛不变：`d8c27c5` 的 macOS push CI 通过；PR #2 的 pull_request CI 通过；Runtime / 集成负责人完成本地测试副本冒烟；没有未解决的阻塞级问题；Kevin 明确批准前不合并 PR #2。
- 2ndscreen：不再接受功能性 PR；保留历史代码、PR 与 Git 历史；暂不 Archive，等 main 合并与真机验收后再考虑。所有新开发（macOS、Windows、Android、iPhone、GUI Explorer、ACP、Runtime）都在本仓库进行。
