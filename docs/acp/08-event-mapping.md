# 08 Runtime 事件到 ACP 更新的映射规范

状态：工作线 E 第三轮，2026-10-08 晚。基于 `main` dfdfb96（ACP 已经由 #111 合入 main，事件目录由 #102 冻结）。第二轮基于 `acp-skeleton` fe1b606（含 Kevin 第二次裁决 P1、P2，README 第七节）。
实现：`Sources/AgentDesktopACP/Events/`（投影）、`Sources/AgentDesktopACP/Privacy/`（分类与脱敏）。
测试：`Tests/AgentDesktopACPTests/Events/`、`Privacy/`、`Fixtures/events/`（16 份 golden 夹具）。

依据：方案 v1.0 第五节、6.4；docs/plan/06 §6.4；README 第五节 Kevin 裁决附加约束 3（事件分三级，重点验证截图、窗口标题、输入内容、审批参数不泄露跨应用数据）；README 第七节第二次裁决 P1（窗口标题与身份信息只在主窗口展示，不进入 ACP 事件流与日志）、P2（结果不明的动作在 Run 结束后为明确终态）。

## 第二轮变更（P1、P2）

- **P1**：窗口标题（title、windowTitle、documentTitle、tabTitle）与身份信息（新增字段类 `identity`：name、displayName、userName、appName、processName、account、contact、sender、recipient、from、to、candidate 等）升为**受保护级**：任何策略下（含 `pageText` 放宽）都不进入 ACP 更新的标题、详情、摘要，也不进入 `redactJSON` / `logLine` 的日志与存储文本（一律 `[已隐藏]`）。动作自身的 title 与 summary 可能引用窗口标题或人名、无法靠正则识别，因此放宽后也不再显示；日志里的自由文本一律隐藏；`logSafe` 只记录错误码或错误类型，不记录 message。页面正文（绑定目标的元素标签）仍按 `pageText` 与脱敏规则显示。
- **P2**：Run 进行中，结果不明的动作保持 `in_progress` + level `unknown`（「结果待核实」）。`ACPProjectorSession` 看到该 Run 的 `run.ended` 时，对每个仍为 unknown 的动作（含 action.unknown、回执轴为 unknown、已发出无结果、Run 以非已知 outcome 结束时仍只到受理的动作）发一条终态 toolCallUpdate：status `failed`、level `unknown`（从不用 `.failed` / `.refused`）、标题「<动作> — 结果未知 · 需要核实」、详情「执行已终止，结果未知」与「不会重试；请在 AgentDesktop 主窗口核实结果后再决定下一步」。线上 `rawOutput {execution: terminated, outcome: unknown}` 由线 T 在 Wire 一处添加。Run 级文案改为「任务结束：结果未知 · 需要核实（…）」，plan 结果项为 completed「结果：未知 · 需要核实」（终态，不再转圈；标记失败的颜色由内容而非状态表达）。

## 第三轮：#102 对齐（2026-10-08）

#102 冻结了 Run 事件目录：`contracts/runtime/v1/runtime.schema.json:2593` `$defs/PlatformRunEvent`，共 11 个类型。投影器现在**只**认这 11 个类型；目录外的类型一律走 3.4（一条中性 thought，不读 payload）。

### 对齐覆盖（目录 → ACP）

| 目录类型 | 目录 data 字段 | 投影器读取 | 未读取（原因） |
| --- | --- | --- | --- |
| `run.started` | kind、origin、ownership、lifetime、desktopId、sessionId | kind（记入上下文）、lifetime | origin、ownership（不影响显示）；desktopId、sessionId（不对外显示） |
| `action.accepted` | requestId、kind | 两个都读 | — |
| `action.dispatched` | requestId | requestId | — |
| `action.completed` / `failed` / `unknown` | receipt（ActionReceipt） | receiptId（新增，哈希后显示「回执：…」）、requestId、delivery、execution、verification、businessResult、**reason.code（新增）**、target.windowId + elementRef（哈希）、timing（耗时） | runId/desktopId/sessionId/snapshotId、route、target.process / point / generation（坐标与 pid 不显示）；**reason.message 从不读**（可能写到其他窗口，P1） |
| `action.refused`（新） | requestId、reason{code, message} | requestId、**reason.code** | reason.message（同上） |
| `run.finishing` / `stop.accepted` | reason、inFlight、revision | inFlight、**reason（新增，按固定表翻译）** | revision |
| `run.quiescent` | revision | — | revision |
| `run.ended` | phase、outcome、reason | outcome、reason | phase（恒为 ended） |

回执里 `elapsedMs`、`dispatchSequence` 还只在 `methods.json` 的 `plannedFields.ActionReceipt`（`contracts/runtime/v1/methods.json:966-976`），目录里没有：耗时仍由 `timing.acceptedAt → completedAt` 计算，`elapsedMs` 落地后优先读它（已写好）；`dispatchSequence` 落地前不映射。目录**没有**按类型的敏感级别，所以第二节的分级和第四节的键名推断保留（见下方缺口）。

### 改了什么

