# ACP 差距分析：现有代码与目标架构

状态：2026-10-08，工作线 D。

核对对象：`acp-skeleton`@2837bd4（基于 `ai-gui-foundation`@6c18480，A0 PR #47 已合入）。另查了 `origin/ai-gui-foundation`@b2831ca（多了 PR #51）与 PR #2、#29、#48、#50。每条都在代码里核对过；行号对应 2837bd4，另注明的除外。

负责方：**f1** = Runtime / 集成负责人 2ndscreen-f1；**40** = L-AIGUI 与 L-Win 2ndscreen-40；**ACP 线** = 本组 T/S/R/E/O/Q；**Kevin** = 产品决定。

## 一、差距总表

| 编号 | 目标需要 | 现状与证据 | 负责 | 阻塞 |
| --- | --- | --- | --- | --- |
| GAP-01 | 宿主只监听一个 Runtime 端点（A2，RT-01） | 引擎旧 `control.sock` 已不再打开：`AppController.swift:139-142` 改为 `runtime.startInProcess()`（f187ec7，随 #47 合入 6c18480；验收见 `docs/acceptance/a0-engine-merge-2026-10-08.md` 补充节）。但宿主仍开第二个监听 `ai.sock`：`AppController.swift:157-178` 的 `RpcSocketServer`，同 uid 一律 `trustedOwner: true`；它承载 ai/1 信封与 `gui.runs.*`，不进 RunStore | f1（A2 / PR2b） | G0 |
| GAP-02 | 发布物里没有第二个可启动的旧入口（T18） | `engine/Package.swift:8` 仍声明 `agentdesktop-cli`（`engine/Sources/ScreenCLI`，含 `MCPServer.swift`）；`AgentRuntime.start(socketPath:)` 仍在（`engine/Sources/SecondScreenRuntime/AgentRuntime.swift:45`）。不在发布包里（#47 验证 `bundle-app.sh` 只放一个 CLI），但本机自行编译即可开出一个不经 Runtime 的 socket | f1 | G0 |
| GAP-03 | 编辑器能交出一件任务（`unit.run`，A6） | `unit.run` 只在目录 `catalog` 里，状态 `frozen`、PR2d（`contracts/runtime/v1/methods.json:300`）；33 个已实现方法里没有它。PR #50 只有文档 `docs/ai-gui/a6-unit-run-draft.md`，开工门槛是 A0、G0、AX、PR2b 都合入 | 40（A6） | G1 |
| GAP-04 | 任务发现：列出调用方有权调用的任务 | runtime/1 没有任务目录方法。`unit_run_params` 是 GUI 目标（`desktopId`、`mode`、`goal`、`verification`、`allowedActions`，见 `runtime.schema.json`），不是「已注册任务」。`gui.procedures.*` 为 reserved（PR7） | f1（契约）、Kevin（范围） | G1 |
| GAP-05 | 握手返回已认证的 principal | `runtime.handshake` 只返回 `RuntimeIdentity`（`Sources/AgentDesktopProtocol/RuntimeModels.swift:56-67`；`RuntimeService.swift:173-184`），没有 `clientId`、`connectionId`。`docs/plan/03` 3.2 写的是「含 principal，已实现」 | f1 | G1（T06） |
| GAP-06 | 身份、配对、授权（A4） | 未实现。`hub.pairing.*`、`hub.clients.*`、`hub.grants.*`、`hub.connections.list` 都是 reserved、PR3（`methods.json:552-600` 一带）。每个本机连接都是 `local:<uid>`（`RuntimeService.swift:27`），且都是 owner，能看见并控制所有 Run（`RuntimeService+Runs.swift:9-15`） | f1（A4 / PR3） | G2（T07、T15） |
| GAP-07 | 审批与提问的 Runtime 方法 | `inbox.list/show/resolve` 为 reserved、PR4（`methods.json:618-630`）。`RunRecord.Phase.waitingApproval`、`waitingInput` 只有定义（`RunStore.swift:21`），代码里从不设置。错误码 `approval_required` 已在 `errors.json:55` | f1（PR4）；U9 界面 | G2（T16）、G3（T17） |
| GAP-08 | 事件类型目录（F1-01） | `RunEvent.type` 在 schema 里是自由字符串（`runtime.schema.json` 的 `RunEvent`）。实际发出：`run.started`（`RunStore.swift:155`）、`run.ended`（`RunStore.swift:124`、`ExecutionCoordinator.swift:222`）、`action.accepted`（`RuntimeService+Act.swift:52`）、`action.dispatched`（:95）、`action.<结果>`（:129）、`run.finishing` / `stop.accepted`（`ExecutionCoordinator.swift:198`）、`run.quiescent`（:221）。没有排队、单元、验证、审批类事件；单元事件在 #50 的 F40-03 提议里 | f1（目录）、40（unit 事件） | G1、G3 |
| GAP-09 | CLI 子命令 `agentdesktop acp` | CLI 没有 `acp` 也没有 `mcp`（`Sources/AgentDesktopCLI/CommandRouter.swift`、`Commands.swift` 无此词）。开发入口 `Sources/agentdesktop-acp-dev` 只打印「server not implemented yet」并以 2 退出 | 协调者提请 f1 | G1（T26） |
| GAP-10 | MCP 经 Runtime（`agentdesktop mcp`） | PR #29 是草案，未合入；`Package.swift` 没有 `AgentDesktopMCP` target。#29 正文说明每个工具对应一个 runtime/1 方法，真机验收未做 | f1（A7） | G0（T18） |
| GAP-11 | Windows 对等（Runtime 与 ACP） | `windows/README.md`：「The Windows native runtime, the NamedPipe endpoint, the model service and the GUI services are not here yet」。`windows/src` 只有 Contracts、AI、GUI 三个库 | 40（L-Win） | Windows 平台门禁（不在 G0～G5） |
| GAP-12 | 真编辑器 | 2026-10-08 在本机 `ls /Applications` 没有 Zed，也没有任何 JetBrains IDE；`which zed` 无结果。有 node 22.23.2、claude、codex、gemini | Kevin（K2） | G1（T26）、G5（T27） |
| GAP-13 | 幂等范围是认证主体 + requestId | 账本键是连接 uid + requestId（`Sources/AgentDesktopRuntime/Records/RequestLedger.swift:7,86-87`；`methods.json:11` 的 `requestLedger.key` 为 `caller uid + requestId`）。同一用户的 CLI、MCP、ACP 共用一个 requestId 空间 | f1（随 A4）；ACP 线 R 先用全局唯一 requestId 规避 | G2（T10） |
| GAP-14 | 提交后丢回复 → 只查询 | `RuntimeClient` 不做这层映射（`Sources/AgentDesktopClient/RuntimeClient.swift:8-20`）；映射写在 CLI 里（`Commands/CallCommand.swift:41` 的 `request_acceptance_unknown`，`RunCommands.swift:109` 的 `cancel_acceptance_unknown`）。查询方法 `request.show` 已有（`RuntimeService.swift:235`） | ACP 线 R | G2（T10、T11） |
| GAP-15 | 异步端口 | `RuntimeClient` 是同步阻塞接口（`RuntimeClient.swift:8-20`），`ACPRuntimePort` 是 async。R 需要把阻塞调用移出协作线程池 | ACP 线 R | 无（实现细节） |
| GAP-16 | 事件订阅与控制分离 | Runtime 拒绝在拥有活 Run 的连接上订阅（`RuntimeService+Events.swift:29-33`）。ACP 需要两条连接：控制与订阅 | ACP 线 R | G1 |
| GAP-17 | 心跳与失联待确认（HB-11） | Runtime 没有心跳：`grep heartbeat Sources/AgentDesktopRuntime` 无结果。失联只靠 socket 关闭触发 `connectionClosed`（`RuntimeService.swift:142-144`） | f1（A4） | G3（T14 的半开连接情形） |
| GAP-18 | 审批后目标复核（TOCTOU，RT-24） | PR #51 已合入 `ai-gui-foundation`（b2831ca）：act 前在 Desktop 锁内复核，发送后再复核，变化记为 unknown。`acp-skeleton`@2837bd4 不含它（`git merge-base --is-ancestor b2831ca HEAD` 为假） | 协调者（rebase） | G3（T17） |
| GAP-19 | AX 观察的总时限与隔离（RT-23A/B） | 未做。#51 正文「不在本 PR：AX 整树总时限与隔离，下一个 PR」 | f1 / 40（A3） | G3（T28） |
| GAP-20 | 存储与 socket 权限（SEC-01～05） | #39 已修 `ai.sqlite` 0600 / 目录 0700。A0 验收记录：SEC-02、SEC-04、SEC-05 未验证，SEC-03 部分验证 | f1（A3） | G0 |
| GAP-21 | ACP 会话存储 | 不存在：`Sources/AgentDesktopACP/Inbound/.keep.swift` 只是占位 | ACP 线 S | G2（T06～T08） |
| GAP-22 | ACP 服务器、传输、桥、投影 | 只有接口：`Ports.swift`、`Model/ACPModel.swift`；`Transport/`、`Wire/`、`RuntimeBridge/`、`Events/`、`Privacy/` 都只有 `.keep.swift` | ACP 线 T/S/R/E | G1 |
| GAP-23 | 从编辑器发起可在关闭后继续的任务（原文 P2 场景 A、T13） | 现行 ADR 不允许：线协议的 Run 一律 connection_scoped；`RuntimeService+Runs.swift:22-28` 拒绝 `lifetime`、`ownership`、非 `agent_hub` 的 `origin`；断连由 `ExecutionCoordinator.swift:228-233` 停止 | Kevin（K1） | G3（T13） |
| GAP-24 | unknown 的核实 | `run.reconcile` 为 reserved、PR4（`methods.json:636`）。ACP 只能显示「待核实」，不能追加核实记录 | f1（PR4） | 不阻塞（T11 只要求不重试） |
| GAP-25 | 真实 GUI 输入的开关 | 由 `role.guiExecutionEnabled` 决定，默认关（`AppController.swift:158-163`；#26）。ACP 的真实 E2E 需要测试副本打开它 | 协调者、Q | G1（T26） |
| GAP-26 | 出站执行体 | 没有代码；本轮只做 `spikes/acp-outbound/` 评估 | ACP 线 O；P3 实现待 Kevin | G4 |
| GAP-27 | 分发：ACP 清单、Registry、安装说明 | 包里只有 `agentdesktop`（`scripts/bundle-app.sh:55`），没有 ACP 清单与 Registry 元数据 | 协调者、f1 | G5 |

