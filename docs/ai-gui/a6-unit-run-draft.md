# A6（PR2d）unit.run 接入草案：契约增量与测试清单

状态：**草案，未实现**。L-AIGUI（2ndscreen-40）起草，2026-10-08。

- 契约部分（第 3 节）只是提议。按 plan 2.1 和冻结规则第 3 条，由集成负责人（2ndscreen-5c）改 `runtime.schema.json` / `methods.json` / 冻结文档之后才算数。
- 本草案不改任何代码，也不改冻结目录。

权威顺序：ADR v2.2 > `docs/architecture/runtime-api-v1-freeze.md` > `docs/plan/` > 本草案。

## 1. 开工门槛

A6 正式接线前，下面四项都要已经合入 foundation。只看 A0 和 PR2b 合没合并不够（Kevin 2026-10-08）：

| 前置 | 内容 | 我依赖它的原因 |
| --- | --- | --- |
| A0 | 仓库收敛：本地 engine/、一个 CLI、一个 Runtime 入口 | 代码基线 |
| G0 | 窗口一致性：截图、AX、输入、验证都作用于同一个绑定窗口；包含检查与使用之间竞态（TOCTOU）的处理和真机回归 | Explorer 的观察与输入全部经 Runtime；G0 不过，unit.run 不能标为可发布 |
| A3 / AX | AX 整树总时限、隔离、partial 观察 | 观察降级要靠 `coverage` / partial 判断 inconclusive |
| PR2b | 单一端点，ai.* 迁到 runtime/1，handler 拿到 CommandContext | unit.run 的身份只来自 CommandContext |

## 2. 三条原则（Kevin 2026-10-08）

1. **Runtime 是唯一的 Run 生命周期管理者。** Explorer 不再有自己的状态机和运行记录库。下面这些在 A6 里删除或降为内部实现：
   - `RunLifecycle` 作为权威的身份；
   - `gui_runs`、`gui_run_events`、`gui_inference_steps`、`gui_inference_receipts` 四张表；
   - `SQLiteGuiRunRepository`；
   - `GuiAuditPort` 的推理记账；
   - `gui.runs.*` 的 handler；
   - CLI `gui run/get/cancel/events`。

   Run 的状态和持久化规则沿用 ADR v2.2 和 PR1 的 RunStore。
2. **身份只来自认证上下文。** owner、ownership、lifetime、origin 只看 CommandContext 里已认证的主体：
   - 主窗口在进程内调用 → `platform / platform_durable / gui_explorer`；
   - 任何线协议调用 → `external_client / connection_scoped / agent_hub`。

   params 里的 `clientId`、`agentId`、`origin`、`lifetime`、`ownership`、`trusted` 一律不作为依据。出现 `origin`、`lifetime`、`ownership` 时返回 `ownership_escalation_denied`，并且不创建 Run（GX-21）。
3. **审计贯穿同一个 runId。** 推理尝试、Observation、Action、回执、验证都能用同一个 Runtime `runId` 关联起来：
   - 推理只由 AiService 记一次（GX-02），`purpose.guiStep.runId` 就是 Runtime 的 runId；
   - 动作回执在 Runtime 的 RequestLedger 里，`ActionReceipt.proposalId` / `inferenceAttemptId` 指回推理。

## 3. 契约增量（F40-02、03、05、06，待 5c 合入）

### 3.1 F40-02 `Run.unit`

`kind = unit` 时必填，其他 kind 不出现。

```json
"RunUnit": {
  "type": "object", "additionalProperties": false,
  "required": ["mode", "goalHash", "guiProfileId", "guiProfileRevision", "inferenceAttempts", "steps",
               "verification", "episodeEligible", "excludedReason"],
  "properties": {
    "mode": { "enum": ["auto", "replay_only", "explore"] },
    "goalHash": { "type": "string", "pattern": "^sha256:[0-9a-f]{64}$" },
    "guiProfileId": { "type": ["string", "null"] },
    "guiProfileRevision": { "type": ["integer", "null"], "minimum": 1 },
    "inferenceAttempts": { "type": "integer", "minimum": 0 },
    "steps": { "type": "integer", "minimum": 0 },
    "verification": { "$ref": "#/$defs/UnitVerificationResult" },
    "episodeEligible": { "type": "boolean" },
    "excludedReason": { "type": ["string", "null"], "maxLength": 96 }
  }
}
```

字段说明：
- `goalHash`：对目标描述做 sha256，参数值不参与计算（05 文件 5.3，参数和步骤分开存）。
- `guiProfileId` / `guiProfileRevision`：`replay_only` 时可以为 null（inferenceBinding 可空，07 文件第 76 行）。
- `episodeEligible` / `excludedReason`：学习层预留，现在只写不读。有 unknown 动作、partial 观察或人工介入时，写 `false` 和原因。
- `UnitVerificationResult`：`{ status: matched | contradicted | inconclusive | not_run, verifierId, observationId?, checkedAt? }`。三值语义是 X1 的内容，A6 先用 `matched` / `contradicted` / `not_run`。

