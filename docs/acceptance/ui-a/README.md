# UI-A：U1b-2 事件驱动 Store 与 U5 Runs（组件验收，2026-10-11）

基线：`origin/ui-lane-seams@dd7efe9`（PR #260），之后合并了 `origin/main@36f84e9`（#260 已合入 main）。工作线规则见 `docs/plan/11-parallel-lanes.md`。

**验收级别：只到组件验收**（单元测试 + 离屏渲染）。页面验收（真实 Runtime、真实窗口、交互）**待做**：本线不启动应用、不建窗口、不连产品 socket。

## U1b-2 事件驱动 Store

改动在 `Sources/AgentDesktopUI/Store/`：

- `ShellStore` 的 Runs 改为跟随 `events.subscribe`（推送循环），Desktops 与状态仍按间隔轮询（runtime/1 还没有 Desktop 事件，F1-02）。
- 游标续订：每帧先用 `run.show` 读到 Run 后才前移游标；断流后从最后一个已应用的游标续订，中间的事件不丢。
- 从“现在”开始订阅时（首次或游标过期后），在订阅建立**之后**再取一次 `run.list` 快照，订阅前后之间的变化不会漏掉。
- `events_cursor_expired`：清空游标，从现在订阅，再取快照。
- 断连：订阅时 Runtime 不可达 → 显示 Disconnected，轮询循环重连成功后推送自动恢复（带游标）；连接中断流 → 暂停一个间隔后续订。
- Runtime 主动结束流：有事件则立即续订，否则暂停一个间隔后续订。
- 推送不可用（`capability_missing` 等其它错误）：Runs 退回轮询，`pushFallback` 记下原因；下次重连会再试推送。
- 快照与推送合并：快照决定列出哪些 Run，但不会把已推送到更高 revision 的 Run 改回旧值。
- 代数（generation）与票据丢弃过期结果的规则不变；推送读到的 Run 和游标也按代数丢弃。
- 页面只看 `runs` 和 `tick`，不知道数据来自推送还是轮询。
- 新增 `PulledEventStream`：把“取帧式”订阅（进程内 `RuntimeService.pendingEventFrames`，与 socket 服务器每 200 ms 取帧的做法相同）包装成 `RuntimePort.subscribe` 返回的流；读者停止时退订一次，不影响任何 Run。

### 需要协调：宿主接线（不在本线文件范围）

进程内端口在 `Sources/AgentDesktop/InProcessRuntimePort.swift`、`AppController.swift`，不属于 UI-A。补丁见 [u1b2-host-wiring.patch](u1b2-host-wiring.patch)：

- `InProcessRuntimePort.subscribe`：独立 `ConnectionState`，先 `runtime.handshake`，再 `events.subscribe`，用 `PulledEventStream` 在端口自己的串行队列上取帧；访问被撤销或流取完时结束；读者停止时 `events.unsubscribe`。
- `AppController`：`ShellStore(runtime: port)`（去掉 `allowSubscription: false`）。
- `MainWindowHostTests`：新增 `inProcessPortPushesRunEvents`（真实 `RuntimeService` + 无屏幕平台，持久 Run 的开始和停止都经进程内订阅到达 Store）。

本地已打上补丁验证：`MainWindowHostTests` 两项进程内测试通过（0.55 秒）。补丁没有提交到本分支。合入前宿主即使不打补丁也安全：进程内端口现在对 `subscribe` 抛 `capability_missing`，Store 会退回轮询。

## U5 Runs

| 页面 | 文件 | Runtime 方法 |
| --- | --- | --- |
| 全部运行（Hub W04） | `Pages/RunsPages.swift` `RunsListView`、`Pages/Loaders.swift` `RunListLoader` | `run.list`（origin / desktopId / clientId / active 由 Runtime 过滤，游标翻页） |
| 运行详情（Hub W05） | `RunsPages.swift` `RunInspectorView`、`RunDetailLoader` | `run.show`、`run.events`（增量）、`request.show`（未发出原因）、`run.cancel` |
| 动作记录（P19） | `Pages/RunsActionRecords.swift` `ActionRecordsView`、`ActionRecordsLoader` | `request.list`（desktopId / state 过滤，游标翻页）、`request.export` + `artifact.read` |
| 动作回执（P20） | `RunsActionRecords.swift` `ReceiptDetailView` | `request.show`（或列表里已有的记录） |

规则（06 §6.3、§6.4）：

- 执行阶段、最终结果、输入静止三列分开；`stopping` 一直显示“停止中”，执行端确认静止后才“已结束”。
- `kind = act` 且 `outcome = success` 只显示“已投递”；`outcome = unknown` 显示“结果未知 · 需要核实”。
- 动作结果按三级逐行显示：投递、执行、验证；汇总徽章“已受理 / 未发出（附原因）/ 已执行，未验证 / 执行失败 / 结果未知 · 需要核实”。回执的 `verification` 只会是 `not_requested`，一律“未请求（平台不判断目标是否变化）”。没有任何重试按钮。
- `action.refused`（被拒绝、未发出）显示“未发出”和原因码；`ActionEntry` 也照此改了，Desktop 详情的最近动作同样受益。
- GUI 单元运行（`kind = unit`）的验证来自 `Run.unit.verification.status`：matched“已验证成功”、contradicted“验证未通过”、inconclusive“无法判定”、not_run“未验证”。单元成功结束时列表显示验证结果，而不是“成功”。三值不依赖 PR #257：契约里 `RunUnit.verification.status` 已有 inconclusive。
- 非输入方法（如 `desktop.create`）的记录按 `state` 显示“已受理 / 已完成 / 失败 / 结果未知 · 需要核实”，不套用回执文案。
- 业务结果一律“业务结果：未评估”。
- 停止运行：确认后调 `run.cancel`，显示 Runtime 的回答（已受理 · phase · quiescence），不自行标记已停止。
- 关联画面：回执只有画面 ID；按画面 ID 取图尚未提供（F1-05），不显示示例图。
- 搜索只在已加载的记录里进行（`request.list` 没有文本搜索），页面写明。
- “导出记录”调 `request.export`，读回产物后由用户点“保存 JSON…”才弹保存面板；单条回执“导出 JSON”同样只在点击时弹出。