1. **`ACPEventType` 只剩目录里的 11 个类型。** 删除暂定类型：`run.accepted`、`run.queued`、`run.waiting_approval`、`run.waiting_input`、`run.resumed`、`unit.started`、`unit.ended`、`action.verified`、`verification.succeeded`、`verification.failed`、`approval.required`、`question.asked`。目录规定 `run.` / `action.` / `stop.` 前缀只能是这 11 个，其他前缀保留；`unit.*` 由 A6 定义（`docs/ai-gui/a6-unit-run-draft.md` §3.2，未冻结，且其中没有 unit.started / unit.ended）。这些类型今后出现时只显示「收到未识别的运行事件（…），未作处理」。`emitted` 属性随之删除（目录内的全部已发）。
2. **错误码改读目录字段。** 原来读暂定的 `data.error.code` / `data.code` / `receipt.error.code`；现在读 `action.refused` 的 `data.reason.code` 和回执的 `receipt.reason.code`（F1-03）。码仍经 `ACPRedactor.errorCode` 收敛到 errors.json 目录（表外 → `unlisted_error`）；`message` 永不显示。unknown 回执的码（`action_delivery_unknown`）也显示。
3. **`action.refused` 成为已发类型。** 层级 refused(code)，缺省码由 `policy_rejected` 改为 `not_dispatched`（目录里 refused 就是「发送前拒绝，没有回执」），详情加「投递：未发出」。它关闭该动作，所以 `run.ended` 不会再补第二条终态。
4. **删除 G0 `details.reason` 的固定原因文案。** 目录的 reason 只有 `{code, message}`，没有 `details.reason`；`ACPEventText.targetReason` 删除。遮挡等原因现在只能以错误码（如 `stale_observation`）出现。
5. **`run.ended` 不再读目录外字段。** `kind`、`verification`、`unknownActions` 不在目录里（`additionalProperties: false`），已不读：kind 只取自同会话的 `run.started`；「N 个动作待核实」改为由会话上下文计数（unknown 结果 + 已发出无结果）；「任务完成：结果已验证」分支删除（目录里 Run 级没有验证结论）。
6. **closingReason 按 Runtime 实际写入的值翻译**（`ExecutionCoordinator.stop` 的调用方与 RunStore 重启恢复）：completed「动作已处理完」、finished「调用方已结束任务」、`exit <n>`「命令已退出（退出码 n）」、stopped「已请求停止」、owner_lost「编辑器连接已断开」、global_stop「已全部停止」、runtime_restarted「Runtime 已重启」，另保留 f1 E-8 表里的 failed / cancelled / grant_revoked / deadline_exceeded。表外值（自由文本）不显示。`stop.accepted` / `run.finishing` 也显示原因。
7. **回执 not_dispatched 一律标「未发出」。** 码 `execution_failed`、`permission_denied` 原来分别标「执行失败」「已拒绝」，但回执说没有送达，标「执行失败」会让人以为执行过（三级规则）。
8. **耗时**：`elapsedMs` 从事件 data 改为读回执（plannedFields 位置）；其余照旧由 timing 计算。
9. **不变**：三级结果（accepted ≠ executed ≠ verified；`verification` 目录里仍是 const `not_requested`，所以今天到不了「已验证」）、P1（窗口标题与身份信息不进 ACP 输出与日志）、P2（unknown 在 Run 结束后为终态，status failed、level unknown，不重试）逐字未改。对目录外字段（截图、元素标签、sensitive 标记等）的防御性处理保留：目录用 `additionalProperties: false` 禁止它们，但投影器仍按最严规则处理，以防 Runtime 越界。

夹具：新增 `catalogue-retired-types`（退役类型只出中性提示；run.ended 的 verification / unknownActions / kind 不被读取）、`emitted-accepted-without-result`（旧 g0 夹具改名：只有 accepted 没有结果，#102 后只在审计写入失败时出现）；`emitted-g0-refused` 改为 accepted → action.refused；`emitted-act-not-dispatched`、`emitted-act-unknown` 的回执带 reason；隐私夹具里的 `error{…}` 改成目录的 `reason{code, message}`；删除 `provisional-lifecycle`。测试新增：目录类型集合直接从 `runtime.schema.json` 读取并与 `ACPEventType.allCases` 比对；用合同夹具 `event-action-refused.valid.json`、`receipt-not-dispatched-with-reason.valid.json` 驱动投影器。

### 差异核查 (a)：`action.refused` 与 f1 审核 E-2

f1 的审核（本文 §〇 E-2）说「派发前拒绝也发 `action.failed`，回执 delivery=not_dispatched；不新增 `action.refused`」。#102 实际新增了 `action.refused`。按代码，两者的分界是**有没有回执**，即是否越过了 `ledger.markDispatching`：

| 写什么 | 何时（`Sources/AgentDesktopRuntime/RuntimeService+Act.swift`） | data |
| --- | --- | --- |
| `action.refused` | ① 快照不存在或不属于该桌面：`:55-60`，写完直接 `return .failure`；② `withDesktop` 闭包里在送达边界之前抛出的错误：绑定变化 / 进程重启 / G0 `exposedTarget` / 窗口移动 / `platformAction` 解析失败 / deadline / `beginAction` 的停止（`:64-90`），以及 `markDispatching` 或审计写入失败（`:93-100`）；统一在 `:175-181` 写，条件是错误 `details` 里**没有** `receipt` | requestId + reason{code, message} |
| `action.failed` | 已越过送达边界、生成了回执：`platform.perform` 抛出 `PlatformError` 且 `beforeDispatch == true`（`:127-131`），回执 delivery=not_dispatched、execution=failed，在 `:164` 以 `"action.\(execution)"` 写 | receipt（带 reason） |
| `action.unknown` | perform 后目标变化，或 PlatformError 不是 beforeDispatch（`:112-136`） | receipt（带 reason） |
| `action.completed` | 送达且无失败 | receipt（无 reason） |

