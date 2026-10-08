# 3 Runtime 契约

基线：`contracts/runtime/v1/` @ ai-gui-foundation c8833c4（含 #33 的 ADR v2.2 Run 模型）。本文给出 v1 冻结时的完整方法表、对象模型、状态机与错误码，标明「已实现 / 新增 / 修改 / 删除」。冻结在 PR A1 完成，之后只由集成负责人修改；字段名以 schema 为准，本文是语义说明。

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

## 3.2 方法表

| 方法族 | 方法 | 状态 | 说明 |
| --- | --- | --- | --- |
| runtime | `runtime.handshake` | 已实现，修改 | 增加客户端凭据认证；返回 `RuntimeIdentity` 与本连接的 `principal`（clientId、kind=owner/paired_client、grants 摘要） |
| | `runtime.status`、`runtime.capabilities` | 已实现，修改 | capabilities 合并 interface、backend、ai、gui、hub、learning 能力；未实现的能力不公布 |
| | `runtime.stopAll`、`runtime.enableInput` | 已实现 | 全局停止与显式重开输入（ADR-09） |
| | `runtime.events` | 新增 | 全局事件游标：desktop、run、connection、grant、inbox 变化；`afterSequence` 游标，过期返回 `events_cursor_expired` |
| desktop | `desktop.list`、`desktop.show` | 已实现，修改 | 增加 `control`（见 3.3） |
| | `desktop.create` | 已实现，修改 | 增加可选 `launch {bundleId|path}` 或 `bind {pid, windowId}`；返回 `state=creating`，就绪后 `ready` |
| | `desktop.destroy` | 已实现，修改 | 先执行 `desktop.stop` 并等静止，再释放资源；只结束本 Desktop 启动的进程 |
| | `desktop.closePlan` | 新增 | 只读：列出将结束的专有进程、保留的宿主共享进程、画面资源与结果文件，供关闭确认（P18） |
| | `desktop.stop` | 新增 | 停止该 Desktop 上持有租约的 Run：撤销新输入、清空待执行输入、释放按住的键；回执分受理与静止（P14–P15） |
| | `desktop.takeover`、`desktop.handback` | 新增 | 人工接管：等当前输入静止后建 `origin=user, ownership=platform` 的租约 Run；交还时结束该 Run 并重新观察，不重放旧队列（P12–P13） |
| app / window | `app.list`、`app.launch`、`window.list`、`window.bind`、`window.unbind` | 已实现 | `app.quit` 新增（旧 CLI `app quit` 的能力，只结束本 Desktop 启动的进程） |
| session | `session.open/show/close` | 已实现 | |
| 观察与动作 | `observe` | 已实现，修改 | 允许只给 `desktopId`（隐式会话）；Observation 增加 `targetKind`、`geometryRevision`、`captureSequence`、`coverage` |
| | `act` | 已实现，修改 | Action 增加 `hover`、`drag`、`press`（AX 按压）；允许只给 `desktopId`；执行前在原生入口重验目标几何与代次（Explorer B03） |
| | `wait` | 已实现 | |
| | `request.show` | 已实现 | |
| | `request.list`、`request.export` | 新增 | 动作记录：按 desktopId、clientId、runId、状态、时间筛选，游标分页；导出 JSON 与引用的图像（P19–P20） |
| | `action.reconcile` | 新增 | 对 unknown 动作追加核实结论（executed / not_executed / still_unknown）与证据；原 outcome 永远保持 unknown（Hub W07） |
| run | `run.start`、`run.attach`、`run.finish`、`run.show`、`run.events`、`run.wait`、`run.cancel`、`run.list` | 已实现 | ADR 三轴模型 |
| | `unit.run` | 新增 | GUI 单元：`desktopId`、`mode=auto|replay_only|explore`、`goal`、`verification`（三值谓词）、`allowedActions`、`guiProfileId?`。平台调用（UI）建 Durable Run；外部 Agent 调用建 Delegated Run |
| ai | `ai.connections.list/get/upsert/disable`、`ai.credentials.rotate`、`ai.models.discover/upsert`、`ai.guiProfiles.list/get/upsert/setDefault`、`ai.capabilityTests.start/get/cancel`、`ai.usage.summary`、`ai.inference.get` | 迁移 | 从 ai/1 迁入 runtime/1，语义不变；`gui.runs.*` 删除 |
| hub | `hub.pairing.open`、`hub.pairing.request`、`hub.pairing.decide`、`hub.clients.list/show/remove`、`hub.grants.list/set/revoke`、`hub.connections.list` | 新增 | 见 04 文件 |
| inbox | `inbox.list`、`inbox.decide` | 新增（P1） | 平台审批：一次 permit 绑定动作指纹、目标、代次与期限（Hub W06） |
| learning | `gui.knowledge.*`、`gui.procedures.*`、`gui.validations.*`、`gui.demonstrations.*`、`gui.learning.settings.*` | 预留（P2） | 方法名进入 methods.json 并标 `stage: P2`；未实现前 capabilities 不公布 |

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

新增：

| code | 何时返回 |
| --- | --- |
| `pairing_required` | 未配对的客户端调用需要授权的方法 |
| `client_revoked` | 客户端已被移除 |
| `grant_missing` / `grant_expired` | 动作所需能力或 Desktop 不在当前授权内 / 已过期 |
| `permit_expired` | 审批许可过期、已消费或代次失效 |
| `target_moved` | 执行入口发现目标几何或绑定代次与观察不一致（修复 M0 预演的误点问题） |
| `audit_unavailable` | 证据写入失败；暂停新输入 |
| `unsupported_backend` | 后端不支持该动作的后台执行；不静默改用前台或真实鼠标 |
| `events_cursor_expired` | 事件游标过期，需重新取快照 |
| `capability_mismatch` | GUI profile 与回退模型的动作协议不兼容 |

## 3.6 冻结方式

A1 PR 一次性提交：methods.json（含 stage 与 mutation 标记）、errors.json、runtime.schema.json、正负 fixtures；Swift 与 C# 各用同一份 golden 做解码、编码、规范化 JSON 哈希的逐字节比对；方法表重复注册在启动与测试时失败。冻结后新增字段按版本说明追加，不改已有语义。
