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

### 再一轮交替对照（main `de99f69` 对 #137 `0845f9e`，各 4 轮，负载 4–6）

| 轮次 | main | #137 |
| --- | --- | --- |
| 1 | 退出码 1：`SingleEndpointTests.aKeyReusedForOtherParamsOrAnotherMethodIsRefusedAndRunsNothing`、`aiMethodsAnswerOnTheRuntimeEndpointInRuntimeTerms` | 退出码 1：同样这两项 |
| 2 | 0 | 0 |
| 3 | 0 | 0 |
| 4 | 0 | 0 |

两边在同一轮、同两项上失败，失败率相同（各 1/4）。在此之前，#137 `0845f9e` 单独跑的两轮里也有一轮是这两项失败。这两项单独运行（`--filter SingleEndpointTests`）在 strict 下连续 3 次通过。原因是协作线程池被并行运行的其他测试占满时，AI 服务的异步应答超时，属于 main 上已有的偶发问题。

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

- 合入 main `de99f69` 之后：#137 在 strict 下 9 轮中 7 轮通过，失败的 2 轮都只有 SingleEndpoint 那两项。main 在同期交替运行中出现了同样的失败，失败率相同。`swift test` 961 项通过。
- engine 的本机崩溃在 main 上同样稳定出现，与 A4 无关，需要 #151 的负责方排查。CI 上通过。
- 原始日志保存在本次会话的 scratchpad（`baseline/`）里，未放进仓库。复现方式见上面的命令。

## 4. 最终 head 对照（main `14fbccb` 对 #137 `01eb2e7` 及修复后的工作区，2026-10-09 21:30–22:10）

命令同上，main 用 `14fbccb` 的独立 worktree，与 #137 交替运行，每轮记录负载（2.9–14）。原始日志在会话 scratchpad 的 `base2/` 目录。

### engine，各 2 轮

| 轮次 | main | #137 |
| --- | --- | --- |
| 1 | 退出码 0，356 项通过 | 退出码 0，356 项通过 |
| 2 | 退出码 0，356 项通过 | 退出码 0，356 项通过 |

之前本机的 signal 11 崩溃在 main 合入的后续修复之后已不再出现，engine 两边一致通过。

### strict，main 15 轮，#137 15 轮

| 版本 | 失败轮数 | 失败用例（每次失败都是这一组，没有别的用例） |
| --- | --- | --- |
| main `14fbccb` | 4 / 15（第 4、5、9、11 轮） | `SingleEndpointTests.aiMethodsAnswerOnTheRuntimeEndpointInRuntimeTerms`、`aKeyReusedForOtherParamsOrAnotherMethodIsRefusedAndRunsNothing`、参数化用例（`SingleEndpointTests.swift:159`，`connection_lost` ≠ `not_found`） |
| #137 `01eb2e7`（第 1–9 轮） | 5 / 9 | 同一组 |
| #137 加上下面的测试修复（第 10–15 轮） | 2 / 6 | 同一组 |

**失败机制**（在 main 的代码里，A4 没有改动）：`RuntimeBridge.answer` 在服务端连接线程上用 `Task.detached` 把请求交给 AI 服务，再用信号量等待结果。这个 Task 必须拿到协作线程池里的一个线程才能运行。在 strict 模式下，其他测试套件占满线程池时它排不上，客户端超时，报 `connection_lost`（失败用例的耗时约 16 秒）。同一轮里，几十个测试都在 15 秒左右才完成，说明是整个测试进程的异步任务都在排队，无法归结到某一个测试。

**A4 的影响**：A4 给每个 socket 连接增加了凭据握手和代码身份核验，这些都在连接线程上执行，不占线程池。但测试里在线程池上同步发起 socket 调用的地方，因此会占用池子更久。找到的一处是 `RuntimeServerTests.concurrentClientsAreServedIndependently`：它用 16 个协作线程同时发起同步调用。这个测试是 main 原有的，A4 已把它改为每个客户端使用自己的普通线程。修复前后，#137 与 main 的失败率差距（5/9、2/6 对 4/15）在这个样本量下不显著（合计 7/15 对 4/15，单侧 Fisher 检验 p ≈ 0.22），但我**不把它判为「已通过」**：

- 本 PR 只能证明，失败用例与 main 完全相同，机制也在 main 的代码里。#137 没有引入新的失败用例。
- 失败率是否被 A4 抬高，现有样本无法排除。
- 根治需要改 `RuntimeBridge`（不在 A4 范围内）：AI 应答不应依赖协作线程池能否及时调度。已开 #195 跟踪。

非 strict 的完整 `swift test`：#137 1051 项通过（退出码 0）。
