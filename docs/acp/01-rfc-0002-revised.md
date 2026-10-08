---
authors:
  - "@szrunworld"
state: draft
---

# RFC 0002 - ACP 接入（agentdesktop 修订版）

## 修订记录

| 日期 | 变更 |
| --- | --- |
| 2026-10-07 | 初稿，在 2ndscreen 仓库（szrunworld/2ndscreen PR #56，分支 `szrunworld/rfc-0002-acp`）。命令为 `2ndscreen acp`，实现位置为 TypeScript `packages/task-runtime` |
| 2026-10-08 | 修订，迁到 agentdesktop 仓库 `docs/acp/`。依据 Kevin 的 [v1.0 方案](00-input-plan-v1.0.md) 与协调者的 [核对结论](README.md)。命令改为 `agentdesktop acp`；ACP 只经 `RuntimeClient` 与 runtime/1 进入 Runtime；生命周期改按 ADR v2.2；模块边界改为 `Sources/AgentDesktopACP` 的实际布局。#56 由本文取代 |

本文是待实施方案，不代表功能已经交付。代码依据是 `acp-skeleton`@2837bd4，它基于 `ai-gui-foundation`@6c18480（A0，PR #47 已合入）。现状与目标的逐项差距见 [04-gap-analysis.md](04-gap-analysis.md)。

权威顺序沿用 [docs/plan/README.md](../plan/README.md)：ADR v2.2 > 冻结契约（`contracts/runtime/v1`）> `docs/plan` > 本文。本文与上位文件冲突时，以上位文件为准。

## 一、定位

ACP（Agent Client Protocol）是 AgentDesktop 的第三种接入方式。它与 CLI、MCP 并列，全部进入同一个 Runtime。

| | 入站（Inbound） | 出站（Outbound） |
| --- | --- | --- |
| AgentDesktop 的角色 | ACP agent server | ACP client |
| 对端 | Zed、JetBrains 等编辑器 | Claude Code、Codex、Gemini 等编程 agent |
| 入口 | `agentdesktop acp` | Runtime 内的执行体适配层 |
| 路由 | 编辑器 → ACP → `RuntimeClient` → Runtime | Runtime → ACP client → 外部 agent |
| 优先级 | P1 | P3，先做隔离评估 |

ACP 是通信协议。它不是沙箱，也不是权限系统。权限只来自 Runtime 与 Agent Hub。

## 二、范围

做：

- **入站服务器**：`agentdesktop acp` 在 stdio 上说 JSON-RPC 2.0，把一个 ACP 会话映射为一串 Runtime Run。
- **版本适配**：只有 Wire 层认识具体 ACP 版本。版本决策见 [02-protocol-version.md](02-protocol-version.md)（工作线 T）。
- **事件投影**：Runtime 事件经一处投影与脱敏变成 `session/update`。规范见 [08-event-mapping.md](08-event-mapping.md)（工作线 E）。
- **出站评估**：只做隔离实测，原型放在 `spikes/acp-outbound/`。结论见 [09-outbound-isolation.md](09-outbound-isolation.md)（工作线 O）。

不做：

- **第二套执行**：ACP 不建 GUI 执行器、RunStore、Desktop 租约或第二套请求去重账本。
- **新的核心 RPC**：不新增 `acp.run()` 之类方法。Runtime 确实缺通用能力时，经 f1 审核的契约增量补进 runtime/1，清单在 [07-runtime-requests.md](07-runtime-requests.md)（工作线 R）。
- **HTTP 或 WebSocket**：两个方向都只走 stdio。
- **历史兼容**：不兼容 `2ndscreen acp`、agent-bridge 或任何旧入口。
- **从编辑器创建长期授权**：不提供 `allow_always`、`reject_always`。

## 三、命令与启动

正式命令是 `agentdesktop acp`。它是唯一正式 CLI `agentdesktop`（`Package.swift` 的 `agentdesktop` 产品，包内路径 `Contents/Resources/bin/agentdesktop`）的子命令。

