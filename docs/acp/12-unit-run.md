# ACP × A6 `unit.run`：差距、测试要求与验收（辅助工作包）

状态：2026-10-08，基于 `main`@cbe7772（含 #102 冻结的 A6 契约增量）。作者：ACP 辅助工作包（2ndscreen 会话 997716a3）。

**范围与边界**：Kevin 批准 ACP 为 A6 准备适配器测试与端到端夹具，**不批准** ACP 实现 `unit.run` 或任何第二个执行入口。本文和 `Tests/AgentDesktopACPTests/Pending/UnitRun/` 只做三件事：对照冻结契约列出 ACP 侧的差距；写出 Mock 测试（今天可跑）和真 Runtime 测试（已写、禁用）；给工作线 Q 留下可复用的场景夹具。**Mock 测试全部通过不代表 A6 完成，也不是端到端验收**（README §五附加约束 6）。

权威顺序沿用 A6 草案：ADR v2.2 > `docs/architecture/runtime-api-v1-freeze.md` > `docs/plan/` > `docs/ai-gui/a6-unit-run-draft.md` > 本文。

## 一、现状一句话

契约已冻结（`methods.json` 第 676–682 行 `unit.run` 为 `frozen`，`runtime.schema.json` 第 2308 行 `unit_run_params`、第 2975 行 `RunUnit`、第 1913 行 `Run.unit`），处理函数没有（`Sources/AgentDesktopProtocol/RuntimeAPI.swift` 第 22–55 行的 `RuntimeMethod` 里没有 `unit.run`），Runtime 也不在 `runtime.capabilities` 里宣告它。ACP 的 Runtime 桥已经按「宣告即出现任务」写好，所以 A6 合入后 ACP 能**提交** `unit.run`；但 Zed 的 prompt 今天走不到提交那一步（见 UR-G1），这是 ACP 自己的差距，与 A6 无关。

## 二、差距表

「负责」一栏：40 = A6 实现方（L-AIGUI），f1 = Runtime 契约负责人，R / S / E = ACP 工作线。每一行在 `Pending/UnitRun` 里有对应的测试；ACP 侧的差距用 `withKnownIssue` 固定，修好后测试会提示去掉包装。

