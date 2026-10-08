# ACP 对 runtime/1 的需求清单（工作线 R）

状态：2026-10-08（第二轮更新：R10、事件载荷、`verified`），基于 `acp-skeleton`（含 ai-gui-foundation b2831ca）的代码与 `contracts/runtime/v1` 核对。负责人：工作线 R。由协调者转给 f1（契约负责人）与 40（unit.run）。

本文只列 ACP 需要、而 runtime/1 现在没有或没有实现的东西。每一条写明：现状证据、建议的确切形状、负责方、阻塞的 ACP 门禁（见 [06-gates.md](06-gates.md)）。原则沿用 [00 方案](00-input-plan-v1.0.md) 4.6：不为 ACP 新增 `acp.*` 专用 RPC，只提通用能力。

## 一、工作线 R 今天的实现（对照）

`Sources/AgentDesktopACP/RuntimeBridge/` 的 `ACPBridgeRuntimePort` 只经 `RuntimeClient` 调 runtime/1：

| 端口方法 | 今天 | 用到的方法 |
| --- | --- | --- |
| `caller()` | 真实，但只是本机 owner 占位，`verified: false`（见 R4） | `runtime.handshake`、`runtime.status` |
| `tasks()` | 真实；Runtime 不宣告 `unit.run` 时为空列表 | `runtime.capabilities`（有 `unit.run` 且有 `ai.profiles.list` 时再读 GUI 配置） |
| `submit()` | 没有 `unit.run` 时返回 `.refused(code: "capability_missing")`，什么都不发；有时走 `unit.run` | `unit.run`、`request.show`、`run.show` |
| `snapshot()` | 真实；`lastCursor` 在 Runtime 提供 `Run.lastEventSequence` 前为 nil（见 R10） | `run.show` |
| `cancel()` | 真实（受理回执；静止之后再到） | `run.cancel`、`run.show` |
| `events()` | 真实；单独连接，游标续传、去重；`payload` 是完整的 `RunEvent`（`runId`、`sequence`、`at`、`type`、`data`） | `events.subscribe`，回退 `run.events` |
| `pending()` / `decide()` / `answer()` / `decline()` | 抛 `capability_missing`，调用方按拒绝处理 | 无（见 R2） |
| `connectionLost()` | 真实：关闭控制连接，由 Runtime 按 ADR v2.2 停止 Delegated Run；不重连、不恢复 | 关闭连接 |

幂等：requestId = `acp-sub-` + sha256(`acp-submission/v1`、调用方、`submissionKey`) 的前 24 字节十六进制，和 CLI、MCP 的 requestId 在同一个「调用方 uid + requestId」空间里不会相撞。发送前先写 `ACPSubmissionLog`（0600 文件，只存 submissionKey → requestId / runId / 状态，不存输入）；重试只查 `request.show` / `run.show`，结果不明一律 `.unconfirmed`，绝不重发。

## 二、需求清单

### R1　`unit.run` 落地（A6 / PR2d）

- **现状**：`methods.json` 的 `catalog` 里 `unit.run` 是 `frozen`，`unit_run_params` 已在 schema 里，但 `RuntimeMethod` 没有它，`runtime.capabilities` 不列出它。编辑器因此不能交出任何任务。
- **需要**：按冻结形状实现，结果为 `Run`（kind `unit`、`external_client / connection_scoped / agent_hub`）；照常经请求账本（`mutation: true`），同一 requestId 重放原结果；实现后在 `runtime.capabilities` 里列出 `unit.run`。R 端不需要改代码：`ACPTaskCatalog` 见到能力就生成任务。
- **补充请求**（PR #50 草案范围内）：
  1. F40-06 前置检查失败时**不建 Run、不写成功账本**，`details.reason` 按草案表固定，ACP 原样展示为拒绝原因。
  2. 参数里出现 `origin` / `lifetime` / `ownership` 返回 `ownership_escalation_denied`（R 已在本地拒绝，不会发出）。
  3. `Run.unit` 字段（F40-02）与 unit 事件目录（F40-03）同时冻结，E 线按它投影。
- **负责**：40（实现），f1（契约审核）。
- **阻塞**：G1-06、G1-07、G1-08、G1-10、G1-11、G2-03、G2-04、G2-05、G2-09（真实部分）、G3-01（unit 级）。