结论：
- 同一次拒绝**不会**产生两条相互矛盾的终态事件。有回执的路径在 `:164` 写结果事件后把回执塞进错误的 `details`（`:166-168`），`:175` 的 `where e.details?["receipt"] == nil` 因此不成立，落到 `:182` 的 `case .failure: break`；快照失效路径在 `:60` 提前返回，不经过 `:175`。
- 边界情形：`:94-95` 先 `markDispatching`、再写 `action.dispatched`，`:96` 的 `checkWritable` 若此时失败，会抛 `audit_unavailable`（notSent），`:175` 尝试写 `action.refused`。但 `RunStore` 写失败后锁存为不可写（`Sources/AgentDesktopRuntime/Records/RunStore.swift:80-93`），这条 refused 写不进去；所以流里最多是「dispatched 之后没有结果」，投影器在 `run.ended` 按 P2 记为结果未知，不会出现 dispatched + refused 的矛盾对。
- 「未发出」在 ACP 侧有两种来源：`action.refused`（Runtime 自己的前置检查，无回执）和 `action.failed` + 回执 not_dispatched（平台在发送前失败，有回执）。两者都显示「未发出」+ 错误码，投影器不再区分。
- 与 E-2 的差异是**有意的形状变化**而非冲突：f1 原方案要求每次拒绝都有一张回执，#102 改为「无回执的拒绝用独立类型」。代价是 refused 没有 `receiptId`、`timing`，ACP 只能显示码，不能显示耗时和目标。

### 差异核查 (b)：事件目录在哪里、是否手工同步

- **只在 `runtime.schema.json`**：`$defs/PlatformRunEvent`（`contracts/runtime/v1/runtime.schema.json:2593-2964`），`$defs/FailureReason`（`:2575-2591`），`ActionReceipt.reason`（`:1671-1674`）。`methods.json` 里没有事件类型目录（全文只出现方法名 `run.events`、`events.subscribe` 等，`:216`、`:280`；`"schema": "runtime.schema.json"` 在 `:28`），只在 `plannedFields` 里记了回执的待加字段（`:953-976`）。这与 Kevin 的口径一致（runtime.schema.json 管事件结构，methods.json 管 RPC 方法），也意味着 f1 审核 E-5/E-6「F1-01 在 methods.json 的 `events` 段冻结」**没有**照做。
- **生成而非手工同步**：`Sources/AgentDesktopProtocol/RuntimeContractData.swift:1` 写明由 `scripts/generate-runtime-contract.sh` 生成，脚本把 contracts/runtime/v1 下四个 JSON 原样嵌成 Swift 字符串；`Tests/AgentDesktopClientTests/ProtocolContractTests.swift:19` 在两者不一致时失败。没有为事件生成 Swift 类型。
- **仍有两处手写副本或缺口**：
  1. `docs/architecture/runtime-api-v1-freeze.md:50-63` §4.1 用表格手写了一遍目录（类型与 data 字段），不是生成的，改 schema 时要人工同步。建议把它改成「见 schema」的链接，或由脚本生成。
  2. `RunEvent`（`runtime.schema.json:1986-2013`，`run.events` 的结果 `RunEvents` 引用它，`:2015-`）的 `type` 仍是任意 string、`data` 是任意 object，**没有** `$ref` 到 `PlatformRunEvent`；`EventFrame`（`:2457`）同理。也就是说目录只由 Runtime 侧测试 `Tests/AgentDesktopRuntimeTests/RuntimeEventCatalogTests.swift:45` 对 Runtime 自己写出的事件做校验，线上的 schema 不拒绝目录外的 `run.*` / `action.*` 类型。ACP 侧因此仍须按「目录外 → 中性提示」防御。
  3. ACP 侧不另存目录：`ETestProjectorTests.everyCatalogueTypeIsMapped` 直接读 `runtime.schema.json` 比对 `ACPEventType`，目录一变就失败。

### 仍待契约补的缺口（不改 contracts，只记录）

- 目录没有按类型的敏感级别（f1 E-7/E-10 曾接受「目录给每个 type 标一次级别」，#102 未带）：第二节分级与第四节键名推断继续保留。
- `run.ended` 没有 kind、unknownActions（E-4 未做）：会话从 `run.started` 之后的游标恢复时，act 与 unit 的成功文案无法区分，按 act 的保守文案显示；待核实计数只覆盖本会话见过的事件。
- `reason` 是自由 string（E-8 未收为枚举），而且 Runtime 实际写的 finished、`exit <n>`、stopped 不在 E-8 表里，E-8 表里的 failed、cancelled、grant_revoked、deadline_exceeded 今天不写。
- reason 带 `message`（E-3 曾说不带 message）：ACP 不读；但日志或其他消费者需注意它可能写到其他窗口。
- `action.refused` 不带 G0 的细分原因（window_gone / occluded 等），用户只能看到 `stale_observation`。
- `elapsedMs`、`dispatchSequence` 仍是 plannedFields；`verification` 仍是 const `not_requested`（E-1 未做），所以「已验证」今天不可达。

