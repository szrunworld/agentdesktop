# A4 / #137 测试基线对照（strict pool 与 engine）

Kevin 2026-10-09 要求：strict 和 engine 的失败要有具体用例、main 基线对照和可复现证据，不能只说「main 也失败」。

## 环境与命令

- 机器：本机 macOS 15.1 arm64，10 核。期间有其他会话在跑测试，负载（load average）随时间变化，每一轮都记录了负载。
- strict：`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test --skip-build`（先执行 `swift build --build-tests`）
- engine：`swift test --package-path engine`
- 对照方式：main 与 #137 在同一台机器上**交替**运行（main 第 1 轮、#137 第 1 轮、main 第 2 轮……），尽量让两边处在相同负载下。

## 1. 受控对照（main `de99f69` 对 #137 `d8cf112`）

### strict，各 5 轮

| 轮次 | main 退出码 | 负载 | main 失败用例 | #137 退出码 | 负载 | #137 失败用例 |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 0 | 9.67 | — | 0 | 8.04 | — |
| 2 | 0 | 20.89 | — | 1 | 15.15 | `WDAClientTests.waiterIsBoundedByItsOwnDeadline` |
| 3 | 0 | 23.25 | — | 0 | 17.37 | — |
| 4 | 0 | 12.68 | — | 0 | 10.62 | — |
| 5 | 0 | 8.57 | — | 0 | 7.56 | — |

`#137` 唯一的失败是 WDA 的挂钟断言（期望 < 1 秒，实际 1.12 秒）。main 的 `de99f69` 正是「WDA: check deadlines by state and by request, not by the wall clock」（#160）的修复，当时 #137 还没有合入它。

### 合入 main `de99f69` 之后（#137 `1990180`），strict 各 3 轮

| 轮次 | 退出码 | 负载 | 失败用例 |
| --- | --- | --- | --- |
| 1 | 0 | 9.74 | — |
| 2 | 0 | 9.45 | — |
| 3 | 0 | 7.59 | — |

另外，完整的 `swift test`（非 strict）958 项通过。

### engine，各 3 轮（与 A4 无关：#137 的 `engine/` 与 main 完全一致）

| 轮次 | main | #137 |
| --- | --- | --- |
| 1 | 退出码 1，`Exited with unexpected signal code 11` | 退出码 1，signal 11 |
| 2 | 退出码 1，输出中途截断（无汇总行，同类崩溃） | 退出码 1，同左 |
| 3 | 退出码 1，同上 | 退出码 1，signal 11 |

- 崩溃发生在 engine 测试进程中，最后启动的是 `IPhoneMirroringTests` 的参数化用例（`classifiesStatusPagesInEnglishAndChinese`），以及 `showTwiceMakesOneScreen`、`hideTellsRequestedRefusedAndNotRunningApart` 等。
- 首次出现在 main `30b65f4`（#151 合入）之后；main `5237340`（#153 合入后、#151 合入前）在本机通过（228 项）。
- GitHub Actions 的 macOS 任务中，同一 engine 步骤通过（#137 的 CI 两项都是绿的）。所以这是本机可复现、CI 上不出现的问题，**不是 A4 引入的**。已在 #151 留言。

## 2. 之前各轮的观察（作为背景）

- 在高负载（load 20–44）下，main 与 #137 都曾在同一批时间敏感用例上偶发失败：`SingleEndpointTests.aiMethodsAnswerOnTheRuntimeEndpointInRuntimeTerms`、`aKeyReusedForOtherParamsOrAnotherMethodIsRefusedAndRunsNothing`（`connection_lost`，回复超时），`WDAClientTests.hangingActionTimesOutWithUnknownDelivery`、`geometryTimeoutKeepsTheDecodedScreenshot`、`waiterIsBoundedByItsOwnDeadline`，`unknownActionEndsTerminalAndIsNeverRetried`。
- #137 自身做过的改进：把所有会阻塞的测试（sleep、信号量、socket 读、等待子进程）移到普通线程上，不再占用协作线程池。其中包括 SDK 实机测试、确认与撤销的竞态测试、SEC-04/05 的 socket 测试。之后 SingleEndpoint 的偶发失败率回到与 main 相同的水平。

## 3. 结论

- 合入 main `de99f69` 之后，#137 的 strict 连续 3 轮通过，`swift test` 958 项通过。
- engine 的本机崩溃在 main 上同样稳定出现，与 A4 无关，需要 #151 的负责方排查。CI 上通过。
- 原始日志保存在本次会话的 scratchpad（`baseline/`）里，未放进仓库。复现方式见上面的命令。
