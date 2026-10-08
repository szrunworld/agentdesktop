# Runtime API 冻结（runtime/1，2026-10-08）

ADR v2.2 开工顺序第 2 步（PR2）。本文在迁移之前冻结**唯一的**对外接口：端点、信封、方法目录、事件与产物的取法、主体身份的位置。后续 PR3（身份与授权）、PR4（Inbox/核对/诊断）、PR6（主窗口）、PR7（Explorer 学习回放）都只往这份目录里**按已预留的名字**填实现，不再新增第二套传输、信封或运行账本。

机器可读的权威版本是 `contracts/runtime/v1/methods.json`（每个方法带 `status`：`implemented` 已实现、`frozen` 名字与参数已定待实现、`reserved` 名字已定、参数随所属 PR 定稿）。本文解释其中的取舍。

依据：ADR v2.2（最高）；GuiAiProvider × Explorer 集成设计 v2.0 §2、§5；GUI Explorer 实施计划 v1.0；AgentHub v1 执行计划（允许映射到合并后的 Runtime 合同）；总计划 v2.1（单仓、`control.sock`）。

## 1. 一个端点、一个信封

| 项 | 冻结值 | 取代 |
| --- | --- | --- |
| 端点（macOS） | `~/Library/Application Support/AgentDesktop/control.sock`，0600，目录 0700，单实例 flock，`getpeereid` 校验 | `runtime.sock`（runtime/1）与 `ai.sock`（ai/1）两个端点 |
| 端点（Windows） | 当前用户 ACL 命名管道 `\\.\pipe\agentdesktop-control-<sid>` | — |
| 信封 | `agentdesktop.runtime/1`：请求 `{apiVersion, requestId, method, context{sessionId,runId,desktopId}, deadline, params}`；响应 `{apiVersion, requestId, ok, data \| error{code, message, phase, retryable, notSent, details}}` | ai/1 的 `{schemaVersion, requestId(uuid), command, context{idempotencyKey, deadlineAt}}` |
| 错误码 | 小写蛇形，唯一清单 `errors.json`；ai/1 的大写码按 §6 映射 | ai/1 `ErrorCode` 枚举 |
| 幂等 | `(主体, requestId)` 唯一键 + 规范化 `{method, context, params}` 的 sha256；同键不同参返回 `idempotency_conflict`。**requestId 就是幂等键**，不再有第二个 `idempotencyKey` | ai/1 的 `context.idempotencyKey` |
| 帧 | 一行一条 UTF-8 JSON，≤1 MiB（含换行）；同一连接上请求按序应答 | 不变 |
| 首个方法 | `runtime.handshake` | 不变 |

没有永久别名：ai/1 信封与 `ai.sock` 在 PR2 迁完后删除（产品未发布，无外部兼容负担）。`AgentDesktopContracts` 的类型并入 `AgentDesktopProtocol`，只保留一份规范性 Schema。

## 2. 主体身份（为 PR3 预留，现在就在线上）

- 每个连接有服务端签发的 `connectionId`；每个请求在服务端被归属到一个**主体** `clientId`。
- PR3 之前只有一种主体：本机同 uid 的进程，`clientId = "local:<uid>"`，角色 `owner`。PR3 引入配对后的外部 App：`clientId = "app:<id>"`，角色 `paired`，权限由授权（grant）决定。
- `runtime.handshake` 的结果增加 `principal: {clientId, role, connectionId}`。客户端**不能**在参数里声明自己的 clientId、ownership、lifetime 或 origin（ADR-05，已由 PR1 实现）。
- 请求账本、Run、产物、事件的可见性一律按主体过滤；`owner` 看全部。

## 3. Run：一个 RunStore，两类生命周期

已在 PR1 实现的模型不变：`kind`（act / exec / unit）、`ownership`、`origin`、`lifetime`、`phase`/`outcome`/`quiescence`、`revision`。

- **`gui.runs.*` 撤销**，并入 `unit.run` + 通用 `run.*`：
  - `unit.run` 启动一个 GUI 单元运行（kind `unit`）：探索 / 回放 / 自动，参数见 §5。
  - 读取、等待、停止、事件统一走 `run.show` / `run.wait` / `run.cancel` / `run.events` / `run.list`。
- 从连接（CLI、MCP、SDK、外部 App）发起的 `unit.run` 是 Delegated Run（external_client / connection_scoped，origin agent_hub）。主窗口的 GUI Explorer 在进程内经 Runtime 创建 Durable Run（platform / platform_durable，origin gui_explorer），**不经过线协议**，因此线上没有任何参数能得到 Durable Run。
- `gui_runs` 表不再作为权威，Explorer 只写 RunStore 事件与 ActionReceipt 的 ID 引用；AiService 只写推理 attempt（集成设计 §4）。