Mock（`Runtime/MockLanes/MockRuntime+Runs.swift`）：新增 `request.list`、`request.export`（结果按契约 schema 校验），以及 `addUnitRun`、`addRefusedAction` 两个场景函数。

## 离屏渲染与线框图对照（1440×1000，Mock，样例数据标识常驻）

| 渲染 | 对照 | 结论 |
| --- | --- | --- |
| [W04-runs-list.png](W04-runs-list.png) | Hub W04 | 一致：筛选（运行范围含“结果未知”、来源、Desktop、调用主体），平台 Run / 调用方 / 执行阶段 / 最终结果 / 输入静止分列，两条说明卡片。差异：W04 的“业务关联”列没有契约字段，不做；多了“验证”列（6.4 第三级）；“全部运行 / 动作记录”标签放在标题右侧（导航不改公共文件） |
| [W05-run-detail-act.png](W05-run-detail-act.png) | Hub W05、P20 部分 | 一致：三轴卡片 + 验证卡、动作与回执（三级逐行）、资源与归属、停止按钮。被拒绝和 target_moved 两种“未发出”都附原因 |
| [W05-run-detail-stopping-unknown.png](W05-run-detail-stopping-unknown.png) | Hub W05 两步停止 | 一致：停止中横幅“停止请求已受理，等待平台输入静止证据”，quiescence=pending；结果未知的动作提示只能核实、不重发。差异：W05 的“模拟执行端事件”与“外部业务 Task”不进产品 |
| [W05-run-detail-unit-inconclusive.png](W05-run-detail-unit-inconclusive.png) | Hub W05 “当前观察与验收” | GUI 单元面板：模式、目标摘要、验证观察、验证时间；inconclusive 显示“无法判定”并说明不能当成成功或失败 |
| [P19-action-records.png](P19-action-records.png) | P19 | 一致：标题、导出记录、所有 Desktop / 所有结果、搜索框、时间 / Desktop·调用者 / 动作（方法 + route·耗时）/ 请求 / 结果 / 详情。差异：结果用 6.4 文案，不用 P19 的“已回执” |
| [P19-action-records-exported.png](P19-action-records-exported.png) | P19 导出 | 导出后显示条数、产物 ID、字节数和“保存 JSON…” |
| [P20-receipt-executed.png](P20-receipt-executed.png)、[P20-receipt-not-dispatched.png](P20-receipt-not-dispatched.png)、[P20-receipt-unknown.png](P20-receipt-unknown.png) | P20 | 一致：浮层标题与 requestId、关联画面区、Desktop / 调用方 / 动作 / 结果、JSON 与复制、关闭 / 导出 JSON。差异：画面区只显示画面 ID（F1-05），JSON 是真实 RequestRecord 而不是 P20 的拟议格式 |

## 测试

| 命令 | 退出码 | 结果 |
| --- | --- | --- |
| `swift build --build-tests` | 0 | — |
| `swift test --skip-build` | 0 | 1421 项通过（Codex 修复后）；7 个 known issue 是原有的 ACP Mock 用例（`withKnownIssue`） |
| `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test --skip-build` | 0 | 1421 项通过（这一轮 `SingleEndpointTests` 没有超时） |

之前一轮（机器重启前、负载 25 左右）出现过 `SingleEndpointTests`、`RuntimeGuiPortsTests`（磁盘 `disk_unknown`）等原有用例失败，本 PR 没有改动这些文件；重启后同一提交整套通过。那一轮还暴露了本 PR 自己的两个问题，已修：`MockRuntimeTests.answersStayInsideTheContract` 改为只核对基础方法（各线方法在各自测试里核对）；新测试的等待从 Combine 的 `.values` 改为缓冲的 `AsyncStream`（前者在两次读取之间收到变化时会崩溃）。

新增测试（新测试一律用确定性的等待：等 Store 的 `tick` 发布后再检查条件，计时器只作为挂死时的保险）：

- `StorePushTests`（8 项）：推送而不轮询 run.list；断流后从游标续订且中间事件到达；游标过期后取快照；推送不可用退回轮询；断连后重连并续订；Runtime 结束流后重开；旧代数的推送结果被丢弃、快照不回退 revision；游标只在 Run 读到后前移。
- `PulledEventStreamTests`（3 项）：帧按序交出、订阅结束时流结束；读者停止时只退订一次且停止取帧；取帧出错时流带错误结束。
- `RunsU5Tests`（9 项）：Run 文案（act 已投递、unknown 需要核实、unit 三值）；动作三级；Mock 账本与导出；动作记录加载器（翻页、刷新保留、搜索、过滤、导出读回、失败与断开不回退样例）；运行列表加载器（游标翻页、服务端过滤、结果未知）；停止不等于已停止；被拒绝的动作显示未发出；单元运行详情；JSON 美化保持键序。
- `RunsRenderTests`（1 项）：上表 9 张渲染图。

## 未完成与依赖

- 页面验收（真实 Runtime、真实窗口）待做。
- 宿主接线补丁待协调者合入（见上）。
- 核实入口（`run.reconcile`）等 PR4（#269）；U9 Inbox 本轮不做。
- 关联画面按 snapshotId 取图（F1-05）；事件类型目录（F1-01）。
