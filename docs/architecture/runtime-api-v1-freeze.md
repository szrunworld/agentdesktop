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

### 1.1 `notSent` 的含义：not_performed（#170，Kevin 2026-10-09 选方案 A）

字段名仍是 `notSent`，语义按 Kevin 的定义：

> **not_performed：执行系统能够证明，本次动作没有向目标平台或目标应用发出任何具有外部效果的输入或写操作。** 无论请求是否已到达 Runtime，只要能够证明没有发生外部输入或写操作，都可以返回 not_performed。如果已经发出部分操作，或者无法证明操作没有发出，则不得返回 not_performed。

| 场景 | 结果 |
|---|---|
| 请求未到达 Runtime，且能够确认没有执行（连接失败、本地参数校验） | `notSent: true` |
| Runtime 收到请求，但授权检查失败，未执行动作 | `notSent: true` |
| Runtime 收到请求，但安全策略拒绝，未执行动作（G2、#153 封堵、焦点检查） | `notSent: true` |
| 焦点检查失败，没有输入任何字符 | `notSent: true` |
| 已经向输入接口提交部分字符 | 送达未知，不得 `notSent` |
| 外部写入已提交，但未收到平台回执 | unknown，不得 `notSent` |
| 外部写入已提交，平台明确确认成功 | completed |
| 无法判断外部写入是否发生 | unknown，不得 `notSent` |
| 请求超时，但 Runtime 可能已经执行 | unknown（`request_acceptance_unknown`），不得 `notSent` |

**三条不变量**
1. **not_performed 必须有证据。** 不能因为超时、断连、取消或缺少回执，就推断什么都没发生。Runtime 里的证据是代码结构：拒绝发生在调用平台（`platform.perform`、启动、移动窗口、截图）或外部写入之前；`act` 的投递边界由请求账本的 `dispatch_started_at` 标记，在调用平台之前同步写入。
2. **not_performed 不等于允许自动重试。** 重试照样要经过授权、Run 状态、停止状态、安全策略和请求账本。停止之后，用同一个 requestId 或新的 requestId 重试，都仍然被拒绝。
3. **区分“已提交输入”和“目标实际接收”。** 只要输入接口已经接受提交，就不得声称没有发送；目标是否实际接收、处理或显示，是另一个层面的确认问题。

**现有用法核对（2026-10-09，main 9eb49bc）**：`Sources` 中共 52 处 `notSent: true`（Runtime 43 处，客户端、CLI、协议层 9 处），逐处核对如下。

| 类别 | 位置 | 结论 |
|---|---|---|
| 连接失败、本地校验、端点被拒 | `UnixSocketTransport`、`EndpointResolver`、`ContractCLI`、`ExecContext`、`RuntimeError.invalidArgument` / `runtimeOffline` | 符合：请求没有发出 |
| 账本、审计不可用，幂等冲突 | `RuntimeService` 处理前，`RuntimeService+Extensions`，`ExecutionCoordinator.begin` / `beginAction` / `enableInput` | 符合：在处理和调用平台之前 |
| #153 的封堵，所有权提升，物理 Desktop、启动、绑定的封堵 | `RuntimeService` 的 `grantRefusal` / `extensionGrantRefusal`，`RuntimeService+Runs`，`RuntimeService+Desktops` | 符合：在请求账本、处理和平台之前 |
| 启动归属拒绝 | `EnginePlatform.launch`（`no_launch_apps_configured` 等） | 符合：在打开应用之前（#151 / #164），`launch_failed` 和 `launch_refused_after_open` 不标 |
| act 的目标与快照检查、G2、截止时间、停止 | `RuntimeService+Act` 投递边界之前的 17 处 | 符合：都在 `markDispatching` 和 `platform.perform` 之前 |
| 重启时未走到投递边界的 act | `RequestLedger` 恢复逻辑 | 符合：只针对 `act`，并以 `dispatch_started_at` 为证；其他方法在途时记为 unknown |
| observe 的截图封堵 | `RuntimeService+Observe` | 符合：在截图之前 |
| **引擎报错时的 `beforeDispatch`** | `EnginePlatform.perform` | **已结构化（#173）**：引擎在每个输入请求里回报 `delivery`（`notPerformed` / `submitted` / `unknown`）。它由执行路径本身记录：事件、焦点或前台切换、真实鼠标移动在**调用之前**标记为已提交；辅助功能的按下和写值按实际返回的错误码记录。记录器只能单向升级，所以复合动作只要提交过任何东西，就不会是未执行。Runtime 只在 `delivery == "notPerformed"` 时标 `notSent`；字段缺失按 unknown 处理。按错误文字判断的 `preDispatchFailures` 和 `notPerformed(message, kind:)` 已删除 |