## 4. 事件：单调序号 + 游标 + 修订号

- 每个 Run 的事件有从 1 开始单调递增的 `sequence`；Run 本身有 `revision`（每次状态变化 +1）。
- 轮询：`run.events {runId, after, limit}` → `{events, next, ended}`（已实现）。`next` 就是恢复游标；客户端断线重连后从 `next` 继续，不丢不重。
- 订阅（PR2e 已实现）：`events.subscribe {runId?, after?}`。成功应答后，服务端在**同一连接**上推送 `{"apiVersion":"agentdesktop.runtime/1","event":RunEvent,"cursor":n}` 行；该连接上除 `events.unsubscribe` 外的请求一律返回 `conflict`（reason `subscribed`）。
  - 带 runId：推送该 Run 序号大于 `after`（默认 0，即从头）的事件；Run 结束且事件推送完毕后，服务端关闭连接。
  - 不带 runId：推送该主体可见的全部 Run 的事件（owner 看全部），`cursor` 是全局游标，`after` 默认为“现在”。主窗口 Runs 列表用这一种。
  - 订阅连接不是控制连接：关闭订阅不影响任何 Run（ADR-02、ADR-06）。在持有未结束 Delegated Run 的控制连接上订阅返回 `conflict`（reason `control_connection`）。
- 全局游标落在已保留区间之外（已裁剪，或来自已清空的旧库）时返回 `events_cursor_expired`，客户端改用 `run.list` / `run.show` 取当前状态后从新游标订阅。

### 4.1 事件类型目录（F1-01，2026-10-08 冻结）

Runtime 在每个 Run 上写的事件就是下面这些，Schema 见 `runtime.schema.json#/$defs/PlatformRunEvent`（按 type 分支，data 字段固定）。`run.`、`action.`、`stop.` 前缀只能是这些类型；`unit.` 前缀留给 GUI 单元，约定写在 Explorer 文档里；其他前缀保留。

| type | data |
| --- | --- |
| `run.started` | kind、origin、ownership、lifetime、desktopId、sessionId |
| `action.accepted` | requestId、kind |
| `action.dispatched` | requestId |
| `action.completed` / `action.failed` / `action.unknown` | receipt（完整的 ActionReceipt） |
| `action.refused` | requestId、reason{code, message}：发送前即被拒绝（G0、快照失效、停止、deadline），没有回执 |
| `run.finishing` / `stop.accepted` | reason、inFlight、revision |
| `run.quiescent` | revision |
| `run.ended` | phase=ended、outcome、reason |

回执（F1-03）：没有送达（not_dispatched）、执行失败或结果未知时带 `reason{code, message}`；送达时没有这个字段。经 `run.events` 和 `request.show` 回看时都能看到原因。

## 5. 产物：不透明 ID，不暴露路径

- `observe` 结果里的 `image` 去掉 `path`，只留 `{artifactId, mediaType, width, height, byteSize, sha256, transform}`。
- `artifact.show {artifactId}` → 元数据；`artifact.read {artifactId, offset, length≤512 KiB}` → `{dataBase64, offset, length, eof}`。分块读取让 1 MiB 帧上限下也能取完整截图，且 Python/TS SDK 都能实现。
- 产物按主体归属；读取他人产物返回 `not_found`。保留 24 小时（不变）。
- CLI：`agentdesktop artifact get <id> --out <file>`。

### `unit.run` 参数（frozen；A6 审核后定稿，2026-10-08）

`verification` 是 `UnitVerification`：`{all: [GuiVerification…]}`，1–8 条，谓词定义在 `service.schema.json`。`lifetime` / `ownership` / `origin` 在 Schema 中放行，只是为了让处理函数能明确返回 `ownership_escalation_denied`。Run 上的 GUI 单元信息在 `Run.unit`（`RunUnit`：mode、goalHash、guiProfileId/Revision、verification.status），不改变 phase / outcome / quiescence 三轴。

```json
{
  "desktopId": "desk_A",
  "mode": "auto | replay_only | explore",
  "goal": { "description": "…", "params": { "name": "Ada" } },
  "verification": { "all": [ /* GuiVerification 谓词，沿用 ai/1 domain 定义 */ ] },
  "allowedActions": ["click", "type", "key", "scroll", "wait"],
  "guiProfileId": "gp_…", "expectedProfileRevision": 3,
  "limits": { "maxSteps": 30, "maxSeconds": 600 }
}
```

