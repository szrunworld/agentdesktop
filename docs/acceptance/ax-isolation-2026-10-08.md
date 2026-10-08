# AX 隔离与有界（A3 · RT-23A/B）验收记录（2026-10-08）

来源：MAC-001 的观察超时排查（`docs/acceptance/mac-001-2026-10-08.md` 第一节的三条风险）与 Kevin 的要求：AX 整树加总时限（P0）、AX 异常不得阻塞其他 Desktop（P0）。

## 实现

**引擎（engine/，SecondScreenCore）**
- `AXSnapshot.capture(window, query, deadline:)`：
  - 遍历时每个节点前检查总截止时间，过时后不再读新节点，返回已读部分并标 `truncated = "deadline"`；
  - 节点数或深度超限时标 `"limits"`；
  - 单次 AX 查询的等待从 2 s 降到 1 s（应用元素和窗口根元素都设置）；
  - Web 内容的重读循环也受截止时间约束。
- `InputEngine.state(window, query, deadline:)`，回应里新增 `elementsTruncated`。
- `AgentRuntime.input` 改为 nonisolated，线程安全；`InputEngine` 标为 `@unchecked Sendable`（内部本来就有锁）。

**Runtime**
- `AXReader`：读元素只在专用线程上进行（线程名 `agentdesktop.ax.<desktopId>`），不在主线程，不在 Swift 协作线程池，也不在持有 Desktop 锁时进行。
  - 全局最多 4 个，每个 Desktop 同时最多 1 个。
  - 调用方只等到截止时间。超时的读取自己跑完；引擎过了截止时间就不再读新节点，所以很快结束。
  - 同一 Desktop 还有读取在跑时，新的观察不再排队，直接返回 busy。
- `EnginePlatform.elements` 在 AX 线程上直接调用引擎的 InputEngine，不再经过 `AgentRuntime.handle` 的 detached task，也就不会把不可中断的 AX 调用放到协作线程池上。
- observe 分三段：
  1. 持锁：做 G0 检查并截图；
  2. 不持锁：在 AX 线程上读元素，预算 5 s，有请求 deadline 时取两者较小值；
  3. 再持锁：复核绑定代次、叠放顺序和窗口位置，然后存档。
  第 1 段开始读之前，该 Desktop 的旧元素引用全部作废，避免引擎编号被替换期间按旧编号误操作。
- 降级而不是失败：观察结果新增 `coverage{screenshot, ax, axReason}`。
  - 遍历被截断 → `ax: partial`（reason deadline / limits）；
  - 超时 → `unavailable / deadline`；
  - 同一 Desktop 已有读取在跑 → `unavailable / busy`；
  - App 不响应辅助功能 → `unavailable / error`；
  以上情况截图都照常返回。缺辅助功能权限仍然报 `permission_denied`，因为需要用户处理。
- Desktop 锁的等待受请求 deadline 约束（没有 deadline 时最多 30 s）；等不到锁返回 `deadline_exceeded`，`notSent: true`，什么都不做。
- `wait`：同样不持锁读元素。**修正一个缺陷**：没读到元素（超时或 busy）时原来按“没有匹配”判定，`elementAbsent` 会被误判为满足；现在没读到就不做判定，继续等到超时。

## 自动化测试

`swift test`：380 项全部通过，退出码 0，连跑 3 次。`swift test --package-path engine`：127 项通过；其中一次 `AgentScreenAdmissionTests` 的时序用例在高负载下失败，与本改动无关，重跑两次都通过，基线上也通过。

新增 RuntimeAXIsolationTests：

| 测试 | 断言 |
| --- | --- |
| aStuckReadReturnsTheScreenshotWithoutElementsInTime | 读取卡住：observe 在预算内返回，有截图、没有元素，coverage 为 unavailable/deadline；旧元素引用被拒；同一 Desktop 上按图像坐标的点击照常执行，说明锁没有被读取占住 |
| twentyTimeoutsInARowStayBoundedAndOthersKeepWorking | 连续 20 次超时：每次都在 1 s 内返回；runtime.status 都在 0.5 s 内返回；该 Desktop 同时最多 1 个读取（峰值 1）；第 1 次为 deadline，之后都是 busy；读取只发生在 `agentdesktop.ax.*` 线程；App 恢复后重新读到完整元素 |
| aStuckReadOnOneDesktopDoesNotDelayAnother | Desktop A 卡住时，Desktop B 的观察照常返回 |
| aTruncatedWalkIsPartial | 截断的遍历标为 partial/limits，已读元素照常返回 |
| waitingForABusyDesktopEndsAtTheDeadlineAndSendsNothing | Desktop 锁被占住时，act 在 deadline 返回 deadline_exceeded，notSent，perform 次数为 0 |
| anAppThatDoesNotAnswerAccessibilityStillHasItsScreenshot | App 不响应辅助功能时降级为 unavailable/error 并保留截图；缺权限时仍报 permission_denied |

## 真机（测试副本 /tmp/adt-ax，自写探针 App，30 个按钮）

| 步骤 | 结果 |
| --- | --- |
| 冻结前 observe | 32 个元素，coverage complete，1.3 s |
| `kill -STOP` 冻结探针后连续 observe 20 次 | 每次都有截图，coverage `unavailable / error`（冻结的 App 连窗口都不交给辅助功能），耗时 2.1–5.5 s，都在预算内 |
| 每次 observe 之后的 `runtime status` | 0.02–0.28 s |
| 每次之后在另一个 Desktop 做只截图的 observe | 0.44–1.02 s，全部成功 |
| 宿主线程数 | 20 次期间稳定在 10–11 |
| `kill -CONT` 恢复后 observe | 32 个元素，complete，0.79 s，不需要重启 |

修正前的同一场景（同一构建去掉降级，13:58）：冻结期间每次 observe 返回 `execution_failed` 且没有截图。这正是本次改为降级的原因。

清理：恢复并结束探针，销毁两个 Desktop，停止测试副本，删除 /tmp/adt-ax。

## 不在本 PR

- 没有做真正可中断的 AX：底层调用仍不可中断，只能靠单次查询 1 s、隔离线程和数量上限来约束。
- `coverage.ocr` 暂不提供。