**另行登记的发现**
- 按元素点击时，引擎先尝试通过辅助功能“按下”元素；如果返回失败（包括超时），会再补发一次事件点击。超时不代表没有执行，所以可能点击两次。这不涉及 `notSent`，但违反“执行状态只描述能够证明的事实”的原则，要单独修。
- iOS（WDA）那条线用的是自己的 `delivery: .notSent`，不属于 runtime/1 契约，这次没有核对。按同一原则另行审查。

**测试**：`RuntimeNotPerformedContractTests` 覆盖以下场景：收到请求但拒绝执行、已发出的输入不得标 notSent、停止后同一 requestId 或新 requestId 重试仍被拒绝、可能已执行的写入记为 unknown。已有测试 `afterARestartUndispatchedActsFailAndDispatchedOnesAreUnknown` 和 `aWriteInFlightWhenTheHostStoppedIsUnknownAfterRestart` 覆盖重启场景。

## 2. 主体身份（为 PR3 预留，现在就在线上）

- 每个连接有服务端签发的 `connectionId`；每个请求在服务端被归属到一个**主体** `clientId`。
- PR3 之前只有一种主体：本机同 uid 的进程，`clientId = "local:<uid>"`，角色 `owner`。PR3 引入配对后的外部 App：`clientId = "app:<id>"`，角色 `paired`，权限由授权（grant）决定。
- `runtime.handshake` 的结果增加 `principal: {clientId, role, connectionId}`。客户端**不能**在参数里声明自己的 clientId、ownership、lifetime 或 origin（ADR-05，已由 PR1 实现）。
- 请求账本、Run、产物、事件的可见性一律按主体过滤；`owner` 看全部。

### 2.1 PR3 之前的临时封堵（#153，Kevin 2026-10-09 裁决）

在 #137（A4 身份与授权）落地之前，Runtime 按连接来源区分两类主体。来源由 Runtime 在建立连接时标记，客户端改不了：

| 来源 | 怎样产生 | `clientId` | 角色 |
| --- | --- | --- | --- |
| `host` | 本进程内的主窗口与 GUI 端口 | `local:<uid>` | owner |
| `socket` | `RuntimeServer` 接受的任何本机客户端（CLI、MCP、ACP、SDK、各 Agent） | `socket:<uid>` | 非 owner |

socket 客户端：
- 不能启动应用，不能枚举应用和窗口，不能调用任何 `gui.runs.*`；服务方法只能调用白名单里的读取方法。拒绝都是 `permission_denied`、`notSent`，发生在请求账本和平台之前。
- 看不到也用不了主窗口创建的 Desktop、会话、请求结果、Run、事件和产物。

#### 剩余风险：反复 Stop 的可用性风险

`runtime.stopAll` 对 socket 客户端开放，因为停止是安全方向；`runtime.enableInput` 只有 owner（主窗口）能调用。因此：

- **任何本机 socket 客户端都可以循环调用 `runtime.stopAll`，让输入一直处于停止状态，并停掉包括主窗口 Durable Run 在内的所有 Run。只有主窗口能恢复输入。**
- 这是可用性风险，不是机密性或完整性风险：Stop 不会读取或泄露任何内容，也不会发出任何输入。每次 Stop 都写入持久的请求账本，被停的每个 Run 都在历史里记录 `global_stop`。同一 requestId 重复调用得到原结果；重复 Stop 不报错。
- 例外：请求账本写入失败时，这一次 Stop 不会留下账本记录，但全局停止仍然生效。停止方向不被审计故障阻挡；审计存储故障本身也会触发全局停止。
- 这一风险只来自已在本机、以同一用户身份运行的进程。这类进程本来就能终止 AgentDesktop 本身。

**#137（A4）配对后的收紧计划：**
1. `runtime.stopAll` 按主体限定范围：配对应用只能停止自己的 Run；只有 owner 能执行全局停止并关闭输入准入。
2. 未配对的连接（`unpaired`）不能调用 `runtime.stopAll`。
3. 全局停止成为单独的授权项：用户可以授予某个配对应用“紧急停止”的能力，并能随时撤销；授权、撤销与每次调用都写入审计。
4. 主窗口显示最近一次全局停止由哪个主体发起，便于用户发现被滥用的情况。

#### 其他剩余风险（交给 #137）