返回 `Run`（kind `unit`）。结果（是否通过验证、用到哪个流程、学到什么）写在 Run 的事件与 `run.show` 的 `unit` 字段里；外部业务结果由外部 App 自己验证（集成设计 §5.1）。

### 5.1 产物的硬上限（#144，Kevin 2026-10-09）

不能因为一个 Run 一直不结束，或者很多 Run 叠在一起，就让截图无限增长。每次截图**之前**先检查并预留名额，超限就不截、不写：

| 上限 | 取值 | 依据（2026-10-09 实测，Retina 窗口截图） |
| --- | --- | --- |
| 单个计数单位：所属 Run；不属于任何 Run 时按会话；连会话也没有时按 Desktop | 2,000 张或 2 GiB，先到为准 | 计算器 43 KB、词典（接近全屏）130 KB、Chess 3.0 MB、整屏带照片 8 MB。GUI 探索一次最多约 60 张；常驻 Agent 每 5 秒观察一次，可以连续跑约 2¾ 小时 |
| 全部产物 | 10 GiB | |
| 磁盘剩余 | 至少保留 2 GiB；查不到剩余空间时也拒绝 | |

- context 里的 `runId` 必须是本连接拥有或已附加、且仍在运行的 Run，否则直接拒绝（`permission_denied` / `run_not_active`）。所以编造一个 runId 拿不到新名额，也不能花掉别人的名额。
- GUI 探索的每个 Run 单独计数，不计入调用方的会话：每一步先确认窗口截图和交给模型的副本两个名额都还有，才开始截图；超限时 GUI 层收到 `LIMIT_EXCEEDED`，消息里只写原因，不写计数单位的名字。
- **按单位计数的上限可以被拆开**：同一用户可以开多个会话；不带会话的 observe 按 Desktop 共用一个单位。因此单位上限只防"一个 Run 或一个会话无限增长"，**真正的硬上限是全部产物 10 GiB 和磁盘至少保留 2 GiB**。按调用方的上限要等 A4（#137）落地后，以 Runtime 认定的 clientId 计数。
- **行为变化**：一个长期不换的会话，每 5 秒观察一次，大约 2 小时 45 分钟就会用满 2,000 张；之后只能不带截图观察，直到旧截图过期（24 小时）或改用新的会话 / Run。
- 超限时返回 `limit_exceeded`（本 PR 起转为正式码），`details.reason` 为 `run_artifact_quota`、`artifact_store_full`、`disk_low` 或 `disk_unknown`。不带截图的 observe（只读元素）照常可用。Run 的事件和回执不受影响，不会丢失审计信息。
- **不为了腾空间删除仍在使用的产物。** 清理只删已过保留期、且所属 Run 已结束（或不属于任何 Run）的产物；仍持有的 observation 的截图、未结束 Run 的产物一律保留。
- 名额在检查时就预留，所以并发请求也不会一起越过上限；截图失败时退还名额。用量在启动时从磁盘记录统计一次，之后随登记和清理逐条增减，不做整体重算，避免和并发登记互相覆盖。
- 剩余空间的查询结果最多缓存 10 秒，在单独的后台队列里刷新，不在 Desktop 锁内，也不受清理任务影响；结果超过 60 秒没有更新（查询卡住）视为查不到并拒绝，卡住超过 30 秒的查询允许重新发起。

## 6. 方法目录

`status`：✅ implemented　🧊 frozen　🔖 reserved（名字定，参数随所属 PR）

