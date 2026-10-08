# U8 菜单栏与退出：验收记录（2026-10-08）

本分支直接基于 main，不依赖 U2a（#98）。在 #98 的独立预览窗口合入之前，菜单栏里每个 Desktop 的入口改为在主窗口打开该 Desktop 的详情；#98 合入时再接回预览窗口。

## 自动化测试

| 命令 | 退出码 | 结果 |
| --- | --- | --- |
| `swift build --build-tests` | 0 | — |
| 全量 `swift test`（基于 main fa2222f，2026-10-08 重启后） | 0 | 480 项通过 |
| 全量 `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test` | 0 | 480 项通过 |

新增测试：

| UC | 测试 | 断言 |
| --- | --- | --- |
| UC51 | `QuitFlowTests.uc51_quitWaitsForQuiescence` | `runtime.stopAll` 受理后，两个 Run 都还是 stopping/pending，退出流程停在「等待」；一个静止后还在等；两个都 ended + confirmed 才进入 quiet；`stopAll` 只调用一次 |
| UC51 | `nothingRunningIsQuietAtOnce`、`cancelWhileStopping`、`stopFailureCanBeRetried` | 没有运行时立即可退出；取消后输入保持停止，不调用 `enableInput`；`stopAll` 失败可以重试 |
| UC50 / UC51 | `MainWindowHostTests.quitChoices` | 隐藏主窗口、保留后台、取消：都回答「不退出」，不调用 `runtime.stopAll`，运行不变；停止输入并退出：Run 只在停止中时不回答，全部静止后才回答「退出」 |
| P32 | `MainWindowHostTests.quitDialogDoesNotWaitForTheRuntime` | run.list 延迟 2 秒时退出对话框不等它：begin 1 秒内返回，运行数显示「正在读取」而不是 0，仍可取消 |
| UC51 | `MainWindowHostTests.aSecondQuitRequestWhileAskingDoesNotTerminate` | 对话框等待时再次请求退出不会调用 terminate，只把对话框调到前面；回答之后的下一次请求才会再次发起退出 |
| P31 | `panelStatusAndRenders`、`menuStatusLines` | 面板状态文字（正在连接 / 运行中 / 输入已停止）、摘要（含「N 个停止中」）；面板与退出对话框能渲染 |

## 严格协作线程池（LIBDISPATCH_COOPERATIVE_POOL_STRICT=1）

本次改动和新增的测试里没有 `DispatchSemaphore.wait`、`Thread.sleep`、`DispatchGroup.wait` 或其他阻塞式等待，等待全部是 async 加带超时的轮询。

单独按 suite 在严格模式下跑（每个限时 60 秒）：

| suite | 结果 |
| --- | --- |
| ActionResultTests、RunStatusTests、ProblemAndTokenTests、MockRuntimeTests、ShellStoreTests | 跑完，退出码 0 |
| StateBadgeTests（以及其他要建窗口或离屏渲染的 suite） | **卡住**。用 `sample` 采样：主线程停在 `NSHostingView.init` → `NSApplication.sharedApplication` → `SLSMainConnection` → `mach_msg`，即进程第一次连接 WindowServer 就没有回应。同一时刻，一个只调用 `CGGetActiveDisplayList` 的小程序也会一直卡住，所以这不是严格模式或测试代码本身的问题，而是本机环境的问题，见下文 |

`AgentDesktopUITests` 整体在严格模式下没有跑完（超过 5 分钟后手动结束），原因同上。机器重启、WindowServer 恢复后已全量重跑，见上表。

## 真机（测试副本，没有启动任何用户或系统应用）

| 图 | 内容 |
| --- | --- |
| [real-p31-panel](real-p31-panel.jpg) | P31 面板：状态「运行中」、2 个 Desktop · 2 个运行进行中、打开主界面、每个 Desktop 的预览入口、停止所有输入、设置、退出 |
| [real-p31-input-stopped](real-p31-input-stopped.jpg) | 确认停止所有输入后：状态「输入已停止」，两个 exec Run 变为 ended/cancelled/confirmed，出现「恢复输入」 |

**退出（P32 / UC51）没有完成真机验证。** 经过如下：