```bash
agentdesktop acp                         # 连接产品 Runtime
agentdesktop acp --endpoint /tmp/adt-x/side.runtime.sock   # 测试副本
```

Zed 配置示例：

```json
{
  "agent_servers": {
    "AgentDesktop": {
      "command": "/Applications/Agent Desktop.app/Contents/Resources/bin/agentdesktop",
      "args": ["acp"]
    }
  }
}
```

规则：

- **端点**：沿用 `AgentDesktopClient.EndpointResolver` 与 `--endpoint`、`AGENTDESKTOP_ENDPOINT`。不自己猜路径。
- **握手**：先 `runtime.handshake`，版本不符就以明确错误退出，不降级。
- **开发入口**：CLI 接入之前，用不进发布包的 `agentdesktop-acp-dev`（`Sources/agentdesktop-acp-dev`，现在只打印「not implemented」并以 2 退出）。CLI 子命令由协调者提请 f1 接入。

## 四、总体架构

### 4.1 入站

```
编辑器（Zed / JetBrains）
   │ stdio JSON-RPC，一个进程一个编辑器连接
   ▼
agentdesktop acp
   ├─ Transport + Wire（T）     帧、错误、版本适配 → ACPIncoming / ACPReply
   ├─ Inbound（S）              会话、命令、prompt、cancel、审批、提问
   │     ├─ ACPSessionStore（S） 只存 ACP 绑定
   │     └─ ACPEventProjector（E）事件投影与脱敏
   └─ RuntimeBridge（R）        ACPRuntimePort，经 RuntimeClient
         │ 控制连接：提交、查询、取消（拥有本进程发起的 Run）
         │ 订阅连接：events.subscribe（只读，关闭不影响任何 Run）
         ▼
   Runtime（runtime/1，唯一）
```

控制与订阅必须分开两条连接。Runtime 拒绝在拥有活 Run 的连接上订阅（`Sources/AgentDesktopRuntime/RuntimeService+Events.swift:29-33`，原因 `control_connection`）。

### 4.2 出站（P3，只做评估）

```
Runtime（Run、授权、审计）
   ▼
执行体适配层 → ACP client → 外部编程 agent 进程（隔离环境）
                                │ 只能调用任务级工具网关
                                ▼
                         RuntimeClient → Runtime
```

外部 agent 的自述结果只是输入。是否成功以 Runtime 的证据与验证为准。

## 五、模块边界

`AgentDesktopACP` 只依赖 `AgentDesktopClient`、`AgentDesktopProtocol`、`AgentDesktopContracts`（`Package.swift` 的 `AgentDesktopACP` target）。它不依赖 `AgentDesktopRuntime`，也不依赖 `engine/`。

| 目录 | 工作线 | 接口（`Ports.swift` / `Model/ACPModel.swift`） | 职责 |
| --- | --- | --- | --- |
| `Model/` | 协调者 | `ACPIncoming`、`ACPReply`、`ACPSessionUpdate`、`ACPToolCall`、`ACPActionLevel` 等 | 版本中立模型，冻结 |
| `Ports.swift` | 协调者 | 下列协议 | 线与线之间唯一的接口，冻结 |
| `Transport/`、`Wire/` | T | `ACPConnection`、`ACPPeer` | stdio、帧、JSON-RPC、v1/v2 适配 |
| `Inbound/` | S | 使用全部端口；实现 `ACPSessionStore` | 服务器、会话、命令、流程编排 |
| `RuntimeBridge/` | R | `ACPRuntimePort`、`ACPCaller` | 身份、任务发现、提交与幂等、状态、取消、事件续传、断连 |
| `Events/`、`Privacy/` | E | `ACPEventProjector`、`ACPPrivacyPolicy` | 投影、三级结果、字段级脱敏 |
| `spikes/acp-outbound/` | O | 无 | 出站隔离实测，不进 `Package.swift` |

与方案原文 4.2 的差异：原文的 `Security/`（`ACPIdentityResolver`、`ACPPolicyAdapter`、`ACPDataFilter`）不单设目录。身份解析在 R（`ACPRuntimePort.caller()`），策略只在 Runtime，数据过滤在 E。原文的 `Outbound/` 本轮不进模块。