| 族 | 方法 | 状态 | 归属 |
| --- | --- | --- | --- |
| 平台 | runtime.handshake / status / capabilities | ✅ | — |
| 平台 | runtime.stopAll / enableInput | ✅ | PR1 |
| Desktop | desktop.list / show / create / destroy；app.list / launch；window.list / bind / unbind | ✅ | — |
| 会话 | session.open / show / close | ✅ | — |
| 输入 | observe / act / wait；request.show | ✅（observe 的 `path` 在 PR2 去掉） | — |
| Run | run.start / attach / finish / show / events / wait / cancel / list | ✅ | PR1 |
| Run | unit.run | 🧊 | PR2 |
| 事件 | events.subscribe / unsubscribe | ✅ | PR2e |
| 产物 | artifact.show / read | ✅ | PR2c |
| AI 配置 | ai.connections.list / get / create / update / disable / delete；ai.credentials.rotate | ✅ PR2b-1（AI 服务经 Runtime 端点应答） | PR2b |
| AI 模型 | ai.models.list / refresh；ai.modelProfiles.list / get / create / update / disable / delete | ✅ PR2b-1 | PR2b |
| GUI 参数 | ai.profiles.list / get / create / update / disable / delete / default.get / setDefault | ✅ PR2b-1 | PR2b |
| 能力检测 | ai.tests.start；ai.operations.get / cancel | ✅ PR2b-1 | PR2b |
| 用量 | ai.usage.summary | ✅ PR2b-1 | PR2b |
| Desktop 控制面 | desktop.stop / takeover / handback / closePlan / resize；app.quit；request.list / export | 🔖 | A5 |
| 身份 | hub.pairing.start / status / approve / deny；hub.clients.list / show / revoke；hub.grants.list / set / revoke；hub.connections.list | 🔖 | PR3 |
| Inbox | inbox.list / show / resolve；run.reconcile（unknown 核对） | 🔖 | PR4 |
| 诊断 | diagnostics.export | 🔖 | PR4 |
| 学习 | gui.knowledge.get / events；gui.procedures.list / get / propose / revise / lifecycle；gui.validations.start / get / cancel | 🔖 | PR7 |
| 示范与策略 | gui.demonstrations.start / get / stop；gui.learning.settings.get / update | 🔖 P1 | PR7 之后 |

**撤销**（不迁移）：`gui.runs.start / get / cancel / events`（由 `unit.run` + `run.*` 取代）；ai/1 的 `runtime.capabilities`（与 runtime/1 同名方法合一）。

### AI 方法的名字为什么不改

集成设计 v2.0 §5.1 提议改名（`ai.connections.upsert`、`ai.guiProfiles.*`、`ai.capabilityTests.*`）。这些方法已经在 ai/1 上实现、有主窗口页面和测试在用，而 ADR v2.2 没有涉及命名。冻结取**现有名字**，只换信封和错误码，避免一次迁移里同时改名。如需按集成设计改名，请在 PR2 合并前提出；合并后视为冻结。

### ai/1 错误码映射

| ai/1 | runtime/1 |
| --- | --- |
| VALIDATION_ERROR | invalid_argument（字段级错误放 `details.fieldErrors`） |
| UNSUPPORTED_SCHEMA / UNSUPPORTED_PROTOCOL | version_mismatch |
| UNSUPPORTED_COMMAND | not_found（`details.reason: "unknown_method"`） |
| IPC_FRAME_TOO_LARGE | frame_too_large |
| UNAUTHORIZED / FORBIDDEN | permission_denied |
| NOT_FOUND | not_found |
| CONFIG_CONFLICT | conflict（`details.currentRevision`） |
| IDEMPOTENCY_CONFLICT | idempotency_conflict |
| RESOURCE_IN_USE | conflict（`details.reason: "in_use"`） |
| RESOURCE_DISABLED | conflict（`details.reason: "disabled"`） |
| CAPABILITY_MISMATCH | capability_mismatch（docs/plan/03 §3.5 起独立） |
| CREDENTIAL_REQUIRED / CREDENTIAL_REVOKED / AUTH_FAILED | model_unavailable（`details.reason` 原样小写） |
| RATE_LIMITED / UPSTREAM_UNAVAILABLE / UPSTREAM_PROTOCOL_ERROR / MODEL_NOT_FOUND | model_unavailable（`retryable` 按原值，`details.retryAfterMs` 保留） |
| DEADLINE_EXCEEDED | deadline_exceeded |
| CANCELLED | Run 上：无错误，`outcome: cancelled`；单次请求被取消时：conflict（`details.reason: "cancelled"`） |
| OPERATION_NOT_CANCELLABLE | conflict（`details.reason: "not_cancellable"`） |
| DESKTOP_BUSY | control_busy |
| STALE_OBSERVATION / STALE_GENERATION | stale_observation |
| INVALID_ACTION / COORDINATE_OUT_OF_BOUNDS | invalid_target |
| ACTION_OUTCOME_UNKNOWN | action_delivery_unknown |
| VERIFICATION_FAILED | Run 上：无错误，`outcome: failed`；单次请求时：execution_failed（`details.reason: "verification_failed"`） |
| LIMIT_EXCEEDED | 新码 `limit_exceeded` |
| USAGE_UNAVAILABLE | internal_error（`details.reason`） |
| AUDIT_UNAVAILABLE | audit_unavailable（docs/plan/03 §3.5 起独立；同时暂停新输入） |
| EVENTS_CURSOR_EXPIRED | 新码 `events_cursor_expired` |
| INTERNAL_ERROR | internal_error |

## 6.1 已登记的后续增量（docs/plan/03 §3.2–3.5，2026-10-08 纳入）

