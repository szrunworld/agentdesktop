# 3 Runtime 契约

**权威**：[`docs/architecture/runtime-api-v1-freeze.md`](../architecture/runtime-api-v1-freeze.md) 与 `contracts/runtime/v1/methods.json`（#34，PR2a，2ndscreen-f1（原 5c））。冻结目录里已有的方法名、信封、错误码以冻结文件为准，本文不再重复定义。

本文只做两件事：一是说明本规划依赖冻结目录里的哪些方法；二是列出冻结目录尚未包含、本规划提出的**增量**。增量按冻结规则第 3 条，必须先由集成负责人改 `methods.json` 与冻结文档，再写实现；在那之前它们只是提议。

## 3.1 信封与通用规则（已实现，A1 补齐）

```json
{ "apiVersion": "agentdesktop.runtime/1", "requestId": "req_…", "method": "…",
  "deadline": "2026-10-08T08:00:10Z", "context": { "sessionId": "ses_…" }, "params": { } }
→ { "apiVersion": "agentdesktop.runtime/1", "requestId": "req_…", "ok": true, "data": { } }
→ { "ok": false, "error": { "code": "…", "message": "…", "phase": "…", "retryable": false, "details": { } } }
```

- 一个端点：macOS 为属主独占的 Unix socket，Windows 为当前用户 named pipe。同一连接内按序请求响应；先 `runtime.handshake` 再调用其他方法。
- 幂等：唯一键（认证主体, requestId）。语义指纹覆盖 method、params、目标与执行 deadline。同键同义返回原回执；同键异义返回 `idempotency_conflict`；过期详情保留最小墓碑，不把旧 ID 当新动作。
- `deadline` 只限制本次受理或查询的等待；后台 Run 的截止时间来自受理时冻结的执行限额。关闭 RPC 连接不取消已受理的 Durable Run；Delegated Run 按 3.4 处理。
- 错误不回显 API key、键入正文、截图或参数值。
- 主体身份来自连接认证（4 文件），不信任 params 里的 clientId、trusted、owner 字段。

## 3.2 方法

### 依赖的冻结方法（以 #34 为准）

| 族 | 方法 | 冻结状态 | 本规划用途 |
| --- | --- | --- | --- |
| 平台 | runtime.handshake（含 `principal{clientId, role, connectionId}`）、status、capabilities、stopAll、enableInput | 已实现 | 所有工作线 |
| Desktop 与输入 | desktop.*、app.*、window.*、session.*、observe、act、wait、request.show | 已实现 | U2、U3、A5 |
| Run | run.start/attach/finish/show/events/wait/cancel/list | 已实现 | U5、ADR 门禁 |
| GUI 单元 | unit.run | frozen（PR2d） | A6、X1、U7 |
| 事件 | events.subscribe / unsubscribe | frozen（PR2e） | U1 Store、U5 |
| 产物 | artifact.show / read | frozen（PR2c） | U5 回执图像、SDK |
| AI | ai.connections.*、ai.credentials.rotate、ai.models.*、ai.modelProfiles.*、ai.profiles.*、ai.tests.start、ai.operations.*、ai.usage.summary | frozen（PR2b，名字沿用 ai/1） | U6 |
| 身份 | hub.pairing.start/status/approve/deny、hub.clients.list/show/revoke、hub.grants.list/set/revoke、hub.connections.list | reserved（PR3） | A4、U4 |
| Inbox 与核实 | inbox.list/show/resolve、run.reconcile、diagnostics.export | reserved（PR4） | U9 |
| 学习 | gui.knowledge.*、gui.procedures.*、gui.validations.*、gui.demonstrations.*、gui.learning.settings.* | reserved（PR7） | L1–L4 |

### 本规划提出的增量（待集成负责人纳入目录）

