# UI-E：U7 GUI Explorer（P27–P29）组件验收记录（2026-10-11）

分支：`ui-e-explorer`，目标 `main`（#260 接缝已合入）。只改了 UI-E 负责的文件（`docs/plan/11-parallel-lanes.md`）。

**本记录只到组件验收这一级。页面验收待做**：需要真实 Runtime 测试副本、宿主接上进程内入口（见“需要协调”）以及真实窗口里的交互验证，按 02 §2.2 才算页面交付。

## 范围

| 页面 | 内容 | 渲染图 |
| --- | --- | --- |
| 一级 GUI Explorer | 跨 Desktop 的 GUI 运行历史（`kind = unit`），按范围（全部 / 进行中 / 已结束）和来源（主窗口发起 / 外部 Agent）筛选；学习层只放一行说明 | `explorer-history.png`、`explorer-history-start-pending.png`、`explorer-in-main-window.png` |
| P27 新建 GUI 诊断 | 目标 Desktop（占用、未绑定、正在关闭的不可选）、默认 GUI 配置、局部目标、完成后应出现的文字、允许的动作、运行限制（只能收紧 20 步 / 120 秒）、诊断范围确认（UC41） | `P27-new-diagnostic.png`、`P27-new-diagnostic-confirmed.png` |
| P28 执行中 | 五段进度（观察 / 模型建议 / 实际动作 / 重新观察 / 条件验证）、`unit.progress` 四项（已用步数、剩余步数、剩余推理次数、剩余秒数）、每步的模型尝试 / 建议 / 动作、条件验证、恢复、固定绑定、运行状态；停止诊断 | `P28-diagnostic-running.png`、`P28-diagnostic-stopping.png` |
| P29 完成 | 结束横幅与结束原因；成功、无进展、无法判定、结果未知四种结局 | `P29-diagnostic-verified.png`、`P29-diagnostic-no-progress.png`、`P29-diagnostic-inconclusive.png`、`P29-diagnostic-unknown.png` |

全部是测试进程里的离屏渲染（`SnapshotRenderer`，1440×1000），数据来自 Mock Runtime，界面带“样例数据”标记。没有截屏、没有打开真实窗口、没有启动应用、没有虚拟显示器、没有连接产品 socket、没有调用模型。

## 进程内发起入口

- Runtime 有：`RuntimeService.startDurableUnitRun(params:)`（A6，#240/#251/#255），建出 `gui_explorer / platform / platform_durable` 的 Durable Run。
- 宿主目前只把它接给旧的 `AgentDesktopAIUI`（`AppController.runtimeRuns`）。主窗口的 `RuntimePort` 和 `SectionContext` 没有这条路，Explorer 页拿不到。
- 本 PR 的处理：在自己的文件里定义 `ExplorerDurableStart` 和 SwiftUI 环境值 `\.explorerDurableStart`。
  - 环境里有：P27 通过它发起，成功后打开该 Run 的详情。
  - 环境里没有（现在的真实宿主）：页面只做观察，“新建 GUI 诊断 · 待接入”按钮不可用，并说明原因；**不会**改用线协议 `unit.run`（那会是 Delegated Run）。
- 页面构造的参数里永远没有 `origin / lifetime / ownership`（`ExplorerDraft.params`，有测试）。

## 与线框图对照

| 线框 | 一致 | 差异与原因 |
| --- | --- | --- |
| P27 | 模态布局、目标 Desktop / GUI 配置两列、局部目标、完成文字及“不以模型说完成为结果”、允许动作勾选、运行限制折叠、范围确认、取消 / 开始诊断 | GUI 配置只能用默认配置：配置列表属于 ai/1（U6），runtime/1 里没有；线框的“我确认这是本地中性诊断示例”改为真实范围确认（会调用模型、执行真实输入） |
| P28 | 标题、返回 / 停止诊断、五段进度、固定绑定（配置、决策步骤 3/20、模型尝试、实际输入）、输出区 | 不显示截图：事件和 Run 里没有截图，界面不去拼凑；改为说明并给“打开 Desktop”。本次目标只显示 `goalHash`：目标正文与完成条件不进运行记录。用量改为指向“设置 › 诊断与用量” |
| P29 | 结果横幅、条件验证结果、计数分离（样例 4 次模型尝试、2 次输入，与线框一致） | 同 P28；“导出证据”未做（等 PR4 `diagnostics.export`） |
| 一级 GUI Explorer | 运行历史；学习层只放说明 | 线框（G03–G08）属于 L4 学习阶段，本 PR 不做 |