- 方法：上表 “Desktop 控制面” 一行，状态 🔖，归 A5。
- 错误码（`errors.json`，`reserved`）：`pairing_required`、`client_revoked`、`grant_missing`、`grant_expired`、`permit_expired`（退出码 4）；`target_moved`（5）；`audit_unavailable`（7）；`unsupported_backend`、`capability_mismatch`（6）。
- 可选字段（`methods.json` 的 `plannedFields`，每项随所属 PR 带 Schema、夹具和 golden 落地）：
  - Action 新增 `hover` / `drag` / `press`；
  - 只给 `desktopId` 时使用隐式会话；
  - ActionReceipt 新增 `businessResult`（恒为 `not_evaluated`）、`elapsedMs`、`clientId`、`origin`、`geometryRevision`、`dispatchSequence`、`reconciliations` 等；
  - Observation 新增 `targetKind`、`geometryRevision`、`captureSequence`、`coverage`；
  - Desktop 新增 `control`、`targetKind`；
  - `desktop.create` 新增 `launch` / `bind` 参数；
  - Run 新增 `unit` 与学习层预留字段。

## 7. 冻结规则

1. 本目录中 ✅ 与 🧊 的方法名、必填参数、结果的必填字段、错误码，合并后只能**加可选字段**，不能改名、删字段、改语义。
2. 🔖 的方法名固定；参数在所属 PR 中定稿，定稿即冻结。
3. 新方法必须先改本文与 `methods.json`，再写实现。
4. CLI、MCP、Python/TS SDK 只经 `AgentDesktopClient`（或等价的线协议客户端）调用，不链接 Runtime 内部。

## 8. PR2 的实施拆分

| 步 | 内容 |
| --- | --- |
| PR2a（本 PR） | 冻结文档；`methods.json` 全目录与状态；新错误码；新增方法的 Schema（unit.run、events.subscribe、artifact.*、handshake.principal） |
| PR2b | 端点改为 `control.sock`；ai/1 方法改由 RuntimeService 在 runtime/1 信封下分发；删除 `ai.sock`、ai/1 信封与 `AgentDesktopContracts` 的重复解码 |
| PR2c | 产物按 ID 取：observe 去掉 `path`，实现 artifact.show/read，CLI/MCP/SDK 跟进 |
| PR2d | `unit.run` 落到 RunStore：GuiExplorer 经 ExecutionCoordinator 执行，撤销 `gui.runs.*` 与 `gui_runs` 权威 |
| PR2e | `events.subscribe`：同连接推送、主体过滤、游标恢复 |

## 9. 单一端点落地说明（PR2b-1、PR2b-2，2026-10-08）

- 宿主只监听一个端点（目前仍叫 `runtime.sock`；`control.sock` 这个名字等引擎侧不再用它时再改），**没有 `ai.sock`**。
- `ai.*` 与过渡保留的 `gui.runs.*` 由宿主里的 AI 服务应答，在 `methods.json` 里标为 `servedBy: "ai-service"`：
  - 同一信封、握手和订阅规则；
  - params 与 result 的定义在 **`contracts/runtime/v1/service.schema.json`**，由 Runtime 合同统一加载；
  - 不进 Runtime 请求账本，requestId 就是 AI 服务的幂等键（写操作 8–128 个字符）；
  - 错误按 §6 映射成小写码，服务自己的分类放在 `details.serviceCode`。
- ai/1 的 `runtime.capabilities` 并入 `runtime.capabilities` 的可选字段 `gui`（定义 `GuiCapabilities`）。
- `gui.runs.*` 在单一端点上过渡保留（`status: transitional`，`removedBy: A6`），unit.run 落地时删除。
- **PR2b-2 起，Swift 端已没有 ai/1 信封**：
  - 不再编码或解码 `schemaVersion` / `command` / `context.idempotencyKey`；
  - 服务内部用 `ServiceRouter.answer(method:params:deadline:idempotencyKey:)` 直接调度；
  - 主窗口在进程内调用同一路由；
  - CLI 的 `rpc` / `ai` / `gui` 命令直接发 runtime/1 请求，输出 runtime/1 应答；`rpc --request-file` 只接受 runtime/1 请求，旧信封在本地即被拒绝；
  - `AgentDesktopContracts` 模块已并入 `AgentDesktopProtocol`，GUI 几何的 `Rect` 改名为 `GuiRect`。
- `contracts/ai-gui/v1` 只剩 Windows 的 C# 合同层在用，待 Windows 线迁移到 runtime/1 后删除。