- socket 客户端之间暂时共用一个主体，能互相看到并使用对方的 Desktop、会话、请求账本、Run 和产物。
- AI 配置只读开放：socket 客户端能读到全局 AI 连接的 `baseUrl` 和 `credentialRef`（钥匙串条目 ID，不是密钥本身）。
- `runtime.status` 向 socket 客户端返回全局计数（Desktop、会话、活动 Run），其中包括主窗口的。只泄露数量，不泄露内容。

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
- 剩余空间的查询结果最多缓存 10 秒，在单独的并发后台队列里刷新（重试不会排在卡住的查询后面），不在 Desktop 锁内，也不受清理任务影响；结果按发出查询的时间记，晚到的旧答案不会冒充新答案；超过 60 秒没有更新视为查不到并拒绝，卡住超过 30 秒的查询允许重新发起。
- GUI 探索的一步在开始前一次性预留两个名额，四项检查（单位上限、全部产物、磁盘剩余、剩余空间可知）一起做；任何一项不过就一张都不截，没用上的名额退还。

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

## 10. 输入不经过系统剪贴板（G2，Kevin 2026-10-08 / 10-09）

剪贴板属于用户：粘贴会把用户最近复制的内容（常常是密码或密钥）送进 Agent 操作的应用；复制或剪切会覆盖用户的内容。**现阶段任何 Agent 都不能经系统剪贴板输入**。这不等于产品永远不能用剪贴板：以后如需开放，必须另行设计显式授权，目前没有这样的授权。

规则不看调用方怎么声明，也没有任何运行模式、来源或主体可以解除。Runtime 在 `act` 里、**发送前的最后一步**统一检查；CLI、MCP、SDK、ACP、独立 Agent、主窗口 GUI 探索都只能经这里到达平台（`.perform(` 只在 `RuntimeService+Act.swift`，有测试守着）。**判断不了的一律拒绝。**

- **按键**：判断的是引擎实际发出的键码在当前键盘布局下打出的字符（Dvorak 下 cmd+"." 就是粘贴），带修饰键和不带修饰键各判断一次。
  - 带 cmd 或 ctrl、字符是 v / c / x：拒绝（`details.path = "shortcut"`）。拒绝 ctrl 是因为虚拟机和远程桌面里 ctrl+V/C/X 用的是共享的剪贴板。
  - 和目标应用菜单栏里"粘贴 / 拷贝 / 剪切"类菜单项的当前快捷键相同的组合：拒绝（`menu_shortcut`），包括用户在系统设置里改过的快捷键。
  - 键盘布局读不到：拒绝（`layout_unknown`）。菜单栏读不到：拒绝（`menu_unverified`）。只对带 cmd / ctrl 的组合做这两项判断。
  - F2 / F3 / F4：拒绝（`function_key`），因为它们是 Office for Mac 的剪切、拷贝、粘贴。Shift+Forward Delete：拒绝（`shortcut`），因为它在 Windows 虚拟机和远程桌面里是剪切。
  - 任何带修饰键的组合，或单独按下的功能键，只要和菜单栏里"粘贴 / 拷贝 / 剪切"类菜单项的当前快捷键相同，就拒绝；包括不带 cmd 的快捷键（option+P、F6、cmd+F5）。命名键的快捷键优先按菜单项的虚拟键码读取；菜单里显示为符号或功能键码的（Safari 的方向键 U+F700、Finder 的 Delete U+0008、Chrome 的 Esc U+238B）换算成引擎的键名再比较。键名别名（enter 和 return、esc 和 escape、backspace 和 delete）视为同一个键。
  - 单独按下的移动或编辑键（Return、Tab、空格、Esc、Delete、方向键、Home、End、翻页键）不查菜单栏，否则每按一次都要读一次菜单；把粘贴改到这类键上属于残余风险。
  - Return、Enter 和空格（包括写成单个空白字符的键：" "、"\n"、"\r"、"\t"）会"按下"当前有焦点的控件（先用 Tab 把焦点移到"拷贝代码"按钮再按回车，等于点它）。所以按这些键前，以及**任何打字之前**（文字发给有焦点的元素，写值失败时引擎也会退回到往焦点里打字），先现场读取该应用当前有焦点的元素：如果它不是文本输入框或可编辑文本，并且它或它的上级名称是"粘贴 / 拷贝 / 剪切"类，或者它的快捷键是剪贴板快捷键，就拒绝（`focused_control`）；读不出焦点也拒绝（`focused_unverified`）。没有任何焦点时放行。第一次读不出焦点时再读一次，仍读不出才拒绝。
  - 应用有打开的菜单（菜单栏菜单或右键菜单，即该进程在弹出菜单层有屏幕窗口）时，Return、Enter、空格和任何打字都拒绝（`menu_open`）：先用方向键选中"粘贴"再按回车，等于点它，而辅助功能的焦点不一定指向被选中的菜单项。读不出窗口列表也拒绝（`menu_unverified`）。G2 这一条本身不拦方向键和 Esc，但 §10.1 的焦点规则在菜单打开时拒绝所有按键，包括方向键和 Esc。代价：地址栏补全列表、下拉列表这类同样处在弹出菜单层的窗口出现时，打字和回车也会被拒绝，要先点击关掉它们（fail closed；按键在菜单打开时一律拒绝，见 §10.1）。
  - 引擎逐字符发送打字文本，文本里的 Tab 会在一次动作中途移动焦点（再用空格按下拷贝按钮）。所以打字文本含换行以外的控制字符（Tab、`\u{19}`、Esc 等）时拒绝（`type_control_character`），Tab 要用单独的 key 动作。按键是换行、Tab 以外的控制字符（例如 AppKit 和 Chromium 当作 Enter 的 `\u{3}`）时拒绝（`key_not_printable`）。
  - 在文本框里按 Return（包括打字文本里的换行）会按下窗口的默认按钮。所以 Return 和含换行的打字会现场读焦点所在窗口的默认按钮，名称是"粘贴 / 拷贝 / 剪切"类时拒绝（`default_button`）。
  - 菜单栏在**取得 Desktop 锁之前**读取，每个应用最多每 5 秒重新读一次，一次最多 1 秒；超过 3,000 项或超时就当作读不到，判为 `menu_unverified` 拒绝，不按读到的一部分放行。
  - 读取时，任何辅助功能错误（超时、应用无法应答）都会让整次探测作废；只有"没有这个值"或"不支持这个属性"才算属性不存在。
