# 11 Run 最新事件游标：差距、测试要求与契约提案

状态：ACP 辅助工作包，2026-10-08，基于 `main` cbe7772。
范围：Kevin 批准 ACP 准备测试与契约提案，**不批准 ACP 实现 Runtime 游标或事件存储**。本文第四节全部是给 Runtime 负责人（f1）的**提案**，不是决定；Runtime、契约、Client 一行未改。
测试：`Tests/AgentDesktopACPTests/Pending/Cursor/`（辅助类型以 `CurTest` 开头）。

> **Mock 通过不等于游标完成。** 本包的 Mock 测试只证明 ACP 自己这一侧（桥的去重、回放边界、错误映射、不重发不恢复）在假 Runtime 上成立。Runtime 游标完成的唯一标准是第七节的 Real 测试在真实测试副本上通过，并且契约已冻结。

## 一、背景与依据

- 07-runtime-requests.md R10：f1 审核结论「接受，PR2b」，`Run.lastEventSequence`（≥0，无事件为 0），`run.show` / `run.list` / `run.wait` 都带。README 第九节把「Run 最新事件游标」列为 **P0**。
- runtime-api-v1-freeze.md §4：每个 Run 的事件有单调序号；`run.events {runId, after, limit}` 的 `next` 是恢复游标，断线重连从 `next` 继续，不丢不重；全局游标落在保留区间外返回 `events_cursor_expired`。
- ADR v2.2（docs/architecture/ADR-v2.2-hub-ui-run-lifetime.md:42、76、95、111）：外部 Agent 重连**不自动恢复旧 Run**；控制连接失效后立即阻止新输入，并停止它的 connection_scoped Run。
- README 第五节 K1：会话恢复不等于 Run 恢复；ACP 发起的 Run 一律 connection_scoped。

## 二、差距表（现状 vs 目标）

行号以 main cbe7772 为准。

| # | 主题 | 现状（证据） | 目标 | 负责 |
| --- | --- | --- | --- | --- |
| G1 | Run 上没有最新序号 | `Run` 的 schema 没有 `lastEventSequence`（`contracts/runtime/v1/runtime.schema.json:1790` 起，`additionalProperties: false`）；`methods.json` 的 `plannedFields` 里也没有它；全仓只有 ACP 读这个名字（`ACPBridgeRuntimePort.swift:338`、`:347`） | 可选字段 `Run.lastEventSequence`，run.show/list/wait 都带（P1） | f1 |
| G2 | ACP 恢复时的 `lastCursor` 恒为 nil | `ACPRunSnapshot.lastCursor` 只取 Run 上的这个字段（`ACPBridgeRuntimePort.swift:341-347`，`Ports.swift:112`）；字段不存在所以恒为 nil；`session/load` 对进行中 Run 的「回放到 lastCursor 再回复」的等待因此跳过（`ACPAgentServer.swift:264`） | 字段到位后自动生效，ACP 不改代码 | f1（ACP 已就绪） |
| G3 | 单个 Run 的游标不校验 | 带 runId 的 `events.subscribe` 直接用 `after ?? 0`，不检查上下界（`RuntimeService+Events.swift:42`）；`run.events` 同样（`RuntimeService+Runs.swift:75`）。游标超过该 Run 最新序号时**静默接受**：进行中的 Run 会把序号 ≤ after 的新事件全部跳过，客户端无从得知 | 超前游标返回明确错误（P3） | f1 |
| G4 | `events_cursor_expired` 只用于全局游标，目录仍标 reserved | 只有不带 runId 的订阅检查区间（`RuntimeService+Events.swift:44-49`）；`errors.json:153-159` 该码仍是 `reserved: true`；details 只有 `latest`（全局 rowid），不是 Run 的序号 | 转正式码；按 Run 的 details（P3） | f1 |
| G5 | 保留期到期后不可区分 | Run 与其事件在创建满 7 天且已结束后一起删除（`RunStore.swift:73`、`:122-123`）；之后 `run.show` / `run.events` / 订阅都是 `not_found`（`RuntimeService+Runs.swift:12`），与「无权查看」相同。按 Run 的游标因此**永远不会**过期，只会整体消失 | 维持 not_found 不泄露；另给不含 Run 信息的保留期说明（Q3） | f1 |
| G6 | 序号连续性只是实现细节 | 序号 = 该 Run 的 `MAX(seq)+1`，在同一事务内写入（`RunStore.swift:243`），事件只随 Run 整体删除，所以今天是 1…N 无空洞；契约没有写明 | 契约写明「1…N 连续、只增不改」，客户端可据此判断缺失（P2） | f1 |
| G7 | 跨客户端读取 | `ownRun` 对 owner 放行全部 Run（`RuntimeService+Runs.swift:8`、`:12`）；A4 之前每个本机连接都是 `local:<uid>` owner，所以「不能读别的客户端的事件」在 Runtime 侧**今天无法证明** | A4/PR3 之后按 clientId 隔离；不可见的 Run 一律 not_found | f1（A4） |
| G8 | ACP 桥的去重与恢复 | 已实现：从上次投递的序号续订（`ACPBridgeEventReader.swift:30`、`:87-107`），丢弃 ≤ last 与其他 runId 的帧（`:141-142`），非瞬时错误（含游标错误、not_found）直接结束流、不重试（`:69-71`） | 保持；本包 CUR-M01～M07 守护 | ACP（已完成，Mock 证明） |
| G9 | ACP 会话层去重与隔离 | 已实现：按会话按 Run 的 `seen` 去重，丢弃 runId 不符的事件（`ACPAgentServer.swift:382-389`）；`session/load` 先回放后回复（`:225-253`）；他人会话一律 `session_not_found`（`:193-196`） | 保持；CUR-M10～M17 守护 | ACP（已完成，Mock 证明） |
| G10 | `session/resume` 的起点会随 R10 改变语义 | 起点是 `snap.lastCursor ?? binding.lastCursor[runId]`（`ACPAgentServer.swift:211`）。今天 lastCursor 为 nil，从编辑器上次看到的位置续读，断开期间的事件会补上（CUR-M10）；R10 落地后改为从「现在」开始，断开期间的事件**不再显示**（CUR-M11 固定了这一行为） | 需要决定（Q2） | ACP 协调者 |
| G11 | 游标错误时的提示 | 跟随任务吞掉流错误（`ACPAgentServer.swift:373-376`）；进行中的 Run 仍显示快照状态行，但**已结束**的 Run 遇到游标错误时编辑器什么都看不到 | 给一条「历史不完整」的说明（Q5，CUR-M18 已写好、未运行） | ACP（等 P3 定形） |
| G12 | 断连后不恢复 Delegated Run | ACP 侧：`connectionLost()` 只关闭控制连接，不重连、不重发（`ACPBridgeRuntimePort.swift:289-296`）；恢复会话不提交、不取消、不跟随已结束的 Run（`ACPAgentServer.swift:204-213`）。Runtime 侧：`ownerLost` 停止该连接的 connection_scoped Run（`ExecutionCoordinator.swift:248-253`）。ACP 从不调用 `run.attach` | 保持；真实验证等 A6（CUR-R07） | ACP 已完成；真实验证依赖 A6 |