| 编号 | 现状（证据） | ACP 需要 | 负责 | 测试 |
| --- | --- | --- | --- | --- |
| UR-A1 | `unit.run` 无处理函数；`RuntimeMethod`（`RuntimeAPI.swift:22-55`）不含它；`runtime.capabilities` 不列出 | 按冻结形状实现并宣告；ACP 的 `ACPTaskCatalog` 见到即生成任务（`ACPTaskCatalog.swift:58-73`），R 不需改代码 | 40 | `realRuntimeAdvertisesUnitRunAndACPOffersTheTask`（Real，禁用）；`noUnitRunNoTask`、`withoutUnitRunNothingIsSent`（Mock） |
| UR-A2 | 越权字段的错误码说法不一：冻结契约 `methods.json:682`、冻结文档 `runtime-api-v1-freeze.md:76`、`a6-unit-run-draft.md:125`、`docs/plan/02:137` 都写 `ownership_escalation_denied`，且 Schema 放行这三个字段（`runtime.schema.json:2394-2399`「accepted only to refuse escalation explicitly」，夹具 `unit-run-escalation-fields-reach-the-handler.valid.json`）；而 07 §〇 R1（第 13 行）记 f1 说「schema 层以 `schema_invalid` 拒绝」 | 定一个码。ACP 本地拒绝用契约里的 `ownership_escalation_denied`（`ACPTaskCatalog.swift:82-84`），从不发出，所以 ACP 不受影响；但真 Runtime 测试与 CLI/MCP 需要同一个答案 | f1、40 | `escalationFieldsAreAHandlerRefusalNotASchemaOne`、`escalationIsRefusedLocallyWithTheContractCode`、`escalationNeverReachesTheRuntime`（Mock）；`realRuntimeRefusesEscalationAndCreatesNoRun`（Real，禁用，暂时两个码都接受） |
| UR-A3 | `unit.*` 事件不在冻结目录里：`PlatformRunEvent` 的说明（`runtime.schema.json:2594`）写「unit. 前缀由 Explorer 文档约定」；A6 草案 3.2 的八类事件只是提议 | 冻结 `unit.*` 的 type 与 data 必填字段、敏感分级；尤其 `unit.verification`、`unit.progress` | 40（f1 审） | `scenarioEventsUseTheFrozenCatalogue`（夹具里 `unit.*` 标 `frozen: false`）；`unitEventsLeakNothing` |
| UR-A4 | 前置检查失败的落账：A6 草案 3.4 说「不建 Run」，07 §〇 R1 补充「请求账本记一条 state=failed」；契约里 `RequestRecord.state` 有 `failed`（`runtime.schema.json:1260` 起），但没有写进 `unit.run` 的说明 | Runtime 保证：拒绝 → 无 Run、账本 failed、同 requestId 重放原错误。ACP 的重试只读账本（`ACPBridgeRuntimePort.swift:171-197`） | 40 | `precheckRefusalsCreateNoRunAndAreNotResent`（Mock，14 行）；`realPrecheckRefusalWritesAFailedRecord`（Real，禁用） |
| UR-G1 | **prompt 无法指定 Desktop**：服务端提交时 `desktopId: nil`（`ACPAgentServer+Prompt.swift:144`）；会话配置只有 mode / screenshots / pageText（`ACPSessionManagerOptions.swift:14-25`）；编辑器侧 schema 去掉了 `desktopId` 且 `additionalProperties: false`（`ACPTaskCatalog.swift:122-138`），所以输入里写也被拒绝（「不接受字段 desktopId」）；桥最后以 `invalid_argument`「no Desktop chosen」拒绝（`ACPTaskCatalog.swift:93-95`）。结论：A6 合入后 Zed 里的任何 prompt 仍不会发出 `unit.run` | 会话级的 Desktop 选择（S 加配置项，值来自 Runtime 的 `desktop.list`，不是编辑器自报），或由协调者定其他来源。属于冻结接口（`ACPSubmission.desktopId` 已有，只是 S 没填）| S（协调者定方案） | `allowedPromptShouldReachUnitRun`（Mock，全栈，known issue） |
| UR-G2 | 编辑器侧 schema 仍列出 `origin`、`lifetime`、`ownership`（`editorSchema()` 只去掉桥自己填的字段，`ACPTaskCatalog.swift:127-128`），命令提示里出现 `"lifetime": …` | 从编辑器 schema 去掉 `forbiddenInputKeys`；拒绝逻辑不变 | R | `editorSchemaShouldNotAdvertiseForbiddenFields`（Mock，known issue） |
| UR-G3 | 任务宣告 `allowFreeText: true`（`ACPTaskCatalog.swift:114`），但一句话填不出 `unit_run_params` 的必填项，得到「需要 JSON 参数」（`ACPCommandCatalog.swift:129`）。f1 不接受 R6 任务目录，自由文本映射归 40 的 F40 增量（07 §〇 R6） | 40 定自由文本 → `goal.description` 与其余必填项（`verification`、`allowedActions`、`mode`）的固定取值；之前 R 应宣告 `allowFreeText: false`，免得误导 | 40；R | `freeTextCannotStartAUnitRunYet`（Mock，known issue） |
| UR-G4 | 前置检查的 `details.reason`（`gui_execution_off`、`desktop_not_found`…，A6 草案 3.4 固定取值）到不了编辑器：`ACPSubmissionReceipt.refused` 只有 code 与 message（`Ports.swift:124`）。07 R1 补充请求 1 要求「原样展示为拒绝原因」 | 冻结接口加 `reason`（协调者改 Ports），S 展示 | 协调者、R、S | `precheckReasonShouldReachTheEditor`（Mock，known issue） |
| UR-G5 | 桥不核对返回的 Run 轴：任何能解析的 Run 都当作本连接的 Delegated Run（`ACPBridgeRuntimePort.swift:152-156`） | 线协议上的 `unit.run` 必须得到 `external_client / connection_scoped / agent_hub`（ADR v2.2，`methods.json:682`）；不符即按契约违例处理（显示为错误、不跟随、记录），不当作成功 | R | `aDurableRunFromTheWireShouldBeRejected`（Mock，known issue） |
| UR-G6 | 桥在本地拒绝（`invalid_argument`、`schema_invalid`、`ownership_escalation_denied`）也显示成「Runtime 拒绝了这个任务」（`ACPAgentServer+Prompt.swift:180`） | 区分「本地未发出」与「Runtime 拒绝」，避免用户以为请求到过 Runtime | S、R | `allowedPromptShouldReachUnitRun` 的文本断言（记录现状） |
| UR-E1 | `unit.*` 事件今天投影为一行中性思考「收到未识别的运行事件（unit.xxx），未作处理」（`ACPProjector.swift:44`）；一次 Run 会有很多条 | 目录冻结后为 `unit.progress`（计划条目）、`unit.verification`（见 Q4）定映射，其余仍只显示状态 | E（等 UR-A3） | `unitEventsLeakNothing` |
| UR-E2 | unit Run 成功时显示「任务结束：已执行（业务结果：未评估）」（`ACPProjector.swift:239-241`），`verifiedValues` 为空（`ACPProjector.swift:19`）；不读 `Run.unit.verification.status` | 按 Q4 的答复决定是否、以及从哪里显示「已验证」。在答复前保持现状（README §九：验证结果落地前不得显示「已验证」） | E（等 Q4） | `normalCompletionIsExecutedNotVerified`（Mock，断言不出现「已验证」） |
| UR-E3 | `run.ended.reason` 是自由字符串，只显示已知值（`ACPEventText.swift:126-145`）；A6 草案说失败原因写在 `closingReason`（如验证未达成、步数用尽），这些值目前不会显示 | 固定 unit 的结束原因枚举（README §九已列为 P1「结束原因固定枚举」） | f1、40 | `timeLimitEndsFailedWithItsReason`（只覆盖已知的 `deadline_exceeded`） |