## 六、ACP Session 与 Runtime Run

### 6.1 四个概念

| 概念 | 是什么 | 权威 |
| --- | --- | --- |
| ACP Connection | 编辑器与 `agentdesktop acp` 进程之间的 stdio | T |
| ACP Session | 编辑器里一次可恢复的对话上下文 | S 的 `ACPSessionStore` |
| Platform Run | Runtime 实际执行的任务 | Runtime 的 RunStore |
| Run Lifetime | 由 Runtime 按调用方决定 | Runtime，只读 |

### 6.2 `ACPSessionBinding`

字段以 `Ports.swift` 为准：`acpSessionId`、`principalId`、`clientId`、`cwd`、`title`、`runIds`、`lastCursor`（按 runId 的整数游标）、`options`、`createdAt`、`updatedAt`、`revision`。

- **只是引用**：`runIds` 是对 Runtime Run 的引用，不是状态来源。显示状态前一律经 `snapshot(runId:)` 向 Runtime 查询。
- **身份来自认证**：`principalId`、`clientId` 来自 `ACPRuntimePort.caller()`，从不取编辑器发来的字段。
- **一对多**：一个 ACP Session 可以有多个先后的 Run。一个 Run 只属于一个 ACP Session。
- **乐观并发**：`save` 要求 `revision` 为当前值加一，否则冲突。
- **不存什么**：不存截图、页面文字、窗口标题、动作参数。存储里的文本先经 E 脱敏。

与原文 4.3 的差异：不持久化 `connectionId`（每次连接都变，`RuntimeService.swift:26`）；不设 `runtimeSessionId`（runtime/1 的 Session 属于 Run 内部）；`permissionMode` 改为 `options` 里的一个配置项；游标是整数而不是字符串，因为 Runtime 的 `RunEvent.sequence` 是整数（`contracts/runtime/v1/runtime.schema.json` 的 `RunEvent`）。

### 6.3 ACP 方法映射

| ACP（版本中立名） | 处理 | 是否创建 Run |
| --- | --- | --- |
| `initialize` | 版本协商，只声明已实现的能力 | 否 |
| `session/new` | 取 `caller()`，建绑定 | 否 |
| `session/list` | 按 `principalId` 过滤绑定 | 否 |
| `session/load`（v1）/ `session/resume`（v2） | 重新取 `caller()`，核对属主，查询 Run 实际状态，从游标续传 | 否 |
| `session/prompt` | 解析命令，提交任务，或只读查询 | 视命令而定 |
| `session/cancel` | 对本轮的 Run 发 `run.cancel`，以 Runtime 回执为准 | 否 |
| `session/close` | 本会话里仍活着的 connection_scoped Run 发 `run.cancel`；只读观察的 Run 只停止观察 | 否 |
| `session/set_config_option` | 改 `mode`、`desktop`、`screenshots`、`pageText` 等会话配置 | 否 |
| `session/update`（通知，方向为服务器到编辑器） | E 投影后的更新 | 否 |

`session/prompt` 从不直接执行 GUI 动作。恢复 ACP Session 从不恢复或重做 Run。

## 七、生命周期（ADR v2.2）

经线协议创建的 Run 一律是 `external_client / connection_scoped`。`agentdesktop acp` 是一个线客户端，所以 ACP 发起的 Run 都是 Delegated Run。依据：ADR v2.2 第三节；`docs/plan/02` A6；`RuntimeService+Runs.swift:22-28` 拒绝参数里的 `lifetime`、`ownership`、非 `agent_hub` 的 `origin`（`ownership_escalation_denied`）。