## 三、测试要求（Kevin 的清单）

| 要求 | 必须证明的事 | Mock（今天可跑） | Real（已写、未运行） |
| --- | --- | --- | --- |
| 1. 断开后从正确位置恢复 | `session/resume` 从编辑器上次看到的位置续读；`session/load` 为空白编辑器从头回放；桥断流后从上次投递的序号续订 | CUR-M02、M10、M11、M13 | CUR-R04 |
| 2. 恢复期间不丢不重（含 lastCursor 处的实时/历史边界） | 每个序号恰好一次；≤ lastCursor 的历史在回复之前；恰在快照之后写入的事件也只出现一次；来源重复或忽略游标时仍只出现一次 | CUR-M01、M12、M13、M14 | CUR-R01（连续性）、R02、R05 |
| 3. 不能读取其他客户端的事件 | 他人会话不可加载且不读取其 Run；串入的他人 Run 事件被丢弃；Runtime 对不可见的 Run 返回 not_found | CUR-M03、M05、M15、M16（仅 ACP 侧） | CUR-R06（要 A4 第二身份） |
| 4. 无效或过期游标返回明确错误 | Runtime 返回 `events_cursor_expired`（带 Run 的最新序号）；ACP 原样映射、不重试、不倒回已存游标；load 仍回复、显示快照、继续服务 | CUR-M04、M17；目标 M18 未运行 | CUR-R03 |
| 5. 断开后 Delegated Run 不自动恢复（ADR v2.2） | 断开后 Run 结束（owner_lost）；重连（load 与 resume）不提交、不取消、不新建、不跟随；结束后的读取不产生新事件 | CUR-M07、M19 | CUR-R07（要 A6） |

层级标注：每个测试名都以 `[Mock]`、`[Mock · not run]` 或 `[Real · not run]` 开头。Real 套件另有 `.enabled(if: CURTEST_REAL_ENDPOINT)`，只能指向 `/tmp/adt-*` 测试副本，不能是产品 endpoint。

## 四、字段与游标语义提案（交 Runtime 负责人）

以下都是**提案**，形状与命名由 f1 决定。原则沿用 07：只提通用能力，不加 `acp.*` 方法；只加可选字段（冻结规则 1）。