不是差距、已对齐的部分（Mock 已证明）：提交前写前日志、结果不明只查不重发（`.unconfirmed` → `request.show`）、同一提交键重放原 Run、取消走 `run.cancel` 并等静止、断连只关控制连接不重连、审批通道缺失按拒绝、P2 终态（v1 线上 `failed` + `rawOutput {execution: terminated, outcome: unknown}`，`ACPWireV1.swift:348-357`）。

## 三、测试要求

### 三.1 参数与契约校验

1. 编辑器输入加上会话 Desktop 后必须通过冻结的 `unit_run_params`；ACP 在发出前用同一份契约校验，不合格在本地拒绝、不发出（`schema_invalid` / `invalid_argument`）。
2. 冻结夹具的含义不得被 ACP 的假设改变：`unit-run-explore` 合法、空 `verification.all` 非法、`guiProfileId` 不带修订号非法、`clientId` 非法、越权三字段在 Schema 层合法（留给处理函数拒绝）。
3. Runtime 宣告 `ai.profiles.list` 时，每个启用的 GUI 配置是一个任务，提交时固定 `guiProfileId` + `expectedProfileRevision`；输入里不能自带这两个字段。
4. 没有 `unit.run` 宣告时，任务列表为空，提交返回 `capability_missing`，什么都不发。

### 三.2 正常完成、取消、超时、结果不明

| 情况 | 必须成立 |
| --- | --- |
| 正常完成 | Run 为 `unit / agent_hub / external_client / connection_scoped`；动作依次 accepted → dispatched → executed；Run `success` 后编辑器看到「已执行，未验证」「业务结果：未评估」，不出现「已验证」 |
| 取消 | 只发 `run.cancel`（调用方 requestId，重复即同一取消）；看到「正在停止」，静止后「已取消」；不发第二个 `unit.run` |
| 调用超时 / 回复丢失 | 提交为「待核实」，不重发；同一提交键再次提交只读 `request.show`，映射到原 Run；`unit.run` 恰好一次 |
| Run 时限用尽 | `outcome: failed`、`closingReason: deadline_exceeded`，显示「失败；原因：超过时限」 |
| 结果不明（P2） | Run 进行中动作为「结果待核实」（in_progress）；`run.ended` 后成为终态：v1 `failed`、标题「结果未知 · 需要核实」、`rawOutput {execution: terminated, outcome: unknown}`、「1 个动作待核实」；从不重试 |

### 三.3 越权参数

任务输入出现 `origin`、`lifetime`、`ownership`（含 `platform_durable`、`platform`、`gui_explorer` 等要求 Durable 的取值）或 `clientId`、`agentId`、`trusted`、`principal`：ACP 本地拒绝，码为 `ownership_escalation_denied`，`unit.run` 调用数为 0，Run 数不变。真 Runtime 上直接用线客户端发同样参数：无 Run、账本 failed，错误码按 Q1 的答复。

### 三.4 事件进入投影

- 已受理 ≠ 已执行 ≠ 已验证：三者分属 `action.accepted`、`action.completed`（回执 dispatched/completed）、Runtime 的验证结果；回执的 `verification` 今天恒为 `not_requested`，不得据此显示已验证。
- P1：窗口标题、人名、键入内容不进入任何帧（含 `unit.*` 的 data）；`unit.*` 只显示类型名。
- P2：见上表。

### 三.5 结果经 Wire v1 给 Zed

每一帧 `session/update`、`session/request_permission` 和回复都对 vendored ACP v1 schema（`Fixtures/acp-schema/v1`）校验，零违例；动作卡片的 `_meta.agentdesktop.actionLevel` 给出内部等级，便于证据比对。