Run 的 `outcome` 怎么映射：

| Explorer 结束原因 | Run |
| --- | --- |
| 验证 matched | `outcome: success` |
| 验证一直未达成、步数或时限用尽、模型无效建议（含 MODEL_EMPTY_RESPONSE） | `outcome: failed`；原因写在 `closingReason` 和最后一个 `unit.*` 事件里，不用错误码表达 |
| 用户或调用方取消 | `outcome: cancelled` |
| 动作结果未知（executor 无回执、重启） | `outcome: unknown`，`unknownActions ≥ 1`；不自动重发 |
| 需要人（needs_user） | `phase: waiting_input` |

### 3.2 F40-03 unit 事件目录（`RunEvent.type` 和 `data`）

都是追加写，每条带 `sourceEventId` 去重（05 文件 5.3）。`data` 不放截图字节、键入正文、参数值和密钥。

| type | data 必填字段 | 何时发 |
| --- | --- | --- |
| `unit.observation` | observationId, captureSequence, coverage{ax, screenshot}, partial | 每次观察 |
| `unit.inference.attempt` | stepIndex, inferenceAttemptId, state（succeeded/failed/cancelled/discarded）, modelProfileRevision, usage?（缺失为 null，不填 0）, errorCode? | 每次模型调用结束 |
| `unit.step.proposed` | stepIndex, proposalId, inferenceAttemptId, kind（action/wait/finish/needs_user）, actionKind? | 建议通过校验 |
| `unit.step.rejected` | stepIndex, inferenceAttemptId, reason（invalid_target / forbidden_action / stale_observation / model_empty_response …） | 建议被拒、没有派发 |
| `unit.action` | stepIndex, actionId, proposalId, deliveryState, dispatchSequence | 引用 Runtime 回执，不复制回执内容 |
| `unit.recovery` | stepIndex, kind（reobserve_after_empty_reply / reobserve_after_stale …）, count | 有界恢复（#46 的规则） |
| `unit.verification` | status, verifierId, observationId, checkedAt | 每次验证 |
| `unit.progress` | stepIndex, stepsLeft, attemptsLeft, secondsLeft | 每步开始，供 U7 显示进度 |

生命周期事件（phase / outcome 的变化）照用 Runtime 现有的 `run.*` 事件，不另外定义 unit 版本。

### 3.3 F40-05 验证谓词迁入 `runtime.schema.json`

把 ai/1 `domain.schema.json#/$defs/GuiVerification` 原样搬过来，作为 `UnitVerification`。`unit_run_params.verification` 改为 `{ "all": [UnitPredicate, …] }`，冻结文档第 5 节已经是这个形状。A6 只带一个谓词，形状不变：

```json
"UnitPredicate": { "oneOf": [
  { "type": "object", "additionalProperties": false, "required": ["kind", "role", "text"],
    "properties": { "kind": { "const": "element_text_equals" }, "role": { "const": "static_text" },
                    "text": { "type": "string", "minLength": 1, "maxLength": 1024 } } }
]},
"UnitVerification": { "type": "object", "additionalProperties": false, "required": ["all"],
  "properties": { "all": { "type": "array", "minItems": 1, "maxItems": 8, "items": { "$ref": "#/$defs/UnitPredicate" } } } }
```

GX-13…16 的新谓词（not、found、歧义）在 X1 里追加，作为 `oneOf` 的新分支。

### 3.4 F40-06 unit.run 启动前置检查

全部在创建 Run 之前做，任何一项失败都不建 Run。错误码只用冻结表里已有的，`details.reason` 固定为下表的值：

| 顺序 | 检查 | error.code | details.reason |
| --- | --- | --- | --- |
| 1 | params 带 `origin` / `lifetime` / `ownership` | `ownership_escalation_denied` | `ownership_from_params` |
| 2 | schema 不通过（含未知 allowedActions） | `schema_invalid` | —（`fieldErrors`） |
| 3 | 本机没有通过 G0 的 GUI 执行后端（真机输入未开启） | `unsupported_backend` | `gui_execution_off` |
| 4 | 输入被 stopAll 关闭 | `input_disabled` | — |
| 5 | desktopId 不存在 | `not_found` | `desktop_not_found` |
| 6 | Desktop 被其他控制者持有 | `control_busy` | — |
| 7 | 没给 guiProfileId，也没有默认 GUI 配置 | `not_found` | `no_default_gui_profile` |
| 8 | guiProfileId 不存在 | `not_found` | `gui_profile_not_found` |
| 9 | `expectedProfileRevision` 不是当前版本 | `conflict` | `profile_revision_changed`（附 `currentRevision`） |
| 10 | 配置的连接或模型已停用 | `conflict` | `disabled` |
| 11 | 凭据缺失或已撤销 | `model_unavailable` | `credential_required` / `credential_revoked` |
| 12 | 该配置的版本没有通过 GUI 契约测试 | `capability_mismatch` | `gui_contract_not_passed` |
| 13 | 后端不支持 allowedActions 中的某个动作 | `capability_mismatch` | `action_unsupported` |
| 14 | 后端不支持某个验证谓词 | `capability_mismatch` | `predicate_unsupported` |
| 15 | `replay_only` 但没有可用流程（L3 之前恒为此） | `capability_missing` | `replay_not_available` |