- **点击**，无论按元素还是按坐标：发送前在点击位置**重新读取**那里的元素，不用快照里的旧信息。
  - 菜单项（含右键菜单）：快捷键或名称表示粘贴 / 拷贝 / 剪切，拒绝（`menu_item`）；名称和快捷键都没有，无法判断，拒绝（`menu_item_unverified`）。其余菜单项和菜单栏项也一律拒绝（`menu_open`，#163，Kevin 2026-10-09）：菜单是哪个窗口打开的无法证明，叠在绑定窗口上也不能证明，同一应用另一个窗口的菜单（“关闭窗口”“删除”）会作用在未授权的窗口上。点击绑定窗口本身（不被菜单覆盖的地方）照常判断，可以用来关闭菜单。代价：Agent 不能通过菜单（右键菜单、菜单栏、弹出列表）完成任何操作；必须用菜单才能完成的任务，应停下来请用户处理。
  - 不在绑定窗口里、又不是菜单的元素（弹出框、浮层、别的窗口）：拒绝（`outside_bound_window`）。
  - 辅助功能读不出元素：拒绝（`hit_unavailable`）。
  - 任何控件，只要它的标题、描述或帮助文字以粘贴 / 拷贝 / 剪切开头：拒绝（`control`）。词表覆盖 macOS 提供的各种语言，"Copy Link""Paste as Plain Text"这类变体也算在内。