## 四、已交付的测试（`Tests/AgentDesktopACPTests/Pending/UnitRun/`）

| 文件 | 层 | 内容 |
| --- | --- | --- |
| `URTestRuntime.swift` | Mock 辅助 | 按冻结形状应答的假 runtime/1：账本重放、Schema 校验、越权拒绝（F40-06 第 1 行）、前置检查拒绝、完整的 `Run`（含 `unit`）、`PlatformRunEvent`、`CancelReceipt`、`RequestRecord`；它发出与收到的每个值都对契约校验，违例让测试失败 |
| `URTestSupport.swift` | Mock 辅助 | 驱动器（目录 → 提交 → 事件 → 投影 → Wire v1 帧，按场景在某事件后取消或断连）；场景期望检查；真实管道上的编辑器（与 dev 入口同一套 Transport / Server / Projector / Wire / Store） |
| `UnitRunContractTests.swift` | Mock | 10 个：冻结夹具、越权字段的 Schema 证据、场景输入与事件合法、目录与配置、参数构造与本地拒绝、越权本地码；UR-G2、UR-G3 为 known issue |
| `UnitRunFlowTests.swift` | Mock | 16 个：五类场景加时限用尽、调用超时、回复丢失、14 行前置检查、越权从不发出、Runtime 侧越权应答、无宣告、`unit.*` 不泄露；UR-G4、UR-G5 为 known issue |
| `UnitRunServerTests.swift` | Mock（全栈） | 3 个：Ask 模式拒绝 → 不发 `unit.run`；批准后因 UR-G1 仍不发（known issue）；prompt 里的越权被拒 |
| `UnitRunRealRuntimeTests.swift` | Real（未运行） | 8 个，全部 `.disabled("waiting for A6 unit.run: …")`：宣告、正常、取消、断连 owner_lost、审批拒绝（另等 PR4）、结果不明、越权、前置检查落账。只允许连 `/tmp/adt-*` 测试副本（`AGENTDESKTOP_ENDPOINT`），需要 `URTEST_DESKTOP_ID` |
| `Fixtures/ur-*.json` | 夹具 | 见第五节 |

计数：Mock 29 个（今天运行、全部通过，其中 6 处为固定差距的 known issue），Real 8 个（已写、禁用、未运行）。

**Mock 的含义**：证明 ACP 这一侧按冻结形状说话、在每类情况下做对的事；不证明 Runtime 会这样做。A6 是否完成只看 40 的实现与真 Runtime 测试、G1/G3 的真实记录。

## 五、给工作线 Q 的夹具

`Pending/UnitRun/Fixtures/`：

| 文件 | E2E 类别 | 门禁 |
| --- | --- | --- |
| `ur-normal.json` | 正常完成 | G1-06、07、08、11 |
| `ur-cancel.json` | 取消 | G2-05、G1-11 |
| `ur-disconnect.json` | 断连（ACP-29） | G1-10、G3-03 |
| `ur-approval-rejected.json` | 审批拒绝 | G2-06、07 |
| `ur-unknown.json` | 结果不明（P2） | G3-01、G3-14 |
| `ur-limit-exhausted.json` | 时限用尽 | G3-09 |
| `ur-precheck-refusals.json` | F40-06 第 2–15 行 | G1-06 |
| `ur-escalation.json` | 越权参数 | G1-09、ADR v2.2 |

每个场景文件：`input`（编辑器给的任务输入，不含 desktopId）、`desktopId`、`runtime`（Mock 用：受理后的阶段、`onAccept` 事件、触发条件 `cancelAfter` / `disconnectAfter`、`onTrigger` 事件、`final` Run 状态；事件里的 `$RUN` 由假 Runtime 换成真实 runId）、`expect`（两层共用：`actionLevels`、`finalToolStatus`、`finalRawOutput`、`planResult`、`textContains`、`textExcludes`、`runtimeFinal`、`unitRunCalls`、`cancelCalls`）。真 Runtime 上 `runtime` 一节不适用，只用 `input` 与 `expect`；事件序列以真实记录为准，与夹具不同之处要回报给 40 与 E。`unit.*` 事件标 `frozen: false`，按 A6 草案 3.2 写，目录冻结后改。

已知小问题：夹具是测试目标里的 `.json`，SwiftPM 构建时提示「8 个文件未处理」（警告，不影响构建）。`Package.swift` 只排除了 `Fixtures`，本工作包不许改它；请协调者把 `Pending/UnitRun/Fixtures` 加进 `AgentDesktopACPTests` 的 `exclude`。