### R2　审批与提问（Inbox，PR4）

- **现状**：runtime/1 没有任何 approval / question 方法；`inbox.list / show / resolve` 只是 🔖 reserved；错误码 `approval_required`、`permit_expired` 为 reserved。Run 的 `phase` 已有 `waiting_approval` / `waiting_input`，但读不到在等什么。
- **建议形状**（只读与决定两步，按 Run 过滤；身份取自连接）：

```json
// inbox.list  params
{ "runId": "Id?", "state": "pending | resolved | expired?", "cursor": "string?", "limit": "1..200?" }
// result
{ "items": [InboxItem], "next": "string|null" }

// InboxItem（docs/plan/03 §3.3 已登记的对象，补齐字段）
{ "inboxId": "Id", "kind": "approval | question | login | review",
  "runId": "Id", "clientId": "string", "state": "pending | resolved | expired",
  "createdAt": "Timestamp", "expiresAt": "Timestamp",
  "action": { "effect": "string", "app": "string?", "target": "string?", "label": "string?",
              "fingerprint": "string" },          // approval：目标指纹，决定时复核
  "question": { "message": "string", "choices": ["string"] },   // question
  "revision": "integer" }

// inbox.resolve  params（mutation，进账本）
{ "inboxId": "Id", "expectedRevision": "integer",
  "decision": "allow_once | reject_once | answer | dismiss",
  "answer": "string?" }
// result：InboxItem（resolved）；目标已变 → conflict（details.reason "target_changed"），
// 已过期 → permit_expired，非本人 → not_found
```

  - 事件：`inbox.created` / `inbox.resolved`（`data: {inboxId, kind}`，不含动作参数），让 ACP 不必轮询。
  - 决定只能收紧：Runtime 在派发前复核 `fingerprint`；编辑器拒绝、超时、通道不可用一律等同拒绝。
  - 不提供 `allow_always`（README §6.2）。
- **负责**：f1（PR4 契约与实现）。
- **阻塞**：G2-06、G2-07、G2-08；原文 P2-04。

### R3　事件类型目录（F1-01）

- **现状**：`RunEvent.type` 是任意字符串，`data` 是任意对象；没有冻结目录。R 原样转发 `{runId, sequence, type, data}`，E 线按草案目录投影。
- **需要**：冻结以下类型与各自 `data` 的必填字段，并写明哪些字段可能含敏感内容（标题、文本、坐标）：
  `run.started`、`action.accepted`、`action.dispatched`、`action.completed`、`action.failed`、`action.unknown`、`run.finishing`、`stop.accepted`、`run.quiescent`、`run.ended`，以及 A6 的 `unit.*`（F40-03）。
  - 每个 `data` 带稳定的来源标识（`actionId` / `receiptId` / `sourceEventId`），用于去重与审计关联。
  - 明确 `run.ended` 一定是该 Run 流的最后一条（R 用它和连接关闭共同判定流结束）。
- **负责**：f1。
- **阻塞**：G0-13、G1-08、E 线的 08 映射定稿。

### R4　调用方身份（A4 / PR2b：`handshake.principal`）

- **现状**：`runtime.handshake` 返回的是 Runtime 自己的 `RuntimeIdentity`，没有调用方；`Principal` 定义已在 schema 里，但标注「Reserved for handshake results (PR2b)」，`RuntimeIdentity` 又是 `additionalProperties: false`，客户端今天无法收到它。Runtime 内部把每个本机连接记为 `local:<uid>`（owner），`connectionId` 不告诉客户端。
- **R 今天的做法（占位）**：`principalId = clientId = "local:<本进程 uid>"`（与 Runtime 用 getpeereid 认定的一致，因为 socket 只对本用户开放），`connectionId` 取 Runtime 写在本连接所建 Run 上的 `connectionId`，还没有 Run 时为 `unissued:<instanceId>`。这**不是**认证结果，T07（无权恢复他人会话）在此之前无法真正验证。
- **需要**：
  1. `RuntimeIdentity` 增加可选 `principal: Principal`（`{clientId, role, connectionId}`），每个连接的握手结果都带上。
  2. `RuntimeClient` 暴露它（例如 `handshake()` 返回值里带 `principal`，或新增 `principal()`）。
  3. 配对客户端（`app:<id>`，role `paired`）只看见自己的 Run / 请求 / 事件，ACP 会话按 `clientId` 隔离。