- **P1 `Run.lastEventSequence`**（即 R10）：整数 ≥ 0，该 Run 已写入的最大 `sequence`，没有事件为 0；`run.show`、`run.list`、`run.wait` 都带。与 `run.ended` 的关系：Run 为 `ended` 时，它等于 `run.ended` 事件的序号（目录已规定 `run.ended` 是最后一条）。
- **P2 序号语义写进契约**：单个 Run 内 `sequence` 从 1 开始、连续、只增，写入后不改不删；事件只随 Run 整体过保留期删除。`EventFrame.cursor` 在带 runId 的订阅里等于 `event.sequence`（schema 描述已这么写，`runtime.schema.json:2471-2475`）。
- **P3 按 Run 的游标校验**：带 runId 的 `events.subscribe` 与 `run.events` 遇到 `after > lastEventSequence` 时返回 `events_cursor_expired`，`details: {runId, lastEventSequence, reason: "ahead"}`；全局游标保持现状并补 `reason: "pruned" | "ahead"`。`errors.json` 把该码的 `reserved` 去掉。Run 不存在或不可见仍为 `not_found`，不新增区分。
- **P4 边界语义**：`after = lastEventSequence` 时，已结束的 Run 不推送任何帧并关闭连接；进行中的 Run 只推之后的新事件。客户端「先取快照得到 N，再从 0 订阅、等到 N 再回复」即可得到无缝的历史/实时边界，不需要 Runtime 额外的快照一致读。
- **P5 隔离**：A4 之后，`run.show` / `run.events` / `events.subscribe` 对其他 clientId 的 Run 一律 `not_found`，不带 `lastEventSequence` 等任何字段；全局订阅只推本主体可见的 Run（今天 `eventsSince` 已按 clientId 过滤，`RunStore.swift:263-268`，但 owner 看全部）。

ACP 侧届时**不需要改代码**的部分：读取 `lastEventSequence`（已按名读取）、按序号去重、游标错误映射。需要改的部分只在会话层，见 Q2、Q5。

## 五、Mock 与真实验收的界线

- Mock 测试的假 Runtime（`CurTestWire`、`CurTestPort`）按第四节的提案行为编写；它们通过只说明「如果 Runtime 这样做，ACP 会正确处理」。
- 变异检查（本地执行，已恢复）：去掉 `ACPAgentServer` 的按序号去重与 `ACPBridgeEventReader` 的 `seq > last` 判断后，CUR-M01 与 CUR-M14 失败，说明这两条测试确实守护去重。
- 06-gates.md 中 G2-01、G2-10、G3-03 的状态**不因本包改变**；本包不改 cases.csv。

## 六、开放问题

| 编号 | 问题 | 问谁 | 本包的建议 |
| --- | --- | --- | --- |
| Q1 | P3：超前游标用 `events_cursor_expired` 加 `reason: "ahead"`，还是用 `schema_invalid` / `conflict`？ | f1 | 用同一个码，客户端只有一条处理路径：改读快照 |
| Q2 | `session/resume` 在 R10 落地后应从哪里开始：编辑器上次看到的位置（补上断开期间的事件），还是「现在」？今天两种行为取决于字段是否存在（G10） | ACP 协调者 | 从 `binding.lastCursor` 开始，没有时再用快照；需注意 `binding.lastCursor` 只在跟随结束、断开时落盘，进程崩溃时可能偏旧，偏旧只会多读、靠去重不重复显示 |
| Q3 | 保留期到期后，客户端如何区分「已过保留期」和「不可见」？是否在 `not_found` 的 details 里给不含 Run 信息的 `retentionDays`、`instanceId`（与 R7 同形） | f1 | 给；不暴露 Run 是否曾存在 |
| Q4 | `lastEventSequence` 是否也放进 `EventSubscription` 的回复（订阅时的最新序号），省掉一次 `run.show`？ | f1 | 可选，不阻塞 |
| Q5 | 已结束 Run 遇到游标错误时，编辑器显示什么文案？ | ACP 协调者 / E 线 | 「任务 X：历史记录不完整，以下为当前状态」加快照状态行（CUR-M18） |
| Q6 | Runtime 重启（`instanceId` 变化）后，ACP 存的 `lastCursor` 是否仍有效？今天同一数据目录下序号不变；换数据目录时同名 runId 不会出现 | f1 | 契约写明「游标在同一数据目录内有效」，换目录时返回 not_found |

## 七、验收标准与依赖

**本包完成的标准**（已满足）：第三节每条要求都有 Mock 测试且通过、Real 测试已写并禁用；`swift build`、`swift test`、`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test --filter AgentDesktopACPTests` 退出码 0。

**游标完成的标准**（不归本包，记录在此）：