| 事件 | ACP 发起的 Run（Delegated） | 主窗口发起的 Run（Durable） |
| --- | --- | --- |
| 编辑器关闭或 stdin EOF | `agentdesktop acp` 关闭控制连接；Runtime `ownerLost` 停止新输入并收尾（`ExecutionCoordinator.swift:228-233`，`closingReason=owner_lost`） | 不受影响 |
| `agentdesktop acp` 崩溃 | socket 关闭，同上 | 不受影响 |
| 订阅连接断开 | 不受影响；重连后从游标续传 | 不受影响 |
| 编辑器重开并恢复会话 | 旧 Run 不恢复；只显示其终态，unknown 显示「待核实」 | 可只读观察 |
| `session/cancel` | `run.cancel`，先 `stopping`，静止后才显示已停止 | 不允许从 ACP 取消，除非 Runtime 授权 |

结论：

- **ACP 没有升级参数**：ACP 请求不能把 Run 变成 Durable。任务预计很长也不例外。
- **原文 P2 场景 A 不成立**：「从编辑器启动 Durable Run」在现行 ADR 下做不到。替代是「主窗口发起的 Durable Run，在 ACP 里只读观察」。是否改 ADR 由 Kevin 决定（README 第五节 K1）。
- **长任务**：P1 验证的是「编辑器显示不了也不会产生错误生命周期或丢状态」，不是「所有编辑器都能持续显示」。

## 八、任务发现

runtime/1 现在没有任务目录方法。`ACPExposedTask` 的来源分三步：

| 阶段 | 来源 | 对应 Runtime 方法 | 依赖 |
| --- | --- | --- | --- |
| 现在 | 平台通用的只读与控制命令：Desktop 列表、本身份 Run 的查看与取消 | `desktop.list`、`run.list`、`run.show`、`run.cancel` | 无 |
| A6 之后 | 通用 GUI 目标任务：Desktop、目标描述、验证谓词、允许动作 | `unit.run`（目录 frozen，PR2d，未实现） | A6（40，PR #50） |
| 之后 | 学习层的已验证流程；配对 App 声明的任务 | `gui.procedures.*`（reserved，PR7）；任务目录方法（不存在，需契约增量） | f1 契约增量、A4 授权 |

规则：

- **不写死业务**：核心代码不出现招聘、计算器等具体业务。计算器只是验收载体。
- **按授权过滤**：A4 之后，只列出当前身份被授权的任务。A4 之前，本机连接都是 owner，过滤没有意义，这一点在 G2 之前必须写进用户可见说明。
- **自由文本受限**：只有声明 `allowFreeText` 的任务接受自由文本。其余只接受斜杠命令加 schema 校验，校验失败不建 Run。
- **ADR v2.2 边界**：AgentDesktop 不托管外部 App 的业务任务。外部 App 的业务命令不进 ACP 命令表，除非将来有经 f1 审核的任务目录契约。

## 九、事件映射摘要

详细规范在 [08-event-mapping.md](08-event-mapping.md)。这里只定原则。

- **一处投影**：所有 `session/update` 都由 `ACPEventProjector` 产生。Runtime、GUI Core、业务代码都不拼 ACP JSON。
- **三级结果不混淆**：受理、已执行、已验证是三件事（`ACPActionLevel`：accepted、dispatched、executed、verified、contradicted、unknown、refused）。已执行从不显示为已验证。
- **unknown**：只显示「待核实」，从不重试。
- **事件来源**：Runtime 现在发出 `run.started`、`action.accepted`、`action.dispatched`、`action.<结果>`、`run.finishing`、`stop.accepted`、`run.quiescent`、`run.ended`（`RunStore.swift:124,155`；`RuntimeService+Act.swift:52,95,129`；`ExecutionCoordinator.swift:198,221-222`）。`RunEvent.type` 在 schema 里是自由字符串，类型目录未冻结（F1-01）。原文 5.1 的 Queued、Unit Started、Verification、Policy Rejected、Approval Required 在 Runtime 里还没有对应事件。
- **续传**：每个 Run 用 `events.subscribe {runId, after}` 从 `lastCursor[runId]` 续传；游标过期返回 `events_cursor_expired`，这时改用 `run.show` 读当前状态。

## 十、身份与审批

### 10.1 三层检查