- 打字（辅助功能写值或 unicode 按键事件）和滚动不使用剪贴板。但如果打字指定了元素或坐标，引擎可能要先点击它（网页里没有焦点的输入框），所以先在该元素位置现场检查：不再因为"已有焦点"而放行（焦点可能在拷贝按钮上），必须是文本输入框（AXTextField、AXTextArea、AXSearchField、AXComboBox、AXSecureTextField），或者是网页标记为可编辑的富文本（contenteditable），并且在绑定窗口里，否则拒绝（`type_target_not_text`）。按钮、链接、菜单项等可按下的角色永远不算可编辑。文本框自己的文字（例如占位文字"Paste your API key here"）不做名称检查，往文本框里打字不是粘贴。
- 点击时，除了被点元素本身，还检查它上面三层控件的名称：按钮里的图标没有名字，要看所在按钮的名字。有测试保证：除了主窗口里用户自己点的复制按钮，以及没链接进 Runtime 的 iPhone 路径，产品和引擎代码都不碰剪贴板 API。
- 应答：`permission_denied`，`notSent: true`，`details.reason = "clipboard_path_refused"`，`details.path` 是上面括号里的取值之一。Run 历史里记 `action.refused`。一次性 Run 以 failed 结束；exec Run 被拒后可以继续。未知的动作类型也拒绝，不再默认当作点击。
- 每次读取对每个辅助功能元素都单独设 0.3 秒超时（超时设置不会从父元素继承；对一个应用的第一次查询实测约需 0.1 秒），整次探测另有 1 秒总时限，超时就当作读不到。
- 用到的系统读取（`SecondScreenCore/ClipboardProbe`）都是只读的：点击位置的辅助功能命中检测、菜单栏第一层菜单项的标题与快捷键（读子项不会打开菜单）、键盘布局。只依赖输入本来就需要的辅助功能权限，不需要新权限；点击位置的检查是在持有 Desktop 锁的时候做的，约 1.3 秒为上限（总时限 1 秒，加上最后一次进行中的读取最多 0.3 秒），属于 RT-23A 的一个有界例外：应用无响应就按"判断不了"拒绝，不会一直占着锁。菜单栏读取不占锁。
- **规则覆盖不到的情况**（残余风险）：
  - 应用或网页在一次普通输入之后**自己写剪贴板**（比如网页按钮的点击处理函数直接复制内容），Runtime 看不到；
  - 虚拟机、远程桌面里由客户机自己定义的复制粘贴方式；
  - 检查和发送之间仍有极短的时间差：引擎在发送那一刻自己选定目标窗口，两者不是原子操作；
  - 拒绝 ctrl+C / ctrl+V / ctrl+X 也会挡住终端里的中断，以及 nano、vim、Emacs 的这些按键，这是有意的取舍，待 Kevin 确认；
  - 应用在一次普通输入之后自己去读剪贴板，例如终端里输入 `pbpaste` 回车，或者网页在点击处理函数里读剪贴板；
  - 应用自己定义、又不出现在菜单栏里的快捷键；
  - 名称不在词表里的控件。
- iPhone 等设备后端（G1）接入 Runtime 时同样适用这条规则：它现在的打字靠粘贴，所以会被拒绝，除非 Kevin 另行裁决并给出可信授权。

### 10.1 按键和打字只发给绑定窗口的焦点（#120 补审，Kevin 2026-10-09）

按键和打字是发给应用当前的焦点窗口的，不是发给某个窗口 ID。窗口栈检查只看普通层（layer 0）的窗口，同一进程的浮动面板不在其中。所以在每次按键或打字之前，Runtime 都会现场核对：