1. f1 的 PR2b 冻结 P1（至少），schema、夹具、goldens 同时进入；最好同时包含 P2、P3。
2. 把 CUR-R01～R05 的 `.disabled` 去掉，在 `/tmp/adt-*` 测试副本上运行（`CURTEST_REAL_ENDPOINT`、`CURTEST_REAL_RUN_ID`），退出码 0，记录证据。
3. A4 合入后运行 CUR-R06（ACP-31-03、ACP-T07-04）；A6 合入后运行 CUR-R07（ACP-30-01、02）。
4. Zed 手工：ACP-30-01～02、ACP-T13-02（重开后事件不重复）按 tests/e2e-runbook.md §六执行。

**依赖与门禁映射**：

| 门禁 | 用例 | 本包测试 | 阻塞于 |
| --- | --- | --- | --- |
| G2-01（T06 恢复关联） | ACP-T06-05 | CUR-M10～M13、R05 | R10/P1、A4、A6 |
| G2-02、G2-11（越权） | ACP-T07-04、ACP-31-03 | CUR-M15、M16、R06 | A4 |
| G2-10（重连不自动恢复） | ACP-30-01～03 | CUR-M17、M19、R03、R07 | A6、A4、P3、Zed 手工 |
| G3-02（T13 只读观察） | ACP-T13-02 | CUR-M10、M11、M14 | A4、A6、U7、Q2 |
| G3-03（断连按 ADR 停止） | ACP-29-01～03 | CUR-M07、M19 | A6、Zed 手工 |

## 八、测试清单

| 编号 | 层级 | 文件 | 内容 |
| --- | --- | --- | --- |
| CUR-M01 | Mock | CurBridgeCursorTests | 来源重复帧且忽略 after 时，桥只交出 after 之后的序号各一次 |
| CUR-M02 | Mock | CurBridgeCursorTests | 订阅中断后从上次投递的序号续读，不丢不重 |
| CUR-M03 | Mock | CurBridgeCursorTests | 其他 Run 的帧被丢弃 |
| CUR-M04 | Mock | CurBridgeCursorTests | `events_cursor_expired` 原样映射、只订阅一次、不发其他请求 |
| CUR-M05 | Mock | CurBridgeCursorTests | 不可见的 Run 为 not_found、不重试 |
| CUR-M06 | Mock | CurBridgeCursorTests | 只在 Run 带 `lastEventSequence` 时读取（缺省 nil，0 为 0），不自行统计 |
| CUR-M07 | Mock | CurBridgeCursorTests | 控制连接断开后不开流、不提交、不新建连接、不发 attach/start/cancel |
| CUR-M10 | Mock | CurServerResumeTests | 无 lastCursor 时 resume 从已存游标续读，断开期间的事件各一次 |
| CUR-M11 | Mock | CurServerResumeTests | 有 lastCursor 时 resume 从快照游标开始（固定现状，见 Q2） |
| CUR-M12 | Mock | CurServerResumeTests | load：lastCursor 之前的历史先于回复；边界事件恰好一次 |
| CUR-M13 | Mock | CurServerResumeTests | load 无 lastCursor：全部事件各一次，已结束 Run 在回复前回放完 |
| CUR-M14 | Mock | CurServerResumeTests | 来源重复且忽略游标时会话层仍只显示一次 |
| CUR-M15 | Mock | CurServerResumeTests | 他人会话 not_found，且不读取其 Run 的快照或事件 |
| CUR-M16 | Mock | CurServerResumeTests | 串入的他人 Run 事件被丢弃，也不写入游标 |
| CUR-M17 | Mock | CurServerResumeTests | 游标过期时 load 仍回复、显示快照、不重发、继续服务、不改已存游标 |
| CUR-M18 | Mock · 未运行 | CurServerResumeTests | 目标：已结束 Run 游标过期时提示历史不完整（Q5） |
| CUR-M19 | Mock | CurServerResumeTests | 断开结束 Delegated Run；resume 与 load 重连都不提交、不取消、不新建、不跟随 |
| CUR-R01 | Real · 未运行 | CurRealRuntimeCursorTests | `run.show.lastEventSequence` 等于最后序号；序号 1…N 连续 |
| CUR-R02 | Real · 未运行 | CurRealRuntimeCursorTests | 已结束 Run 在 lastEventSequence 处订阅：零帧并关闭 |
| CUR-R03 | Real · 未运行 | CurRealRuntimeCursorTests | 超前游标：subscribe 与 run.events 都返回 `events_cursor_expired` |
| CUR-R04 | Real · 未运行 | CurRealRuntimeCursorTests | 桥从中间游标续读，不丢不重 |
| CUR-R05 | Real · 未运行 | CurRealRuntimeCursorTests | load 在回复前恰好回放 lastEventSequence 条 |
| CUR-R06 | Real · 未运行 | CurRealRuntimeCursorTests | 第二身份按 runId 读不到（要 A4） |
| CUR-R07 | Real · 未运行 | CurRealRuntimeCursorTests | Delegated Run 断开后保持 ended，重连不新建（要 A6） |