运行中出现的错误不走这张表，写进 Run 的 `closingReason` 和事件（见 3.1）。

## 4. F40-04 按 runId 汇总用量

`ai.usage.summary` 增加可选参数 `runId`，和 `from` / `to` 互斥，返回该 Run 的推理尝试次数、token 和费用。规则：
- 缺失的 usage 计为 unknown，不按 0 算；
- 只认 AiService 账本，Explorer 不另外累计；
- 调用方只能查自己有权看的 Run，否则返回 `not_found`。

## 5. 测试清单（A6 的验收）

| 用例 | 断言 | 现有基础 |
| --- | --- | --- |
| GX-01 | 一次 unit.run：建议、回执、新观察、验证都在同一个 runId 的时间线上，`sequence` 连续 | `mac001_neutralHappyPath` 改为走 RunStore |
| GX-02 | 每个推理尝试在 AiService 账本里只有一行；Explorer 只引用 inferenceAttemptId | 删掉 GuiAuditPort 推理记账后的计数测试 |
| GX-03 | 模型 finish 但新观察未达标 → `outcome: failed`，不判成功 | `gui003_finishWithoutTheTextDoesNotSucceed` |
| GX-04 | 非法动作 → `unit.step.rejected`，dispatch=0 | Codec 测试 + 新事件 |
| GX-05 | 必需图像被剥离 → 明确失败，dispatch=0 | 现有图像预算测试 |
| GX-06 / 07 | 回退模型协议不兼容 → capability_mismatch；同协议首个 503 → 预算内切换，动作最多一次 | 现有 StepInference 测试 |
| GX-08 | 运行中修改默认 GUI 配置：运行中的 Run 用旧版本，新 Run 用新版本 | 现有绑定测试 |
| GX-09 | 主窗口进程内发起，关闭 Explorer 页面后 Run 继续（Durable） | 新增，需要 F40-01 的进程内入口 |
| GX-10 | 线协议发起 → Delegated；断开连接后进入 stopping、ended，closingReason=owner_lost，重连不恢复 | 新增 |
| GX-11 | RunStore 或事件写失败 → `audit_unavailable`，下一次模型调用和输入都不发；之前已执行的动作保留原状态 | `eventWriteFailureStopsBeforeInput`（#40）改为走 RunStore |
| GX-12 | 两个 Desktop 同时 unit.run：历史、预算各自独立；取消 A 不影响 B | 新增 |
| GX-21 | 同一 unit.run 在不同主体下的所有权：进程内 → platform；线协议（含本机 owner）→ external_client；params 带 origin/lifetime/ownership → `ownership_escalation_denied` 且 Run 数不变 | 新增 |
| ADR-05…08、10 | 按 ADR v2.2 第五节 | 由 5c 的 PR1 测试扩展到 kind=unit |
| #46 回归 | 空回复：每步只重新观察一次；第二次空回复 → `outcome: failed`，事件带 `model_empty_response`；不重放输入 | `EmptyReplyRecoveryTests` 改为走 RunStore |
| G0 联动 | Runtime 返回 `stale_observation` / `target_moved` 时，Explorer 不再调用模型、不切换窗口、不重放 | 新增，依赖 G0 |

真机部分（G0 回归通过之后）：MAC-001 完整重跑。覆盖 Safari 新开窗口、窗口被遮挡、检查之后输入之前弹出新窗口、目标失效、AX 异常、模型空回复、Audit 写入失败。通过的记录另写新文件，不覆盖 `docs/acceptance/mac-001-2026-10-08.md`。

## 6. 不在 A6 里做

- X1 的三值谓词、进展检测和循环检测（GX-13…20）。
- 学习层 L1–L4：只写 5.3 节的预留字段，不建库。
- Windows Explorer 主循环：C# 端目前只有 codec，随 L-Win 另排。
- 新的 Explorer 功能：Kevin 2026-10-08 明确不扩大范围。