## 〇、f1 审核结论（2026-10-08）

| 编号 | 结论 |
| --- | --- |
| E-1 | 接受形状，分两步：PR2b 把 `ActionReceipt.verification` 放宽为 not_requested / pending / matched / contradicted / inconclusive，并登记 `action.verified`；产生它的实现随 A3 的动作后观察落地。只有 Runtime 验证器能写 |
| E-2 | 接受：派发前拒绝也发 `action.failed`，回执 delivery=not_dispatched；不新增 `action.refused` |
| E-3 | 接受：`action.failed`/`action.unknown` 的 data 带 `error {code, details.reason}`，不带 message |
| E-4 | 接受：`run.ended` data 带 kind、unknownActions、closingReason；unit 级验证结论属 F40-03（40，PR2d） |
| E-5、E-6 | 接受：F1-01 在 methods.json 的 `events` 段冻结，type 为 string 加 pattern |
| E-7、E-10 | 接受，规则更硬：事件 data 只允许 id、枚举、数字、时间戳，任何文本只能以 artifact 引用出现；目录给每个 type 标一次级别 normal / sensitive / protected。ACP 届时按契约分级，不再按键名推断 |
| E-8 | 接受：closingReason 取值冻结为 completed / failed / cancelled / global_stop / owner_lost / runtime_restarted / grant_revoked / deadline_exceeded，表外值不显示 |
| E-9 | 接受：ImageArtifact 加可选 `scope`（window / screen）、`windowId`、`bindingGeneration` |

PR2b 合入后，工作线 E 改为读目录里的级别与字段，删除按键名推断的部分。

**#102 后的实际情况**（详见上一节「第三轮」）：E-2 改为新增 `action.refused`；E-3 改为 `reason{code, message}`（带 message）；E-4、E-7/E-10、E-8 未做；E-5/E-6 的目录放在 runtime.schema.json 而不是 methods.json；E-1、E-9 尚未落地。因此按键名推断的部分**保留**。

## 一、原则

1. **唯一出口。** Runtime 事件只经 `ACPProjector`（实现冻结接口 `ACPEventProjector`）变成 `ACPSessionUpdate`。投影是纯函数：同一事件、同一策略、同一上下文，输出逐字相同。
2. **三级结果不混淆**（方案 5.2、docs/plan/06 §6.4）：已受理 ≠ 已执行 ≠ 已验证。只有 Runtime 报告验证「matched」时才显示「已验证成功」；`verification = not_requested`、`businessResult = not_evaluated` 一律停在「已执行，未验证」。
3. **unknown 不显示成功也不记为失败**：Run 进行中显示「结果待核实」（in_progress）；Run 结束后成为终态「结果未知 · 需要核实」（ACP v1 线上 status failed，内部 level 始终 unknown），从不重试，只能在主窗口核实。
4. **默认最严。** 默认只显示动作类别、状态、耗时、脱敏目标标识、目录内错误码、验证状态。截图、页面文字、输入内容、原始参数默认都不出现；窗口标题与身份信息在任何策略下都不出现（P1）。
5. **永不崩溃。** 未识别的事件类型变成一条中性 thought；字段缺失或类型不对时按最保守的语义投影。
6. **事件来源**：`ACPRuntimeEvent.payload` 可以是 RunEvent 的 `data`，也可以是整个 RunEvent（`{runId, sequence, at, type, data}`）；两种形状投影结果相同（夹具 `emitted-full-frame-payload`）。建议线 R 传整个 RunEvent，以便拿到 `at` 计算 Run 用时。

## 二、三级分级（Kevin 裁决）

| 级别 | 含义 | 事件 | 字段类 |
| --- | --- | --- | --- |
| 普通 normal | 可完整展示 | Run 生命周期：run.started / finishing / quiescent / ended、stop.accepted | code、identifier、scalar |
| 敏感 sensitive | 脱敏后展示；内容类字段只在策略放宽时出现 | 动作：action.accepted / dispatched / completed / failed / unknown / refused | freeText（显示端不再输出，日志隐藏）、pageText、url |
| 受保护 protected | 只显示状态，任何策略下都不暴露内容 | 目录外的任何类型（含 #102 前的暂定类型 approval.required、run.waiting_approval、question.asked 等，以及未冻结的 unit.*）：一条中性提示；以及 data 带 `sensitive / withheld / redacted` 或敏感 `dataClassification` 的动作事件 | windowTitle、identity（P1）、typedValue（含审批与动作参数 params / arguments）、credential、screenshot（字节）、withheld（含 covering* / other* / foreign* / sibling* 等描述其他窗口的字段） |

实现：`ACPEventTier`、`ACPEventType.tier`、`ACPEventType.tier(of:)`（目录外 → protected）、`ACPDataClass.tier`。#102 的目录没有按类型的级别，这一列是 ACP 自定的。受保护事件一律按最严策略投影并只保留状态行；被标记 withheld 的动作事件只剩「状态：…」一行。

### 2.1 跨应用数据（四类重点）