| 方法或字段 | 用途 | 依据 |
| --- | --- | --- |
| `Desktop.control`（见 3.3） | 总览与详情显示控制状态、控制者、动作数 | Design P01、P06、P13–P16 |
| `desktop.stop` | 只停一个 Desktop 的输入，回执分受理与静止 | Design P14–P15、UC08–UC10 |
| `desktop.takeover` / `desktop.handback` | 人工接管：建 `origin=user` 的平台租约 Run；交还时结束并重新观察，不重放 | Design P12–P13、UC11–UC15 |
| `desktop.closePlan` | 关闭前列出将结束与将保留的资源 | Design P18、UC16–UC18 |
| `desktop.create` 的 `launch` / `bind` 可选参数，`desktop.resize` | 一步创建并启动或绑定；调整尺寸 | Design P04–P05；旧 `screen resize` |
| `app.quit` | 只结束本 Desktop 启动的进程 | 旧 `app quit`（07 文件） |
| `request.list` / `request.export` | 动作记录筛选、分页、导出 | Design P19–P20、UC26–UC28 |
| Action 增加 `hover`、`drag`、`press` | 补齐旧 CLI 能力 | 07 文件 7.2 |
| observe 与 act 只给 `desktopId` 时隐式会话 | 外部 Agent 简化调用 | Design P09 CLI 示例 |
| ActionReceipt 增加 `businessResult: "not_evaluated"`、`elapsedMs`、`clientId`、`geometryRevision`、`dispatchSequence` | 回执与业务结果分离；学习层预留 | Design 交接规则、05 文件 5.3 |
| 目标 `kind: window \| device` | Android 设备目标 | 裁决 D19 |
| 错误码 `target_moved`、`unsupported_backend`、`audit_unavailable`、`grant_missing`、`grant_expired`、`permit_expired`、`pairing_required`、`client_revoked` | 见 3.5 | — |

## 3.3 对象模型

已有对象（Desktop、Session、Observation、ActionReceipt、Run、RuntimeIdentity、Capabilities）的新增字段：

```text
Desktop.control = {
  state: creating | ready | running | manual | stopping | stopped | disconnected | unknown | error,
  controllerRunId?, clientId?, clientName?, transport?: cli | mcp | sdk | ui,
  since, actionCount, lastActionAt?
}
Desktop.targetKind = window | device        // 首发只有 window

Observation += targetKind, geometryRevision, captureSequence, coverage {ax, screenshot, ocr}
ActionReceipt += clientId, origin, proposalId?, inferenceAttemptId?, dispatchSequence,
                 geometryRevision, elapsedMs, businessResult: "not_evaluated",
                 reconciliations: [ {at, verdict, evidenceRef, by} ]
Run (已实现) = { runId, kind, origin, ownership, lifetime, clientId?, connectionId?, sessionId,
                 desktopId, phase, outcome, quiescence, closingReason, revision, createdAt,
                 endedAt?, receipts, unknownActions }
Run += unit? { mode, goalHash, guiProfileRevision?, inferenceAttempts, steps }   // unit.run 时
```

新增对象：

| 对象 | 字段 |
| --- | --- |
| Client | clientId（平台签发，稳定）、agentName（自报，仅显示）、publisher、signingIdentity?、registeredAt、removedAt? |
| Connection | connectionId（每次连接新建）、clientId、transport、state（3.4）、lastHeartbeatAt |
| Grant | grantId、clientId、capabilities[]、desktops[]（不默认「所有」）、targetApps[]、expiresAt、limits、revision、state（active/expired/revoked） |
| PairingRequest | pairingId、shortCode、requested{capabilities,desktops,apps,duration}、callerFacts（运行来源核验）、callerClaims（自报）、state（3.4）、expiresAt |
| InboxItem | inboxId、kind（approval/question/login/review）、runId、clientId、action{effect,app,target,label,fingerprint}、expiresAt、state |
| Reconciliation | actionId、verdict、evidenceRef、by、at |

学习层预留（不实现，但字段现在就写进 Run / Receipt / Observation，见 05 文件 3 节）：`episodeEligible`、`excludedReason`、`afterDispatchSequence`、`resetId?`、`layoutTag?`。

