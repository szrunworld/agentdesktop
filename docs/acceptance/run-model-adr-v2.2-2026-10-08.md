# Run 模型（ADR v2.2）验收记录（2026-10-08）

范围：Architecture Decision v2.2 第 3–9 条在 Runtime 的落地——Delegated / Durable 两类 Run、三维状态、全局停止、所有权提升拒绝、统一 Run 列表；以及顺带修复的持久化缺陷。

## 自动化测试

`swift test`：349 项全部通过，退出码 0。新增 RuntimeRunModelTests（Runtime 层的 ADR 回归）：

| ADR | 测试 | 断言 |
| --- | --- | --- |
| ADR-01 | adr01_aDelegatedRunCarriesItsOwnerAndActs | run.start 生成 agent_hub / external_client / connection_scoped，带 clientId、connectionId，可在 Run 内动作 |
| ADR-03 | adr03_controlConnectionLossBlocksNewInputAndStopsTheRun | 动作在途时控制连接断开：先 stopping/pending，新输入立即被拒；在途动作结束后 ended/confirmed/cancelled，原因 owner_lost |
| ADR-04 | adr04_reconnectingDoesNotResumeTheOldRun | 同一主体新连接：connectionId 变、clientId 不变；旧 Run 不能附着、不能动作，零输入 |
| ADR-05 | adr05_aClientCannotAskForPlatformOwnership | lifetime=platform_durable / ownership=platform / origin=gui_explorer 均 ownership_escalation_denied，且未创建 Run；Runtime 内部也不能为 agent_hub 建 durable Run |
| ADR-06/07 | adr06_07_aDurableRunOutlivesConnectionsAndReadsTheSameFromANewOne | 任意连接关闭不影响 Durable Run；新连接读到相同 runId、revision 与事件；仍持有 Desktop（客户端单次 act → control_busy） |
| ADR-08 | adr08_stoppingADurableRunIsAcceptedThenQuiescent | 停止先返回 stopping/pending，wait 超时；在途动作结束后 ended/confirmed/cancelled |
| ADR-09 | adr09_globalStopCoversBothKindsAndReopensForNewRunsOnly | stopAll 同时停止 Durable 与 Delegated，逐 Run 返回状态与 pending；停止中拒绝新 Run（input_disabled）和重新开放（stop_pending）；静止后 stopped，enableInput 后旧 Run 仍 ended，新 Run 可启动 |
| ADR-10 | adr10_anUnknownActionKeepsTheOutcomeUnknownWhateverStopsIt + 重启测试 | 有 unknown 动作时停止后 outcome 仍为 unknown；重启时有已投递未确认动作的 Durable Run 记为 ended/unknown，不重做 |
| — | oneShotActsEndWithTheirDeliveryAsOutcome | 单次 act 的 Run：投递成功 success、投递前拒绝 failed、投递不明 unknown |
| — | runListFiltersPagesAndShowsOnlyOwnRunsToAClient | 两类 Run 同一列表、按 origin 筛选、游标分页；配对客户端只能看到自己的 Run，不能全局停止 |
| — | thePersistentRuntimeKeepsRunsAcrossARestart | 产品组装函数把账本和 Run 写到 0600 文件；重建后 Run 仍在且被标为 runtime_restarted |

ADR-02（关闭 AgentHub 页面）需要主窗口，界面线完成后补测；Runtime 层由 ADR-06/07 覆盖（关闭任意连接不影响 Run）。

## 真机结果（测试副本，计算器）

| 用例 | 结果 |
| --- | --- |
| 单次 act | Run 为 agent_hub / connection_scoped / ended/success / confirmed |
| exec Run 进行中执行 `runtime stop-all` | Run 立即 ended/cancelled，原因 global_stop；此后 act 返回 input_disabled（notSent）；状态 inputAdmission=stopped |
| `runtime enable-input` | 恢复 enabled；旧 exec Run 仍为 ended，不恢复；新 act 正常投递 |
| 原始协议请求 lifetime=platform_durable / ownership=platform / origin=gui_explorer | 三者均 ownership_escalation_denied |
| exec 外壳 `kill -9` | Run ended/cancelled，原因 owner_lost |
| exec Run 进行中 `kill -9` 宿主，再启动 | Run 记录仍在，ended/cancelled，原因 runtime_restarted；`runs.sqlite`、`requests.sqlite` 均 0600 |

## 本次发现并修复的缺陷

PR2-2（#25）起宿主只给请求账本配了文件路径，RunStore 用的是内存实现：产品中的 Run 记录与事件不落盘，重启恢复虽有单元测试但未生效。现在宿主统一经 `RuntimeService.persistent(records:)` 组装，并有测试覆盖。

## 其他发现（交给 AI/GUI 线）

`ai.sqlite`（AgentDesktopService 的配置库）权限为 0644。记录目录本身是 0700，其他用户无法访问，但建议与其他库一致改为 0600。

## 留给后续

- Durable Run 目前只能由 Runtime 内部创建（`ExecutionCoordinator.startDurable`）；GUI Explorer 的运行在 PR2（统一端点与协议）中并入 RunStore 后才真正以 Durable Run 运行。
- 外部 Agent 失联检测窗口与心跳随身份与授权（PR3）一起做；目前控制连接 EOF 即视为失效。
- MCP `run_list` 工具与 SDK 字段随 PR3（#29）rebase 一并更新。