- **A4 之后 R 要改的**：`caller()` 直接取 `principal` 并置 `verified: true`；requestId 派生里的调用方改用 `principal.clientId`；`ACPSubmissionLog` 按 clientId 分区。接口 `ACPCaller` 不变。
- **负责**：f1（A4 / PR2b），Client 的改动由 f1 一并做。
- **阻塞**：G1-09、G2-01（真实身份）、G2-02、G2-08。

### R5　按调用方与来源列出 Run

- **现状**：`run.list` 有 `clientId` / `origin` / `active` 过滤；但 A4 之前所有本机连接都是同一个 `local:<uid>`，ACP 无法区分「本编辑器连接建的 Run」与 CLI、MCP 建的 Run；Run 也不记录是由哪种入口建的。
- **需要**：
  1. `Run` 增加可选 `client: { name, transport }`（`transport: cli | mcp | sdk | acp | ui`，`name` 取握手的 `client.name`，只用于显示与过滤，不作授权依据）——docs/plan/03 已登记 `Desktop.control.transport`，Run 上用同一取值。
  2. `run_list_params` 增加可选 `connectionId`（仅能过滤本主体可见的 Run）与 `transport`。
- **用途**：会话恢复时把 ACP 绑定里的 `runIds` 与 Runtime 对账（G2-01）；Durable Run 的只读观察列表（README 决策 K1）。
- **负责**：f1。
- **阻塞**：G2-01 的对账部分；K1 的只读观察。

### R6　任务目录（非 GUI 单元任务）

- **现状**：唯一可能的任务入口是 `unit.run`；没有「已注册 Agent / 平台任务」的目录方法。`ACPExposedTask` 需要的 `requiresApproval`、`dataClassification`、`allowFreeText`、输出 schema 都没有权威来源，R 目前按 `unit.run` 固定取值（需要审批、`desktop_content`、允许自由文本）。
- **需要**（方案 4.5 的 Registry）：

```json
// task.catalog.list  params
{ "cursor": "string?", "limit": "1..200?" }
// result
{ "tasks": [ { "taskType": "string", "displayName": "string", "description": "string",
               "entry": { "method": "unit.run", "fixed": { /* 任务固定的参数，如 guiProfileId、mode */ } },
               "inputSchema": {}, "outputSchema": {},
               "allowFreeText": true, "freeTextField": "goal.description",
               "requiresApproval": true, "requiredCapabilities": ["string"],
               "dataClassification": "public | internal | desktop_content | personal" } ],
  "next": "string|null" }
```

  只返回该主体有授权的任务；`entry.method` 只能是 Runtime 已宣告的方法。R 的 `ACPTaskCatalog` 已按「方法宣告 → 任务」组织，届时改为读这个目录。
  - 同时请定义自由文本映射：`freeTextField` 指明 prompt 文本放进哪个参数，其余必填参数（`verification`、`allowedActions`、`mode`）由任务固定值给出；否则编辑器的一句话无法满足 `unit_run_params` 的必填项。
- **负责**：f1（与 Agent Hub / 40 协商）。
- **阻塞**：G1-07（非 unit 任务）、G1-09（T15 无权限任务）。

### R7　请求账本的可确认性

- **现状**：`request.show` 对账本里没有的 requestId 返回 `not_found`。这无法区分「从未到达」与「已超出 7 天保留期」或「换了一个 Runtime 数据目录」。R 因此把 `not_found` 也当作不明（`.unconfirmed`），提交卡在待核实，用户只能重新发起。
- **需要**：`request.show` 的 `not_found` 带 `details: { retentionDays, oldestAcceptedAt, instanceId }`，或新增 `RequestRecord.state = "never_received"` 的明确答复（仅当 requestId 落在保留期内且本实例的账本连续时给出）。有了它，R 可以对「确定未到达」的提交安全地重新发送一次。
- **负责**：f1。
- **阻塞**：G2-09 的完整性（今天行为安全但不便利）。