## 3.4 状态机

**Run（已实现）**：三轴 `phase × outcome × quiescence`。
- phase：queued → running ⇄ waiting_approval / waiting_input → stopping → ended。
- `ended` 必须 `quiescence=confirmed`；`ended + outcome=unknown` 合法。
- 停止受理只把 phase 置为 stopping、quiescence 置为 pending；拿到执行端静止证据才 ended/confirmed。
- Delegated Run：控制连接失效 → 立即拒绝新输入 → stopping → ended（closingReason=owner_lost）；重连不恢复。
- Durable Run：UI 页面关闭、订阅断开不影响；Runtime 重启后按账本恢复，不能证明安全则 outcome=unknown（closingReason=runtime_restarted）。

**Desktop.control（新增，派生）**：

| state | 条件 |
| --- | --- |
| creating | desktop.create 受理、资源未就绪 |
| ready | 无租约 Run，输入准入开放 |
| running | 有 Delegated 或 Durable Run 持有租约 |
| manual | 持有租约的 Run `origin=user`（人工接管） |
| stopping | 持有租约的 Run phase=stopping |
| stopped | 上一个 Run 刚结束且由停止导致，直到新 Run 或用户清除 |
| disconnected | 上一个 Delegated Run 以 owner_lost 结束 |
| unknown | 上一个 Run outcome=unknown 且有未核实动作 |
| error | 资源错误（显示丢失、权限撤销） |

**Connection**：connecting → connected → heartbeat_stale（暂停新输入）→ disconnected；任意状态 → revoked（客户端被移除或授权全部撤销）。

**Pairing**：open（Owner 在 UI 打开短期配对窗口）→ requested（客户端发起）→ approved / denied / expired。approved 后签发凭据，不自动运行任何业务。

**Grant**：active → expired / revoked。收窄立即生效：最终原生入口按当前 `policyEpoch` 判定。

**Action delivery**：reserved → dispatch_intent（落盘）→ delivered → confirmed；或 not_sent（派发前取消/拒绝）、rejected、unknown（可能已派发但回执丢失）。unknown 只能追加 Reconciliation。

## 3.5 错误码

已有 29 个：invalid_argument、schema_invalid、frame_too_large、not_found、invalid_target、runtime_offline、permission_denied、ownership_escalation_denied、approval_required、control_busy、stale_observation、idempotency_conflict、conflict、run_not_active、input_disabled、stop_pending、handshake_required、version_mismatch、instance_mismatch、capability_missing、model_unavailable、execution_failed、internal_error、wait_timeout、deadline_exceeded、connection_lost、request_acceptance_unknown、action_delivery_unknown、cancel_acceptance_unknown。

#34 另加了 `limit_exceeded`、`events_cursor_expired`。本规划提议新增：

| code | 何时返回 |
| --- | --- |
| `pairing_required` | 未配对的客户端调用需要授权的方法 |
| `client_revoked` | 客户端已被移除 |
| `grant_missing` / `grant_expired` | 动作所需能力或 Desktop 不在当前授权内 / 已过期 |
| `permit_expired` | 审批许可过期、已消费或代次失效 |
| `target_moved` | 执行入口发现目标几何或绑定代次与观察不一致（修复 M0 预演的误点问题） |
| `audit_unavailable` | 证据写入失败；暂停新输入（#34 目前映射为 internal_error + details.reason，提议升为独立码，便于 UI 与客户端区分） |
| `unsupported_backend` | 后端不支持该动作的后台执行；不静默改用前台或真实鼠标 |
| `capability_mismatch` | GUI profile 与回退模型的动作协议不兼容 |

## 3.6 冻结方式

目录冻结已由 #34（PR2a）完成，规则见冻结文档第 7 节。本文 3.2 的增量由集成负责人逐项并入；每项并入时同时提交 schema、正负 fixtures 与 Swift / C# golden，Swift 与 C# 对同一 golden 逐字节一致。