| 数据 | 风险 | 规则 | 测试 |
| --- | --- | --- | --- |
| 截图 | 屏幕或桌面截图可含其他应用 | 字节、base64、路径永不输出；只在 `screenshots` 放宽时输出 artifact 引用，且仅当图像对象的 `windowId` 等于本动作绑定目标的 `windowId`；没有 windowId（整屏）或不一致一律不出 | `crossAppScreenshots`、夹具 `privacy-cross-app` |
| 窗口标题 | G0 拒绝的 reason.message 会描述遮挡窗口；标题常含人名 | P1 后任何窗口（含绑定目标）的标题都不显示；元素标签只取绑定目标，两处 windowId 不一致时不读；covering* 等字段归 withheld；`reason.message` 永不读取（只显示目录内错误码） | `crossAppWindowTitles`、`p1WindowTitleNameNeverLeaves` |
| 输入内容 | 粘贴或输入的文本可来自其他应用 | text / input / clipboard / paste / keys 归 typedValue，任何策略都不显示 | `crossAppTypedInput` |
| 审批参数 | 摘要、参数可引用其他应用内容 | 审批与提问不在 Run 事件目录里（真正的请求由线 S 发起）；这类事件若出现只得到一条中性提示，不读 payload；params / arguments 归 typedValue | `crossAppApprovalParameters` |

## 三、映射表

「来源」一列：**目录**＝#102 冻结的 `PlatformRunEvent`，Runtime 今天都会写。#102 前的暂定类型已删除，见上文「第三轮」。

### 3.1 Run 生命周期

| Runtime 事件 | 来源 | 读取字段 | ACP 更新 | 用户看到 |
| --- | --- | --- | --- | --- |
| `run.started` | 目录 | `kind`（记入上下文）、`lifetime` | agentMessage + plan | 任务已开始（Run run_xxx）；`connection_scoped` 时加「编辑器断开后将停止输入」 |
| `stop.accepted` | 目录 | `inFlight`、`reason` | agentMessage + plan | 正在停止；有进行中的动作时加「（等待进行中的动作收尾）」；原因按 3.3 的表 |
| `run.finishing` | 目录 | `inFlight`、`reason` | agentMessage + plan | 正在收尾；同上 |
| `run.quiescent` | 目录 | — | agentMessage + plan | 已停止输入 |
| `run.ended` | 目录 | `outcome`、`reason` | 先补齐未结动作的 toolCallUpdate，再 agentMessage + plan | 见 3.3 |

plan 固定四项：受理任务 / 执行 / 停止输入并收尾 / 结果。状态随阶段推进；结果项在 unknown 时为 completed「结果：未知 · 需要核实」（P2 终态；内容写明未知，不表示成功）。

### 3.2 动作

toolCallId = `act:<runId>:<requestId>`，两段都经 `ACPRedactor.identifier`（调用方自选的 requestId 一律哈希）。标题 =「类别 — 状态」，如「点击 — 已执行，未验证」。

| Runtime 事件 | 来源 | 层级 `ACPActionLevel` | ACP 状态 | 标题后缀 |
| --- | --- | --- | --- | --- |
| `action.accepted` | 目录 | accepted | pending | 已受理（发 `toolCall`） |
| `action.dispatched` | 目录 | dispatched | in_progress | 已发出，等待执行结果 |
| `action.completed`，回执 dispatched + completed | 目录 | executed | completed | 已执行，未验证 |
| 回执 verification ∈ {matched, verified, passed, confirmed, succeeded} | 目录字段，但今天是 const `not_requested`（E-1） | verified | completed | 已验证成功 |
| 回执 verification ∈ {contradicted, mismatched, not_matched, failed, rejected} | 同上 | contradicted | failed | 验证未通过 |
| `action.failed`，回执 not_dispatched | 目录 | refused(`receipt.reason.code`) | failed | 未发出 |
| `action.failed`，回执 dispatched + failed | 目录 | failed(`receipt.reason.code`，缺省 execution_failed) | failed | 执行失败 |
| `action.unknown`，或任何回执 delivery / execution 为 unknown（Run 进行中） | 目录 | unknown | in_progress | 结果待核实（详情带 `receipt.reason.code`） |
| 上一行的动作，在同一 Run 的 `run.ended` 时（P2） | — | unknown | failed（终态） | 结果未知 · 需要核实 |
| `action.refused` | 目录（#102 新增） | refused(`data.reason.code`，缺省 not_dispatched) | failed | 未发出（码不在「未发出」词表时为「已拒绝」） |
| （无结果事件）`run.ended` 时仍只到 accepted | #102 后只在审计写入失败时出现 | refused(not_dispatched)；Run outcome 为 unknown 时为 unknown | failed | 未发出 |
| （无结果事件）`run.ended` 时已 dispatched，或 Run outcome 不是 success / failed / cancelled | 重启恢复、审计失败 | unknown | failed（终态） | 结果未知 · 需要核实 |

规则：

- **回执优先于事件名。** 回执是 Runtime 的记录；`action.completed` 携带 `execution = failed` 的回执按失败显示，携带 `delivery = unknown` 的按待核实显示，未识别的轴组合一律待核实。
- **verified 需要投递与执行都成立**：回执 delivery 为 unknown 时即使写了 matched 也只显示待核实。
- **发送前拒绝**（G0 窗口身份、快照失效、停止、deadline）写 `action.refused{requestId, reason}`，没有回执。投影器显示「未发出」、「投递：未发出」与错误码；`reason.message` 从不读取（它可能写出遮挡窗口的标题）。它关闭该动作，`run.ended` 不再补终态。
- 详情行（默认）：状态、投递 / 执行 / 验证三轴（有回执时；refused 只有「投递：未发出」）、业务结果（回执有字段时）、耗时（回执 `elapsedMs`，否则 `timing.acceptedAt → completedAt`）、目标（`ref-xxxxxxxx`，windowId + elementRef 的字母哈希）、错误码（目录内，否则 `unlisted_error`）、回执号（哈希）、待核实提示。坐标、pid、windowId 原值不显示。