### R8　取消的完成通知与 `stop.accepted`

- **现状**：`run.cancel` 返回受理回执，静止要靠 `run.wait` 或事件；`cancel_acceptance_unknown` 错误码为 reserved，客户端（CLI）自己合成。
- **需要**：
  1. 把 `cancel_acceptance_unknown` 转为正式码，说明「用同一 requestId 重复 `run.cancel` 即可得知是否已受理」。
  2. F1-01 目录里 `stop.accepted`、`run.quiescent` 两类事件保证在 Run 流里出现，ACP 不必为取消另开 `run.wait`。
- **负责**：f1。
- **阻塞**：G2-05 的事件化展示（今天可用 `snapshot` 轮询代替）。

### R9　CLI 子命令 `agentdesktop acp` 与端点

- **现状**：ACP 模块不在 CLI 里；端点解析在 `EndpointResolver`（今天默认 `runtime.sock`，A2 之后是 `control.sock`）。
- **需要**：`agentdesktop acp` 子命令用 `EndpointResolver.resolve` 取端点，构造 `ACPBridgeRuntimePort(makeClient: ACPBridgeConfiguration.socketFactory(endpoint:), log: ACPSubmissionLog(path: ACPSubmissionLog.defaultPath()))`；测试副本用 `AGENTDESKTOP_ENDPOINT`。
- **负责**：f1（CLI），协调者提出。
- **阻塞**：G1-11、所有真编辑器验收。

### R10　Run 的最后事件序号

- **现状**：`Run` 没有「最后一条事件的 sequence」。ACP 恢复会话时要知道编辑器错过了多少事件，只能把 `run.events` 从游标翻到底；`ACPRunSnapshot.lastCursor` 因此今天恒为 nil。
- **需要**：`Run` 增加可选字段 `lastEventSequence: integer ≥ 0`（该 Run 已写入的最大 `sequence`，没有事件时为 0），`run.show`、`run.list`、`run.wait` 都带上。R 已按这个名字读取（`ACPBridgeRuntimePort.lastCursorField`），字段一出现即生效，不必改代码。
- **负责**：f1（与 docs/plan/03 §3.3 的 Run 增量一起）。
- **阻塞**：G2-01 的恢复回放（今天可用 `run.events` 翻页代替，较慢）。

### R11　事件里的回执引用

- **现状**：E 线需要从事件计算耗时并关联动作回执。R 现在把完整 `RunEvent` 作为 `payload` 交给 E，时间取 `at`；但回执只在 `data` 里按事件类型约定出现，没有统一字段。
- **需要**：F1-01 目录（R3）里，凡与动作有关的事件，`data` 一律带 `receiptId`（与 `Run.receipts` 中的 ID 一致）与 `dispatchSequence`；需要耗时的事件带 `elapsedMs`（与 ActionReceipt 增量同名）。
- **负责**：f1。
- **阻塞**：E 线的耗时展示与三级结果关联（G1-08）。

## 三、汇总

| 编号 | 内容 | 负责 | 阻塞门禁 |
| --- | --- | --- | --- |
| R1 | `unit.run` 实现与宣告 | 40（f1 审） | G1-06/07/08/10/11，G2-03/04/05/09，G3-01 |
| R2 | `inbox.list` / `inbox.resolve` 与事件 | f1 | G2-06/07/08 |
| R3 | 事件类型目录 F1-01 | f1 | G0-13，G1-08 |
| R4 | `handshake.principal` 与 Client 暴露 | f1 | G1-09，G2-01/02/08 |
| R5 | Run 的入口标记与 `run.list` 过滤 | f1 | G2-01，K1 |
| R6 | 任务目录 `task.catalog.list` 与自由文本映射 | f1（与 40） | G1-07，G1-09 |
| R7 | `request.show` 的确定性未到达答复 | f1 | G2-09 |
| R8 | 取消的正式错误码与事件 | f1 | G2-05 |
| R9 | `agentdesktop acp` 子命令接线 | f1 / 协调者 | G1-11 |
| R10 | `Run.lastEventSequence` | f1 | G2-01 |
| R11 | 动作事件统一带 `receiptId` / `elapsedMs` | f1 | G1-08 |