- **菜单打开时**：判断依据是该进程在弹出菜单层有屏幕窗口。这时任何按键和打字都拒绝（`menu_open`），方向键和 Esc 也不例外：菜单授权属于绑定窗口，不属于进程，而一个菜单是哪个窗口打开的无法证明，位置叠在绑定窗口上也不能证明（Kevin 2026-10-09）。读不出菜单状态也拒绝（`menu_unverified`）。要关闭菜单，就点击绑定窗口里的空白处；点击由 G2 按落点下的元素判断。菜单关闭后，立即恢复下面的焦点检查。代价：地址栏补全列表、下拉列表这类同样处在弹出菜单层的窗口出现时，也要先点击关掉，才能继续按键或打字。
- **菜单关闭时**：读出应用的焦点窗口，读取失败时重试一次。只有焦点窗口就是绑定窗口时才发送。焦点在其他窗口时拒绝（`focus_outside_bound_window`）。以下情况都拒绝（`focus_unverified`）：读不出焦点；读得出焦点元素，但读不出它所在的窗口；没有焦点元素，也没有焦点窗口。不会退回到只按进程判断，也不会改走别的输入路径。
- 所有拒绝都是 `stale_observation`，并标明 `notSent`，原因码放在 `details.reason`。
- **打字的额外条件**：打字是逐字符发送的，而焦点只在发送前检查一次。空格可能按下一个获得焦点的按钮，换行可能按下默认按钮，两者都可能打开菜单或把焦点移走，剩下的字符就会跟着发到别处（Codex 在 74278c9 上的意见）。所以打字还要满足两点：焦点必须是绑定窗口里的可编辑文本，否则拒绝（`type_focus_not_text`）；换行最多一个，并且只能是文本的最后一个字符（`\n`、`\r` 或 `\r\n`），否则拒绝（`type_newline_not_last`）；结尾连续两个换行也拒绝，因为第二个会发到第一个可能移走的焦点那里。多行文本要拆成多个动作发送。只在开头检查一次焦点证明不了整段文字都发到了绑定窗口（Kevin 2026-10-09）：在文本框里逐字输入时，网页脚本仍可能在某个字符之后打开新窗口并抢走焦点。所以引擎在**每个字符发出之前**都重新读一次焦点所在的窗口，一旦不是绑定窗口或读不出来就立即停止：一个字符都还没有提交给输入接口时，报“no character was submitted”，引擎的执行记录（#173）保持 `notPerformed`，Runtime 标为 `notSent`；但如果打字前先点击了网页输入框，这次点击已经提交，整个动作记为 `submitted`，Runtime 记为送达未知，不标 `notSent`；已经提交过字符时，报出**已提交给输入接口的字符数**（这是提交的数量，不是目标应用收到的数量），Runtime 记为送达未知（`action_delivery_unknown`），绝不把部分发送标成零发送。残余风险（Kevin 2026-10-09：不得宣称消除了 TOCTOU）：每次“读焦点”和“提交这个字符”之间仍有竞争窗口；而且字符事件是异步排队交给应用的，应用处理到某个字符时才打开新窗口、移走焦点，那么已经提交、但应用还没处理的后续字符也可能落到新焦点上。**这种情况下错发的字符数没有上限保证**，逐字符检查只能缩小范围，不能证明零错误输入；发送后的复查也不能保证发现所有瞬时的焦点变化。代价：每个字符多一次辅助功能读取，长文本会变慢。按元素打字时，如果目标是没有焦点的网页输入框，引擎会先点击它再打字。条件是：目标位置必须通过 G2 的文本输入框检查（`type_target_not_text`），并且发送前绑定窗口里必须有可编辑文本获得焦点（`type_focus_not_text`）。这次点击本身就是一次外部输入，之后的任何失败一律记为送达未知（#171 §1.1），不会标为未执行。
- **代价**：没有焦点窗口的应用（例如从未被激活过的后台应用），以及读不出焦点所在窗口的应用，所有按键和打字都会被拒绝。这是 fail closed 的结果，真机上的实际影响要等能建立绑定之后再验证。

**明确接受的残余风险：目标应用内部的自动补全列表（Kevin 2026-10-09，#163 选方案 A）。** 打字前先点击网页输入框、或打出某个字符之后，应用可能弹出自动补全列表（同样处在弹出菜单层），而焦点仍在绑定窗口的输入框里。引擎在打字过程中**不**因此停下，因为逐字符检查菜单（方案 B，8788c3d）会让地址栏、搜索框这类常见输入只能打进一个字符，属于不可接受的功能退化。这时补全列表可能改变实际输入的位置或内容。仍然保留的约束有：每个字符发出之前都重新确认焦点在绑定窗口，焦点不在或读不出就立即停止；换行只能是最后一个字符，所以打字过程中不会选中补全项；发送后出现菜单，记为送达未知（`menu_opened_by_action`），不会报成已发出；执行结果未知时不会自动重试。因为补全可能影响实际输入，**不能只凭焦点正确就认定文本已经正确输入**：回执的 `businessResult` 始终是 `not_evaluated`，实际内容要靠后续观察确认。

**残余风险：检查和发送不是原子的。** 平台接口无法保证，在"读焦点"和"发送按键"之间焦点不被移走。发送之后会再读一次菜单状态和焦点：发送前已确认没有打开的菜单，所以发送后出现菜单、或者读不出菜单状态，都说明这次输入可能打开了菜单，焦点也可能随之移走，记为"送达未知"（`menu_opened_by_action`，Codex 在 b258049 上的意见）；没有菜单时，只有确认焦点**仍在**绑定窗口才算已发出：焦点在别的窗口，记为"送达未知"（`focus_moved`）；读不出焦点或读不出它所在的窗口，也记为"送达未知"（`focus_unverified_after_send`，Codex 在 9ed802d 上的意见）。凡是"读不出"的分支，发送前一律拒绝（`notSent`），发送后一律记为送达未知：其中包括窗口列表。绑定窗口在屏幕上时，一定会出现在它所属进程的窗口列表里，列表里找不到它就说明列表读不出来，发送前拒绝（`window_list_unverified`），发送后记为送达未知。两者都不会算作成功，也不会自动重试。代价：在带自动补全的输入框里打字时，补全列表同样处在弹出菜单层，这类打字之后会报送达未知。但焦点在两次读取之间离开又回来，是发现不了的。所以这里实现的是"发送前后都核对过的窗口级检查"，不是严格的窗口级隔离。