### 3.3 Run 结束文案

| outcome | Run kind（取自同会话的 `run.started`） | 文案 |
| --- | --- | --- |
| success | act 或未知 | 任务结束：已投递（业务结果：未评估）（docs/plan/06 §6.4：act 的 success 只表示投递） |
| success | unit / exec | 任务结束：已执行（业务结果：未评估） |
| failed | — | 任务结束：失败 |
| cancelled | — | 任务结束：已取消 |
| unknown、空、其他 | — | 任务结束：结果未知 · 需要核实（不会重试；请在 AgentDesktop 主窗口核实结果后再决定下一步） |

追加：本会话里该 Run 有 unknown 结果或已发出无结果的动作时「N 个动作待核实」（由上下文计数；`run.ended` 目录里没有这个数）；`reason` 按固定表翻译：completed「动作已处理完」、finished「调用方已结束任务」、`exit <n>`「命令已退出（退出码 n）」、stopped / cancelled「已请求停止」、failed「任务失败」、owner_lost「编辑器连接已断开」、global_stop「已全部停止」、runtime_restarted「Runtime 已重启」、grant_revoked「授权已撤销」、deadline_exceeded「超过时限」，表外原因不显示；见过 `run.started` 时追加「用时 N 秒」。

### 3.4 未识别事件

`agentThought("收到未识别的运行事件（<type>），未作处理")`。type 只有符合 `段.段` 小写形状时才回显，否则写「未知类型」（夹具 `unknown-types`：类型名里塞邮箱也不回显）。

### 3.5 ToolKind

| 动作 kind | ToolKind |
| --- | --- |
| observe、snapshot、read、wait | read |
| click、type、key、scroll、drag、launch、act | execute |
| submit、send*、publish、post、external_submit、outbound、upload、pay、*_submit | other（外部提交类，不当本地命令） |
| 其他 / 缺失 | other |

### 3.6 不由投影器产生的更新

- `sessionInfo`（会话标题）归线 S（`ACPSessionBinding.title`）；投影器不改会话标题，避免把 Run 信息写进标题。
- `turnEnded` / `promptFinished` 由线 S 按版本决定；投影器只描述 Run。
- 审批请求（`session/request_permission`）与提问（`elicitation/create`）由线 S 根据 `ACPRuntimePort.pending` 发起；Run 事件目录里没有对应类型，投影器不显示「等待批准 / 等待回答」。线 S 构造审批摘要时须调用 `ACPRedactor.redact`。

## 四、数据分类与脱敏

### 4.1 字段分类（`ACPDataClassifier.classify(key:)`）

| 类 | 例子（键名，大小写与分隔符不计） | 默认 | pageText 打开 | screenshots 打开 |
| --- | --- | --- | --- | --- |
| code | kind、phase、outcome、delivery、execution、verification、businessResult、code、reason | 只显示固定词表的中文 | 同左 | 同左 |
| identifier | *Id、*Ref | 运行时形状 id 原样，其余哈希 | 同左 | 同左 |
| scalar | sequence、revision、windowId、x、y、pid、时间戳 | 只用于计算（耗时、目标哈希），不显示原值 | 同左 | 同左 |
| freeText | message、summary、description、goal，及所有未列出的键 | 不显示；日志与存储中为 `[已隐藏]` | 仍不显示（可能引用窗口标题或人名，P1） | — |
| windowTitle | title、windowTitle、documentTitle、tabTitle | **永不显示**，日志 `[已隐藏]`（P1） | **永不显示** | — |
| identity | name、displayName、userName、fullName、nickname、appName、processName、account、contact、sender、recipient、from、to、cc、owner、candidate、person、author | **永不显示**，日志 `[已隐藏]`（P1） | **永不显示** | — |
| pageText | label、value、elements、matches、content、ocr | 不显示 | 仅绑定目标的元素标签，脱敏后显示；elements / matches 列表不显示 | — |
| typedValue | text、input、typed、clipboard、paste、keys、params、arguments、args | **永不显示** | **永不显示** | **永不显示** |
| url | url、href、link、uri | 不显示 | 不显示（文本内链接一律 `[链接]`） | — |
| screenshot | image、screenshot、png、base64、bytes | 不显示 | 不显示 | 只显示 artifact 引用（「截图：art_xxx（在 AgentDesktop 主窗口查看）」），从不含字节，且图像 windowId 须等于绑定目标；`submit` 只对提交类动作显示 |
| credential | password、token、attachToken、secret、apiKey、cookie、authorization、*token | **永不显示** | **永不显示** | **永不显示** |
| withheld | 对象带 `sensitive: true`、`withheld: true`、`redacted: true` 或敏感 `dataClassification`；covering* / other* / foreign* / sibling* 字段 | **永不显示** | **永不显示** | **永不显示** |

Runtime 因缺少屏幕录制授权而给出 `title: null`（`contracts/fixtures/runtime/v1/window-title-withheld.valid.json`）时，放宽策略下也不出标题行（夹具 `privacy-window-title-withheld`）。