| 层 | 问题 | 由谁判定 | 现状 |
| --- | --- | --- | --- |
| 1 身份与配对 | 谁在连接 | Runtime 的连接认证（A4） | 未实现。每个本机连接都是 `local:<uid>` 且是 owner（`RuntimeService.swift:27`，`RuntimeService+Runs.swift:9`）。握手不返回 principal（`RuntimeService.swift:173-184`） |
| 2 能力授权 | 这个客户端能做什么 | Runtime 的 Grant（A4） | 未实现，`hub.*` 为 reserved（PR3） |
| 3 动作策略 | 这个动作现在能否对这个目标执行 | Runtime 在原生入口复核 | 窗口一致性已在 `ai-gui-foundation`（PR #51，b2831ca），尚未进入 `acp-skeleton` |

### 10.2 审批

- **选项只有两个**：`allow_once` 与 `reject_once`（`ACPPermissionOptionKind`）。
- **编辑器批准不扩权**：它只是当前动作的一个审批条件。调用方本来没有的权限，批准了也照样被 Runtime 拒绝。
- **通道不可用即拒绝**：编辑器没有权限交互能力、已断开或请求失败时，`ACPPeer.requestPermission` 返回 `.unavailable`，S 按拒绝处理，从不自动批准。
- **审批后复核（TOCTOU）**：批准之后，Runtime 在执行入口重新检查目标的代次、进程、几何与遮挡，不符则 `stale_observation` 且 `notSent`（PR #51）。ACP 不缓存审批前的快照去执行。
- **Runtime 侧方法缺失**：`inbox.list/show/resolve` 是 reserved（PR4，`methods.json:618-630`），Run 的 `waiting_approval` 阶段在代码里从未被设置。在契约增量之前，`decide` 返回 `capability_missing`，S 绝不当作批准。

### 10.3 Ask / Auto

| 模式 | 含义 |
| --- | --- |
| `ask`（默认） | 在已有平台权限之内，对需要确认的动作逐次询问 |
| `auto` | 在已有平台权限与组织策略之内执行，不额外询问 |

两种模式都不能提高权限等级。`auto` 不跳过 Runtime 自己要求的审批。

## 十一、隐私

- **默认最严**：截图、页面文字、窗口标题、动作参数默认不进入任何 ACP 更新（`ACPPrivacyPolicy` 默认 `screenshots=off`、`pageText=false`）。
- **元数据也脱敏**：工具标题、错误消息、摘要、参数里的个人信息同样脱敏，例如「点击发送给 example@email.com」。
- **脱敏只在一处**：E 的 `ACPEventProjector.redact`。S 写日志、写存储、回错误之前都先经它。
- **日志不是旁路**：错误日志、调试日志、崩溃输出只写稳定错误码与 ID，不写原文。
- **存储权限**：ACP 会话存储放在用户目录，文件 0600、目录 0700，与 SEC-01 同一标准。
- **图片输入**：编辑器贴进来的图片只以不透明句柄存在于适配器内（`ACPContentBlock.image`），不落盘，不进日志。

## 十二、出站隔离摘要

细节与实测结果见 [09-outbound-isolation.md](09-outbound-isolation.md)。原则：

- **任务级工具**：外部 agent 只拿到被授权的任务级工具，不开放原子点击、键盘或无约束读屏。
- **进程级隔离**：环境变量、凭据、目录、网络、终端、自带工具、MCP 配置都要逐项限制并实测。
- **逐个执行体验证**：Claude Code、Codex、Gemini 的内部权限模型不同，不能假设 ACP 能禁止其内置工具。
- **数据分级**：Public、Internal、Confidential、Restricted/PII；Confidential 与 PII 默认不外发。只读也算披露。
- **做不到就不宣称**：隔离不成立的执行体只能是实验性适配器，不能通过 G4。

## 十三、幂等与提交