动作结果按 06 §6.4：`confirmed` →“已执行，未验证”，`submitted` →“已受理”，`not_sent` / `rejected` →“未发出”，`unknown` →“结果未知 · 需要核实”，没有重试按钮；有 `request.show` 记录时以回执级别为准。验证 `inconclusive` 显示“无法判定”和原因（X1-1 的五种 reason）。`unit.recovery` 的未知 kind 显示为“恢复”。

## 测试（`Tests/AgentDesktopUITests/ExplorerTests.swift`）

| 测试 | 断言 |
| --- | --- |
| `connectionRunsAreDelegatedAndNeverEscalate` | 连接发起的 unit Run（线上 `unit.run` 的形状）是 agent_hub / external_client / connection_scoped；两种入口的参数带 origin / lifetime / ownership 一律 `ownership_escalation_denied`；Mock 不在线上提供 `unit.run`（共享 Mock 测试要求它不在建模列表里） |
| `durableStartIsPlatformOwnedAndInTheSameRunList` | 进程内发起是 gui_explorer / platform / platform_durable，出现在同一个 `run.list` 里；`callLog` 里没有 `unit.run` |
| `admissionRefusalsCreateNoRun` | `control_busy`、`unsupported_backend / gui_execution_off` 时不建 Run |
| `eventsFollowTheContractAndCarryNoText` | 四种剧本的 unit 事件全部符合 `UnitRunEvent`，事件里没有目标、完成文字或参数值 |
| `draftNeverCarriesOwnershipAndOnlyTightens` | 参数符合 `unit_run_params`、不含归属字段；超过上限、未确认范围、没有动作时不能开始；占用的 Desktop 不能选 |
| `starterGoesThroughTheInProcessEntry` | P27 经进程内入口发起，绑定所选 Desktop（UC42） |
| `verifiedRunCountsAttemptsApartFromInputs` | 4 次模型尝试、2 次输入；模型 finish 不作为成功依据；只有 matched 才是“已验证成功” |
| `stallShowsOneRecoveryAndTheEndingReason` | 1 次恢复（repeated_action），结束原因 no_progress |
| `inconclusiveIsNeverSuccessAndSaysWhy` | “无法判定”并给原因；不成功 |
| `unknownActionNeedsVerification` | “结果未知 · 需要核实”，回执级别一致 |
| `unknownKindsAndTypesAreTolerated` | 未知恢复 kind 显示“恢复”，未知事件类型忽略 |
| `stopWaitsForQuiescenceAndKeepsTheDesktop` | 停止后先是 stopping / pending，执行端确认后才 ended / cancelled；停止后没有新的 unit 事件；Desktop 和其他运行不受影响（UC45–UC48） |
| `closingThePageNeverStopsTheRun` | 渲染并销毁详情页不调用 `run.cancel`，Run 继续并能完成（ADR-06） |
| `historyListsOnlyUnitRunsFromBothSources` | 历史只列 unit Run，两种来源都在 |
| `rendersAgainstWireframes` | 生成本目录的渲染图（`AGENTDESKTOP_UI_SNAPSHOTS=docs/acceptance/ui-e`） |

测试结果见 PR 描述。

## 需要协调

1. **宿主接线**（`Sources/AgentDesktop/MainWindow.swift`，不在本线范围）：在 `MainWindowView` 上加 `.environment(\.explorerDurableStart, ExplorerDurableStart { p in await offPool { runtime.startDurableUnitRun(params: p) } })`，与 `AppController.runtimeRuns` 一样不在主线程、不在协作线程池上调用。接上之前，真实应用里“发起”显示为待接入。
2. **Desktop 详情的 Explorer 标签**（UI-B 的 Desktop 页）：可以直接放 `ExplorerPage(…, route: .history)` 或按 desktopId 预选的 P27；需要协调者和 UI-B 对接。
3. **`ShellNavigation` 增加 Explorer 的 runId**（公共文件）：现在详情路由是页面自己的状态，切换一级入口后回到历史。
4. **契约请求**：`run.list` 按 `kind` 筛选（F1-09），现在历史在客户端按 `kind = unit` 过滤，受 `limit 200` 限制。