### 4.2 文本脱敏（`ACPRedactor.redact`）

对每一个离开投影器的自由文本（元素标签；以及其他线经 `redact` 显示的文本）执行；窗口标题与身份信息不靠正则，而是按字段整体不输出（P1）；**与策略无关**：放宽只决定哪些字段出现，不放松字段内容的遮盖。

| 顺序 | 识别 | 替换为 |
| --- | --- | --- |
| 0 | 全角数字、字母、＠＋－．转半角；换行、控制字符、格式字符变空格；超过 160 字截断加「…」 | — |
| 1 | `Bearer/Basic/token <值>`、`password= / 密码： / 验证码：` 等键值、JWT、sk-/ghp_/xox*/AKIA 等前缀密钥、32 位以上十六进制、40 位以上混合 base64 | `[凭据]` |
| 2 | http(s)/ftp/file/ws/smb/afp 链接、`www.` 开头 | `[链接]` |
| 3 | 邮箱（含 mailto:、裸主机名） | `[邮箱]` |
| 4 | 18 位居民身份证号（含出生日期校验形状、末位 X） | `[证件号]` |
| 5 | 中国大陆手机（可带 +86、空格、短横）、带 + 的国际号码、(555) 123-4567 形式、0xx-xxxxxxxx 座机 | `[电话]` |
| 6 | 4 位一组的卡号、7 位以上连续数字（银行卡、15 位旧身份证、QQ、账号） | `[数字]` |

投影器在输出前还对每个字符串再过一遍凭据、链接、邮箱规则（`guardOutput`，纵深防御）。

### 4.3 给其他工作线的接口

| 函数 | 用途 |
| --- | --- |
| `ACPRedactor.redact(_:)` / `ACPEventProjector.redact(_:policy:)` | 任何自由文本（审批摘要、提问、错误）在显示或记录前 |
| `ACPRedactor.redactJSON(_:policy:)` | 把整个 payload 按字段分类脱敏后写日志或存储 |
| `ACPRedactor.logLine(_ event:)` | 一行安全的事件日志 |
| `ACPRedactor.logSafe(_ error:)` | 错误描述写日志、崩溃报告前 |
| `ACPRedactor.identifier(_:)`、`errorCode(_:)` | 显示 id；把任意错误码收敛到 runtime/1 目录（目录外 → `unlisted_error`） |
| `ACPProjectorSession` | 每个 ACP 会话一个，按游标顺序喂事件；它记住动作类别、Run kind、开始时间和未结动作 |

## 五、测试

| 组 | 文件 | 内容 |
| --- | --- | --- |
| golden | `Events/ETestGoldenTests.swift` + `Fixtures/events/*.json`（16 份） | 每份夹具：合成输入事件、策略、逐事件的期望更新、`mustNotContain`（植入的个人信息）与 `mustContain`；所有输出另过一遍泄露正则。`ETEST_REGEN=1 swift test --filter ETestGoldenTests` 重写期望，提交前人工核对 |
| 三级结果 | `Events/ETestProjectorTests.swift` | accepted ≠ dispatched ≠ executed ≠ verified；只有 matched 才 verified；回执轴优先；unknown 不完成也不失败 |
| T19 | 同上 + 夹具 `privacy-t19-*` | 默认不出截图；`all` 只出引用不出字节；`submit` 只对提交类 |
| T20 | 同上 + `privacy-t19-t21-*` | 默认不出窗口标题、元素标签、摘要；放宽后只出脱敏的元素标签，窗口标题与摘要仍不出（P1） |
| T21 | 同上 | `Click send to candidate: example@email.com` 在任何策略下输出都不含邮箱；输入内容永不出现；坐标、pid、windowId 不出现 |
| 脱敏 | `Privacy/ETestRedactorTests.swift` | 28 条样例、单行与截断、策略不放松遮盖、id 哈希、错误码目录覆盖 errors.json 全部 40 个码、字段分类、`redactJSON`、`logLine` |
| 健壮 | 同上 | 每个目录类型 × 多种畸形 payload 不崩溃；未识别类型只产生 thought |
| #102 目录 | `everyCatalogueTypeIsMapped`、`provisionalTypesAreGone`、`actionRefusedFromTheContractFixture`、`receiptReasonCodeOnFailedAndUnknown`、`refusalIsTheOnlyTerminalUpdate`、`closingReasonsTheRuntimeWrites`、`freeTextClosingReasonIsNotShown`、`unknownCountComesFromTheSession`，夹具 `catalogue-retired-types`、`emitted-g0-refused`、`emitted-accepted-without-result` | 类型集合与 runtime.schema.json 一致；退役类型只出中性提示；合同夹具驱动；refused 只有一条终态；message 不出现 |
| P1 | `p1WindowTitleNameNeverLeaves`、夹具 `privacy-t19-t21-widened` | 放宽策略 + 绑定窗口标题含人名：人名与标题不出现在任何更新、`logLine`、`redactJSON` 中；元素标签照常 |
| P2 | `p2*` 五个测试、夹具 `emitted-act-unknown`、`emitted-restart`、`unknown-types` | 进行中 in_progress；run.ended 后 failed + level unknown + 固定标题；已拒绝或已执行的动作不被重开；其他 Run 不受影响 |
| 三级与跨应用 | `Events/ETestProjectorTests.swift` + 夹具 `privacy-cross-app` | 每种事件与字段类有级别；截图、窗口标题、输入内容、审批参数四类各一条测试；带 sensitive 标记的动作只剩状态 |