## 二、前五项差距

| 顺序 | 编号 | 为什么排在前面 |
| --- | --- | --- |
| 1 | GAP-03 `unit.run`（A6） | 没有它，编辑器不能交出任何任务；P1 的真实端到端全部卡在这里 |
| 2 | GAP-01 / GAP-02 单一端点（A2） | G0 的前置；`ai.sock` 仍以 trustedOwner 接受同 uid 的 ai/1 请求 |
| 3 | GAP-05 / GAP-06 身份（握手 principal、A4） | ACP 拿不到可信调用方；T07、T15 无法真正验证；会话按身份过滤没有意义 |
| 4 | GAP-07 审批与提问方法 | P2-04 与场景 C、D 的 Runtime 侧都不存在；`waiting_approval` 从未被设置 |
| 5 | GAP-04 任务目录 | 「从 Registry 动态生成可用任务」没有数据源；只能先用通用命令与 `unit.run` |

## 三、方案原文与核对结论、代码的冲突

一条一行。「README」指 [README.md](README.md) 第二节。

| 编号 | 原文位置 | 冲突 |
| --- | --- | --- |
| C-01 | 3.3、A0-05、第十一节「MCP 单独安全修复 PR」 | 新 MCP（#29）的工具都经 `RuntimeClient`；真正的旁路是宿主的额外监听，归 A2，不另开 ACP 安全 PR（README 二.1） |
| C-02 | README 二.1 本身 | README 说宿主仍调用 `runtime.start(socketPath:)` 打开旧 `control.sock`；代码已改为 `startInProcess()`（f187ec7，`AppController.swift:139-142`）。现存的第二监听是 `ai.sock`。README 引用的是 #47 正文里已过时的「未完成」条目，需协调者更正 |
| C-03 | 3.1 表、P2 场景 A、T13、第十三节「仅符合 Durable 规则的任务继续」 | ACP 发起的 Run 一律 connection_scoped，编辑器关闭即停止新输入；「从编辑器启动 Durable Run」不成立（README 二.2，K1；`RuntimeService+Runs.swift:22-28`） |
| C-04 | 4.6「复用现有 `unit.run`、`run.get`、`run.cancel`、`run.events`」 | `unit.run` 未实现（README 二.3）；`run.get` 不存在，对应方法是 `run.show` |
| C-05 | 4.5、P1-05「任务来源于已注册的 Agent」 | Runtime 没有任务注册表；ADR v2.2 规定平台不托管外部 App 的业务任务；`unit.run` 是 GUI 目标，不是已注册任务 |
| C-06 | 4.7「以认证后的 `clientId` 和 `requestId` 作为幂等范围」 | 代码与冻结契约的键是 uid + requestId（`RequestLedger.swift:86-87`，`methods.json:11`） |
| C-07 | 6.1 Layer 1、4.3「`clientId`、`principalId` 从可信认证上下文取得」 | 握手不返回任何 principal（`RuntimeService.swift:173-184`）；README 二.4 说「只能是握手返回的本机身份」，但握手连本机身份也不返回 |
| C-08 | `docs/plan/03` 3.2「runtime.handshake（含 `principal{clientId, role, connectionId}`）已实现」 | 同 C-07：计划与代码不一致（计划文件不属本线，回报 f1） |
| C-09 | 6.2、P2-04 审批 | runtime/1 没有可用的审批方法（README 二.5）；补充：`inbox.*` 已在目录里 reserved（PR4），`waiting_approval` 从不设置 |
| C-10 | 5.1 事件映射表 | Runtime 没有 Run Queued、Unit Started、Verification Succeeded/Failed、Policy Rejected、Approval Required 事件；实际事件见 GAP-08（README 二.6） |
| C-11 | 5.3 `ACPEventProjection.cursor: string` | Runtime 游标是整数：单个 Run 用 `sequence`，全局订阅用全局游标；`Ports.swift` 用 `lastCursor: [runId: Int]` |
| C-12 | 4.3 `ACPSessionBinding` 字段 | `Ports.swift` 没有 `connectionId`、`runtimeSessionId`、`permissionMode`；`activeRunIds` 改为 `runIds`；模式进 `options` |
| C-13 | 4.5 `ExposedTask.outputSchema`、`requiredCapabilities` | `Ports.swift` 的 `ACPExposedTask` 没有这两项；Runtime 也没有对应数据源 |
| C-14 | 4.2 模块图的 `Security/`、`Outbound/` | 实际布局没有 `Security/`：身份在 R，策略在 Runtime，过滤在 E（`Privacy/`）；出站只在 `spikes/`（原文自称逻辑名，记为偏差） |
| C-15 | 第九节「Windows 的 Runtime 与 ACP 适配层测试列入平台门禁」 | Windows 还没有 Runtime 与 named pipe 端点（`windows/README.md`），无从测试 |
| C-16 | P1「继续使用计算器测试作为标准样本」 | 计算器只能经 `unit.run`（A6）跑，且测试副本须打开真实 GUI 输入（GAP-25）；在 A6 前无法作为 ACP 任务 |
| C-17 | 3.1 表第三行「尚未被 Runtime 接受的请求：连接关闭，不执行」 | 代码一致，但「是否已受理」在丢回复时不可知；按规则只查询（`request.show`），不能假定未执行 |
| C-18 | 4.4 表把 `session/update` 列为 ACP 方法 | 它是服务器发给编辑器的通知，不是请求，不在 `ACPIncoming` 里 |
| C-19 | `methods.json` 的 `transport.macOS`「control.sock (frozen; runtime.sock until PR2b moves it)」 | A2 之后 Runtime 端点会改名为 `control.sock`，与引擎旧 socket 同名；G0 的检查必须按监听进程与协议判定，不能按文件名 |
| C-20 | #56「入站鉴权：stdio 子进程与用户同权，不另设登录」 | 原文与 ADR v2.2 要求身份来自 Runtime 认证；本修订版采用后者，A4 前明确标为本机 owner |

## 四、对其他工作线的提示

| 线 | 提示 | 依据 |
| --- | --- | --- |
| R | 两条连接：控制与订阅分开 | GAP-16 |
| R | requestId 全局唯一，带进程随机段与会话 ID | GAP-13 |
| R | 自己映射丢回复为「不明」，之后只用 `request.show` | GAP-14 |
| R | 握手拿不到 principal：A4 前 `caller()` 只能返回标为本机 owner 的占位身份，并写进 07 | GAP-05 |
| E | 按 GAP-08 的实际事件写夹具；F1-01 冻结后对齐 | GAP-08 |
| S | `decide` 返回 `capability_missing` 时按拒绝处理 | GAP-07 |
| Q | T13 改写为「主窗口 Durable Run 的只读观察」，或在 K1 决定前标 blocked | GAP-23 |
| 协调者 | 把 `acp-skeleton` rebase 到 b2831ca 以纳入 #51 | GAP-18 |