## 六、需要负责人答复的问题

| 编号 | 问谁 | 问题 |
| --- | --- | --- |
| Q1 | f1、40 | 越权字段（origin / lifetime / ownership）的错误码：#102 冻结的契约与文档是 `ownership_escalation_denied`（Schema 放行），07 §〇 R1 记录的是 `schema_invalid`。以哪个为准？若改成 `schema_invalid`，契约、夹具 `unit-run-escalation-fields-reach-the-handler.valid.json` 和冻结文档都要改 |
| Q2 | 40 | 自由文本映射（F40 增量）：一句话 prompt 填 `goal.description`，`mode`、`verification`、`allowedActions` 由什么给出？没有 `verification` 的任务能不能提交？答复前 R 是否应把 `allowFreeText` 改为 false |
| Q3 | 40、f1 | `unit.*` 事件目录何时冻结、是否带敏感分级；`unit.observation` 的 `coverage` 取值；是否保证 `data` 不含窗口标题与键入内容（P1） |
| Q4 | f1、Kevin | `Run.unit.verification.status = matched`（Runtime 对新观察做的验证）是否就是 README §九所说「验证结果落地」？若是，ACP 可在 Run 结束时显示「已验证」，取值来自 `run.show` 还是 `unit.verification` 事件？`run.ended` 是否会带验证状态 |
| Q5 | 40 | 前置检查失败是否保证写 `RequestRecord.state = failed` 且同 requestId 重放原错误（07 §〇 R1 的说法）？这一点在 A6 草案里没有写 |
| Q6 | 40、f1 | 线协议上的 `unit.run` 是否在 Desktop 被其他控制者持有时立即 `control_busy`（第 6 行），还是排队？ACP 按立即拒绝写了夹具 |
| Q7 | f1、40 | unit Run 的 `closingReason` 取值表（验证未达成、步数用尽、模型无效建议、`audit_unavailable`），以便 E 显示原因（UR-E3） |
| Q8 | 协调者 | UR-G1 的方案：会话配置项「Desktop」由 S 从 `desktop.list` 填充，还是由 Runtime 给 ACP 连接一个默认 Desktop？这改的是 S 的行为，`ACPSubmission.desktopId` 已在冻结接口里 |
| Q9 | 协调者 | UR-G4 需要在冻结接口 `ACPSubmissionReceipt.refused` 加 `reason`，请协调者决定 |

## 七、验收标准与依赖

**本工作包（已满足）**：Mock 29 个通过、Real 8 个禁用且原因写明「waiting for A6 unit.run」；`swift build`、`swift test`、`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test --filter AgentDesktopACPTests` 退出码 0（PR 正文记录）。

**A6 之后 ACP 侧算通过**，全部要真实记录（L2 真 Runtime 测试副本，L3 再加 Zed）：

1. G1-06：一次 Zed prompt 只产生一个 Run（RunStore 一条），且为 `unit / agent_hub / external_client / connection_scoped`。前提：UR-G1 已修。
2. G1-07：Zed 的命令列表里出现 `unit.run` 任务（来自 Runtime 宣告），提示里不含越权字段（UR-G2）。
3. G1-08：真实动作卡片 accepted → dispatched → executed；没有验证结果时不出现「已验证」。
4. G1-10 / G3-03 / ACP-29：执行中 Cmd-Q 与 `kill -9` Zed，Run `ended`、`closingReason: owner_lost`、之后无 GUI 输入、未确认的动作为 unknown；ACP 进程随 stdin EOF 退出，无孤儿。
5. G3-01 / G3-14：真实 unknown 动作为终态「结果未知 · 需要核实」，日志里没有第二个 `unit.run` 或重发的动作。
6. 五类端到端：正常、取消、断连、审批拒绝、结果未知，各至少一份证据（e2e-runbook §八 的目录约定）。审批拒绝的 Runtime 侧部分另等 PR4 inbox；编辑器侧（Ask 模式拒绝不发 `unit.run`）A6 后即可验。
7. Real 测试去掉 `.disabled` 后在测试副本上通过；Mock 测试继续保留，作为回归。

**依赖**：A6 `unit.run`（40，PR2d #50）→ 所有真实部分；PR4 inbox（f1）→ 审批拒绝的 Runtime 侧；A4 身份（f1）→ G1-09；Zed 手工 Z1（Kevin）→ L3 记录；ACP 自身：UR-G1（S）是 G1-06/G1-11 的硬前提，UR-G2～G6 与 UR-E1～E3 在 G3 之前修完。
