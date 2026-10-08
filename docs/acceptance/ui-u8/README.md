# U8 菜单栏与退出：验收记录（2026-10-08）

本分支叠在 U2a（#98）之上：菜单栏的「打开 Desktop 预览」要用 U2a 的预览窗口。

## 自动化测试

| 命令 | 退出码 | 结果 |
| --- | --- | --- |
| `swift build --build-tests` | 0 | — |
| `swift test --filter 'QuitFlowTests\|MainWindowHostTests'` | 0 | 12 项通过 |
| 本分支全量 `swift test` | **未跑完** | 跑之前，本机 WindowServer 已经不再接受新进程连接（见下文），任何建窗口或渲染的测试都会卡在连接 WindowServer 这一步 |

新增测试：

| UC | 测试 | 断言 |
| --- | --- | --- |
| UC51 | `QuitFlowTests.uc51_quitWaitsForQuiescence` | `runtime.stopAll` 受理后，两个 Run 都还是 stopping/pending，退出流程停在「等待」；一个静止后还在等；两个都 ended + confirmed 才进入 quiet；`stopAll` 只调用一次 |
| UC51 | `nothingRunningIsQuietAtOnce`、`cancelWhileStopping`、`stopFailureCanBeRetried` | 没有运行时立即可退出；取消后输入保持停止，不调用 `enableInput`；`stopAll` 失败可以重试 |
| UC50 / UC51 | `MainWindowHostTests.quitChoices` | 隐藏主窗口、保留后台、取消：都回答「不退出」，不调用 `runtime.stopAll`，运行不变；停止输入并退出：Run 只在停止中时不回答，全部静止后才回答「退出」 |
| P31 | `panelStatusAndRenders`、`menuStatusLines` | 面板状态文字（正在连接 / 运行中 / 输入已停止）、摘要（含「N 个停止中」）；面板与退出对话框能渲染 |

## 严格协作线程池（LIBDISPATCH_COOPERATIVE_POOL_STRICT=1）

本次改动和新增的测试里没有 `DispatchSemaphore.wait`、`Thread.sleep`、`DispatchGroup.wait` 或其他阻塞式等待，等待全部是 async 加带超时的轮询。

单独按 suite 在严格模式下跑（每个限时 60 秒）：

| suite | 结果 |
| --- | --- |
| ActionResultTests、RunStatusTests、ProblemAndTokenTests、MockRuntimeTests、ShellStoreTests | 跑完，退出码 0 |
| StateBadgeTests（以及其他要建窗口或离屏渲染的 suite） | **卡住**。用 `sample` 采样：主线程停在 `NSHostingView.init` → `NSApplication.sharedApplication` → `SLSMainConnection` → `mach_msg`，即进程第一次连接 WindowServer 就没有回应。同一时刻，一个只调用 `CGGetActiveDisplayList` 的小程序也会一直卡住，所以这不是严格模式或测试代码本身的问题，而是本机环境的问题，见下文 |

`AgentDesktopUITests` 整体在严格模式下没有跑完（超过 5 分钟后手动结束），原因同上。环境恢复后需要重跑。

## 真机（测试副本，没有启动任何用户或系统应用）

| 图 | 内容 |
| --- | --- |
| [real-p31-panel](real-p31-panel.jpg) | P31 面板：状态「运行中」、2 个 Desktop · 2 个运行进行中、打开主界面、每个 Desktop 的预览入口、停止所有输入、设置、退出 |
| [real-p31-open-preview](real-p31-open-preview.jpg) | 从面板打开「退出验证 A」的预览窗口 |
| [real-p31-input-stopped](real-p31-input-stopped.jpg) | 确认停止所有输入后：状态「输入已停止」，两个 exec Run 变为 ended/cancelled/confirmed，出现「恢复输入」 |

**退出（P32 / UC51）没有完成真机验证。** 经过如下：

1. 点「恢复输入」，新起两个 exec Run，再点面板的「退出 Agent Desktop…」。
2. 测试副本 A 的进程随即消失：
   - 没有崩溃报告；
   - 两个 Run 在 A 的记录里还是 running/not_confirmed，说明不是走退出流程正常结束的；
   - 退出对话框没有出现。
3. 用新的副本 A 重试时，副本 B 的 `window bind`、`desktop create` 开始超时。这时本机多出两块不属于本测试的虚拟显示器（30、31 号，1440×900），我们的显示器被重排。
4. 结束副本 B 之后，新进程连接 WindowServer 一律卡住（见上面的严格模式一节）。之后 5 分钟内每 10 秒检查一次，都没有恢复。

我没有对 WindowServer 做任何操作。A 为什么会退出，还没有定论：可能是本 PR 退出路径的缺陷，也可能是环境异常（不属于本测试的显示器变化、WindowServer 停止应答）。在复现之前，不能把 UC51 记为真机通过。

### 是否触及用户屏幕

没有。主窗口、面板、预览窗口都在副本自己的虚拟显示器上；没有启动任何应用，没有窗口出现在主显示器（3 号）上。所有副本进程、exec 进程和 `/tmp/adt-u8` 都已清理。WindowServer 不接受新连接这件事，影响的是整台机器，已经在报告里单独提出。

## Wireframes 对照

| 页面 | 设计 | 已实现 | 差异与原因 |
| --- | --- | --- | --- |
| 菜单栏弹层 | P31 | NSPopover：运行状态与摘要、打开主界面、打开某个 Desktop 的预览、停止所有输入（两步确认）/ 恢复输入、设置、退出 | 原来菜单里的「测试副本」列表去掉了（P31 没有这一项）；测试副本没有菜单栏入口，验收时用 `AGENTDESKTOP_MENU_PANEL=1` 把同一个面板放在副本自己显示器上的窗口里 |
| 退出与后台 | P32 | 取消 / 隐藏主窗口 / 保留后台（关闭窗口、离开 Dock，只留菜单栏）/ 停止输入并退出（`runtime.stopAll` 后按 run.list 与 run.show 核对，全部 ended + confirmed 才退出，不强制） | 真机未完成，见上文 |
| 关窗转后台 | UC50 | 沿用 U1b-1：关闭主窗口只隐藏 | — |