## 六、需要 f1 补的契约（schema 缺口）

第二轮提出时的原文，保留作记录；#102 之后的状态见上文「第三轮 · 仍待契约补的缺口」：E-2、E-5、E-6 已由 #102 以不同形状解决（`action.refused`；目录在 runtime.schema.json），E-3 部分解决（reason 带 message），其余未做。

| 编号 | 缺口 | 现状与影响 | 建议 |
| --- | --- | --- | --- |
| E-1 | 回执没有验证结果 | `ActionReceipt.verification` 是 const `not_requested`，所以今天任何动作都到不了「已验证」 | 定义 verification 枚举（建议 `not_requested / pending / matched / contradicted / inconclusive`）与产生它的事件（`action.verified` 或 unit 的验证事件），并说明谁有资格写 |
| E-2 | 派发前拒绝不产生结果事件 | G0 窗口身份拒绝、stale_observation、deadline 在 `action.accepted` 之后抛错，事件流里没有 `action.failed`；投影器只能在 `run.ended` 时推断「未发出」，且拿不到错误码与 `details.reason` | 派发前拒绝也发 `action.failed`（回执 `delivery = not_dispatched`）或新事件 `action.refused`，data 带 `error.code` 与 `details.reason` |
| E-3 | 结果事件不带错误码 | `action.failed` / `action.unknown` 的 data 只有回执；错误码只在 RPC 响应里，订阅事件的观察者（ACP 会话恢复后）看不到 | 结果事件 data 增加 `error: {code, details.reason}`（不含 message） |
| E-4 | `run.ended` 不带 kind、unknownActions、verification | 投影器需要 `run.started` 的上下文才能区分 act 的「已投递」；会话恢复时游标在 `run.started` 之后就只能按 act 的保守文案显示 | `run.ended` data 增加 `kind`、`unknownActions`；unit Run 增加单元验证结论 |
| E-5 | 排队、单元、审批、提问、策略拒绝事件不存在 | C-10；映射已按暂定名实现 | F1-01 冻结时给出正式名称与 data 字段；本文与夹具随之对齐 |
| E-6 | RunEvent.type 是自由字符串 | GAP-08；没有目录就无法在 schema 层拒绝未知类型 | F1-01 把 type 收为枚举（允许扩展前缀） |
| E-7 | 事件 data 没有敏感标记 | 今天靠键名分类；未来若在 data 里放标题、标签、摘要，需要显式 `sensitive` / `dataClassification` | 约定事件 data 中可能含个人信息的字段一律带分类标记，或只放引用（artifact id） |
| E-9 | 截图没有采集范围 | `ImageArtifact` 没有 windowId 或 scope（window / screen），投影器无法证明一张图只含绑定窗口，所以今天即使 `screenshots = all` 也不会显示任何截图引用 | `ImageArtifact` 增加 `scope` 与 `windowId`（及 binding generation） |
| E-10 | 事件没有分级字段 | 三级分级今天由 ACP 按事件类型与键名推断 | F1-01 给每个事件类型标注级别，data 字段标注分类，ACP 以契约为准 |
| E-8 | `run.ended.reason` 是自由字符串 | 已见 completed、finished、exit*、stopped、global_stop、owner_lost、runtime_restarted | 收为枚举；投影器对表外值不显示 |

## 七、需要协调者决定或调整的接口

1. ~~`ACPActionLevel` 增加 `.failed(code:)`~~：已由协调者加入并采用。
2. `ACPEventProjector.project` 无状态，动作的后续事件拿不到类别、Run 结束拿不到 Run kind。已提供 `ACPProjectorSession`（值类型，内含 `ACPEventContext`）作为补充，不改协议；线 S 应每会话持有一个。若希望协议本身带上下文，可把 `project(_:policy:context:)` 提到协议里。
3. `ACPToolCall` 的 `title` / `kind` 在更新里是必填：无上下文时后续更新只能写「界面动作」，可能覆盖编辑器已显示的类别。建议线 T 在 toolCallUpdate 里只发变化的字段，或把这两个字段改为可选。
4. 夹具 JSON 位于测试 target 内，SwiftPM 报「found 14 file(s) which are unhandled」警告（线 T 的 Fixtures/acp-schema 同样）。建议协调者在 `Package.swift` 的 `AgentDesktopACPTests` 加 `exclude: ["Fixtures"]`。
5. ~~unknown 动作的终态~~：按第二次裁决 P2 实现（Run 结束后 status failed、level unknown，线 T 加 rawOutput）。

## 八、待 Kevin 确认

- 放宽 `pageText` 后，页面文字里的邮箱、电话仍被遮盖（策略只扩大字段范围，不放松遮盖）。这让「看页面文字」对招聘类场景用处有限，但符合「默认最严、凭据永不外发」。若需要「看到原文」，应是单独的、带审计的开关，而不是 pageText。
- ~~窗口标题里的人名~~：第二次裁决 P1 已决定，窗口标题与身份信息不进入 ACP。仍存在的边界：页面正文（元素标签）在 `pageText` 放宽后显示，其中的人名无法可靠识别。