1. 点「恢复输入」，新起两个 exec Run，再点面板的「退出 Agent Desktop…」。
2. 测试副本 A 的进程随即消失：
   - 没有崩溃报告；
   - 两个 Run 在 A 的记录里还是 running/not_confirmed，说明不是走退出流程正常结束的；
   - 退出对话框没有出现。
3. 用新的副本 A 重试时，副本 B 的 `window bind`、`desktop create` 开始超时。这时本机多出两块不属于本测试的虚拟显示器（30、31 号，1440×900），我们的显示器被重排。
4. 结束副本 B 之后，新进程连接 WindowServer 一律卡住（见上面的严格模式一节）。之后 5 分钟内每 10 秒检查一次，都没有恢复。

我没有对 WindowServer 做任何操作。

### 原因（2026-10-08 重启后查系统日志确定）

副本 A（pid 11196）的系统日志：

| 时间 | 事件 |
| --- | --- |
| 17:31:22.254 | 第一次 `terminate:`；`applicationShouldTerminate` 按设计返回 `NSTerminateLater`，退出对话框随即显示 |
| 17:31:24.066 | 第二次 `terminate:`。AppKit 报错 `Unexpected call to terminate: while still determining whether to terminate. Will force immediate termination.`，不再询问代理，直接强制退出 |
| 17:31:24.067 | 两块虚拟显示器（28、29 号）被直接销毁，其余显示器重排 |
| 17:31:24.297 | `Termination complete`，进程退出，两个 Run 仍是 running/not_confirmed |

这是**本 PR 的缺陷**：退出对话框等待选择时，任何一次新的 `NSApp.terminate`（面板里的退出按钮、Dock 的「退出」、空闲退出定时器）都会被 AppKit 强制执行，绕过「停止所有输入、等运行静止」。

修复：
- 所有退出入口统一走 `QuitController.requestQuit()`。对话框在等待时，它只把对话框调到前面，不再调用 terminate。
- Dock 的退出 Apple 事件（kAEQuitApplication）也改由同一个入口处理。
- 回归测试 `aSecondQuitRequestWhileAskingDoesNotTerminate` 覆盖这一点。

**30、31 号显示器**（1440×900）是 `/Applications/2ndscreen.app`（pid 19953）在 17:31:48 和 17:31:57 创建的，与本测试无关，属于环境干扰。之后 WindowServer 停止接受新连接，发生在这些显示器反复增删之后。

**UC51 仍未真机通过。** 重做要求（Kevin 2026-10-08）：
- 不创建虚拟显示器；
- 不影响正在运行的 Agent；
- 使用独立测试副本；
- 覆盖 Runtime 正常、断连、无响应三种情况；
- 不能造成 WindowServer 卡死，不能绕过运行中任务的安全收尾。

### 是否触及用户屏幕

没有。主窗口、面板、预览窗口都在副本自己的虚拟显示器上；没有启动任何应用，没有窗口出现在主显示器（3 号）上。所有副本进程、exec 进程和 `/tmp/adt-u8` 都已清理。WindowServer 不接受新连接这件事，影响的是整台机器，已经在报告里单独提出。

## Wireframes 对照

| 页面 | 设计 | 已实现 | 差异与原因 |
| --- | --- | --- | --- |
| 菜单栏弹层 | P31 | NSPopover：运行状态与摘要、打开主界面、打开某个 Desktop 的预览、停止所有输入（两步确认）/ 恢复输入、设置、退出 | 原来菜单里的「测试副本」列表去掉了（P31 没有这一项）；测试副本没有菜单栏入口，验收时用 `AGENTDESKTOP_MENU_PANEL=1` 把同一个面板放在副本自己显示器上的窗口里 |
| 退出与后台 | P32 | 取消 / 隐藏主窗口 / 保留后台（关闭窗口、离开 Dock，只留菜单栏）/ 停止输入并退出（`runtime.stopAll` 后按 run.list 与 run.show 核对，全部 ended + confirmed 才退出，不强制） | 真机未完成，见上文 |
| 关窗转后台 | UC50 | 沿用 U1b-1：关闭主窗口只隐藏 | — |