| 规则 | 做法 |
| --- | --- |
| 账本在 Runtime | Runtime 的请求账本以「调用方 + requestId」为键（`RequestLedger.swift:7,86-87`；`methods.json:11` 的 `requestLedger`）。ACP 不建第二套去重账本 |
| 键的现状 | 现在的调用方是连接的 uid，不是 clientId。同一用户的所有客户端共用一个 requestId 空间。ACP 生成的 requestId 必须全局唯一：前缀加本进程随机段与会话 ID |
| 同一 prompt 重试 | `ACPSubmission.submissionKey` 对同一 prompt 稳定。R 在发送前把 `submissionKey → requestId` 写入本地提交记录（`ACPSubmissionLog*`），重试复用同一 requestId，Runtime 返回原回执（`.duplicate`） |
| 不同请求 | 正文相同也用不同 requestId，不会被错误去重 |
| 结果不明 | 发出后丢了回复，记为 `.unconfirmed`，只用 `request.show {requestId}` 查询，从不重发。查不到时显示「待核实」 |
| 回复丢失的映射 | 现在由 CLI 自己映射为 `request_acceptance_unknown`（`Sources/AgentDesktopCLI/Commands/CallCommand.swift:41`），`RuntimeClient` 不做。R 要自己实现同样的映射 |
| unknown | 已执行但结果未知的动作，从不因超时重新执行 |

## 十四、阶段与门禁

- **PR 依赖与合并顺序**：见 [05-pr-graph.md](05-pr-graph.md)。
- **G0～G5 清单**：见 [06-gates.md](06-gates.md)。G0～G3 是入站发布的必要条件，G4 是出站启用的额外条件，G5 是公开分发条件。
- **mock 先行**：协议、投影、桥、服务器可以对着假实现合入 `acp-skeleton`。真实写操作要等 A2 合入且 G0 通过；真实任务提交要等 A6。

## 十五、未决问题

| 编号 | 问题 | 建议 | 决定方 |
| --- | --- | --- | --- |
| K1 | ACP 发起的任务能否在编辑器关闭后继续 | 维持 ADR v2.2：不能 | Kevin |
| K2 | 安装 Zed（P1 必需）与一个 JetBrains IDE（P2） | P1 前装 Zed | Kevin |
| K3 | ACP 是否随首版发布 | G0～G3 通过后再进首版 | Kevin |
| R1 | 握手是否返回 principal（`clientId`、`connectionId`） | 是；`docs/plan/03` 3.2 已写为「已实现」，代码没有 | f1 |
| R2 | 请求账本的键从 uid 改为认证主体 | 随 A4 改 | f1 |
| R3 | 审批与提问的 Runtime 方法 | 在 PR4 的 `inbox.*` 上加按 Run 查询与裁决 | f1 |
| R4 | 任务目录方法 | 先只用 `unit.run` 与只读命令；目录另提契约增量 | f1、Kevin |

## 十六、相对 #56 的修改

| 项 | #56 | 本文 |
| --- | --- | --- |
| 命令 | `2ndscreen acp` | `agentdesktop acp` |
| 实现 | TypeScript `packages/task-runtime`，`tasks.db` 新表 | Swift `Sources/AgentDesktopACP`，只经 `RuntimeClient` |
| 鉴权 | 「stdio 子进程与用户同权，不另设登录」 | 身份来自 Runtime 认证（A4）；A4 前明确标为本机 owner |
| 生命周期 | 「ACP 进程退出不影响已提交的任务」 | ACP 发起的 Run 是 connection_scoped，断连即停止新输入 |
| 恢复 | `session/load` 重新接上仍在运行的任务 | 恢复只读回放；旧 Run 不恢复 |
| 任务 | 每个 hub agent 任务类型一条斜杠命令 | 通用命令与 `unit.run`；无业务写死 |
| 事件 | `task_created`、`unit_started` 等 | Runtime 实际事件；三级结果；脱敏 |
| 审批 | `allow_once` / `reject_once` | 同上，另加不扩权、不可用即拒绝、审批后复核 |
| MCP 旁路 | 「另开议题」 | 落在 A2 单一端点，作为 G0 |
| 出站 | 执行体 `acp` 与 `agent-mcp` | 先做隔离评估（P3 前置），不进本轮代码 |
| 测试 | P1～P4 验收 | T01～T28 与 G0～G5 |
