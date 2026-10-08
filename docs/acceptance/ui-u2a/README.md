# U2a Desktops 可用部分：验收记录（2026-10-08）

基线：`origin/ai-gui-foundation@d8c27c5`；第二轮（实时预览改走 ScreenCaptureKit）以 `main` 为目标。

## 第二轮：实时预览改走 ScreenCaptureKit（D48）

Kevin 2026-10-08 裁决：实时预览不能用 `observe`。`observe` 每次都写一个 PNG 产物和它的 sidecar，每 3 秒一次就是每个预览每天约 2.8 万个文件；`observe` 只用于 Agent 观察与执行取证。冻结的 runtime/1 契约不改。

改动：

- 新的画面来源 `DesktopFrameHub`（`Sources/AgentDesktopUI/Pages/DesktopFrames.swift`）：按 Desktop 的 `screen.displayId` 每个显示器一路流，详情、并排、总览卡片、独立预览窗口共用；第一个可见的使用者出现时开始，最后一个离开时停止。使用者按窗口分组（主窗口一组，每个预览窗口一组）：窗口关闭、隐藏、最小化或被完全遮挡时这一组暂停；预览窗口关闭时这一组全部释放；Desktop 被销毁后它的显示器不再被捕获，预览窗口自动关闭；应用退出时全部停止。
- 真实来源 `ScreenCaptureFrameSource`（`Sources/AgentDesktopUI/Pages/ScreenCaptureFrameSource.swift`）：ScreenCaptureKit，每秒最多 4 帧，宽度最多 1600 像素（由捕获本身缩放），每帧从 IOSurface 复制成 CGImage 后立即归还；内存里每个显示器只留最新一帧，等待主线程的最多一帧；**任何帧都不写盘**。
- 预览路径上不再调用 `observe` 和 `artifact.read`；`DesktopFrameLoader` 已删除。实时帧没有 snapshotId，界面不再显示「画面 ID」，也不编造。
- 没有屏幕录制权限显示「需要屏幕录制权限」和去哪里打开；捕获失败显示「画面暂不可用」和原因；都不显示示例图。失败后不自动反复重试，用户点「重试」才再开始。
- 宿主：`MainWindowController(store:frames:)` 必须显式给出画面来源（应用给 ScreenCaptureKit，测试给假来源），主窗口显示前不开始捕获；预览窗口关闭时立即释放。
- 窗口绑定的 Desktop 现在显示整个 Desktop 显示器，不再只截绑定的窗口。

### 第二轮测试

| 命令 | 退出码 | 结果 |
| --- | --- | --- |
| `swift build --build-tests` | 0 | — |
| `swift test --skip-build` | 0 | 484 项通过；跳过的是原有的真实模型用例 |
| `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test --skip-build` | 0 | 484 项通过 |
| 与 `origin/main@dfdfb96` 试合并后 `swift test --skip-build` | 0 | 714 项通过 |
| 试合并后 `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test --skip-build` | 第 1 次 1，第 2 次 0 | 第 1 次 `SingleEndpointTests` 两项在整套负载下等 Runtime 回复超时（13.5 秒），单独重跑 7 项全过，整套第 2 次 714 项全过；这组测试本 PR 没有改动 |

测试都只用假来源，没有启动真实捕获、没有建屏幕上的窗口或虚拟显示器。

| 测试 | 断言 |
| --- | --- |
| `DesktopLiveFrameTests.livePreviewNeverObserves` | 40 轮 Store 刷新、反复渲染总览 / 并排 / 详情 / 预览窗口，`observe` 和 `artifact.read` 调用次数都是 0 |
| `DesktopLiveFrameTests.streamLifecycle` | 打开详情 1 路；再开并排和同一 Desktop 的预览窗口仍是 1 路；全部关闭 0 路且最后一帧释放；两个 Desktop 2 路；主窗口隐藏时暂停并保留最后一帧，再显示恢复；预览窗口被遮挡只暂停它自己；Desktop 被销毁后它的流停止、预览关闭；未解除就被释放的使用者自动归还；退出时全部停止 |
| `DesktopLiveFrameTests.onlyTheLatestFrameIsRetained` | 推 121 帧后，之前的帧都已释放，内存里只有 1 帧；最后一个使用者离开后 0 帧 |
| `DesktopLiveFrameTests.permissionAndFailureStates` | 无权限显示「需要屏幕录制权限」，没有画面，第二个使用者不会再次触发捕获；重试后重新开始；运行中失败显示「画面暂不可用」并保留最后一帧；没有画面来源或没有 displayId 时显示「画面暂不可用」 |
| `DesktopsU2aTests.uc49_zoomNeverRestartsTheCapture` | 四种缩放都不重启捕获，不调用 Runtime（替换原来基于 observe 的 UC49 测试） |
| `MainWindowHostTests.closingAPreviewWindowKeepsTheDesktop`、`previewOfADesktopDestroyedWhileDisconnectedCloses` | 宿主里关闭预览窗口后流停止；断线期间被销毁的 Desktop 重连后不再被捕获 |

### 真机验收：未运行（待做）

ScreenCaptureKit 的真机验收**没有运行，不算通过**，由主会话另行在测试副本上做：需要确认屏幕录制权限的提示与状态文字、实际帧率与 CPU / 内存占用、窗口遮挡 / 最小化 / 关闭时流确实停止、Desktop 销毁后流停止，以及运行期间 Runtime 的产物目录不再因为预览而增长。下面第一轮的真机截图是改动前（observe 版）的界面，其中的「画面 ID」和「每 N 秒观察一次」已不再适用。

## 第一轮（observe 版，已被第二轮取代的部分见上）

## 测试

| 命令 | 退出码 | 结果 |
| --- | --- | --- |
| `swift build` | 0 | — |
| `swift test`（全量，第 1 次） | 0 | 481 项通过；跳过 1 项，是原有的真实模型用例 |
| `swift test`（全量，第 2 次） | 0 | 481 项通过；跳过同上 |

两次都通过，没有偶发失败。

新增 `AgentDesktopUITests/DesktopsU2aTests`（8 项）和 `MainWindowHostTests.closingAPreviewWindowKeepsTheDesktop`（1 项）；`MockRuntimeTests.answersStayInsideTheContract` 扩到新加的 7 个 Mock 方法。

| UC | 测试 | 断言 |
| --- | --- | --- |
| UC03 | `uc03_nameIsRequired` | 名称为空时原位报「请填写名称」，没有发出 `desktop.create`；启动 / 绑定方式缺选择时各自报错 |
| UC04 | `uc04to06_uc52_createEmpty` | `desktop.create` 在途时步骤状态为「进行中」，界面不显示百分比 |
| UC05 | 同上 | 新的 desktopId 在 `desktop.list` 里出现且只出现一次，不同于已有的 Desktop |
| UC06 | 同上 | 新 Desktop 显示「等待接入」 |
| UC52 | 同上 | 空 Desktop 的 binding 为 null，没有调用 `app.launch` 或 `window.bind` |
| P05 失败与重试 | `failedStepRetriesAlone` | 失败的步骤保留错误码；重试只重做失败的那一步，Desktop 不会建两次，应用不会启动两次 |
| 三种方式 | `createWithSizeLaunchAndBind` | 高级尺寸；启动（bundleId 或 .app 路径）后绑定它的窗口；绑定已有窗口 |
| UC49 | `uc49_framesAndZoom`（第二轮已改为 `uc49_zoomNeverRestartsTheCapture`） | 第一轮：画面来自 `observe` 加 `artifact.read`；四种缩放都不再触发 observe，snapshotId 不变 |
| UC14 | `uc14_closingAPreviewKeepsTheDesktop`、`closingAPreviewWindowKeepsTheDesktop` | 隐藏或关闭预览不调用任何 Runtime 方法，Desktop 不变；宿主里关闭预览窗口只移除这个窗口 |
| UC16 | `uc16_closedDesktopDisappears` | Desktop 在别处被关闭后，总览不再显示它，详情显示「已不存在」，它的预览自动关闭 |
| UC19–UC21 | `uc19to21_searchFilterLayout` | 搜索有结果 / 无结果；清除筛选后恢复列表；网格与列表都能渲染；并排视图 |

## 真实界面（测试副本 + 自写中立探针）

**没有启动任何用户或系统应用。** 被操作的应用是自写的探针（源码 [probe-main.swift](probe-main.swift)）：一个带输入框的窗口，只记录收到的按键。它从 `/tmp/adt-u2a/probe-target.json` 读取目标显示器的编号和坐标，只有窗口完全落在那个虚拟显示器上才显示，否则不建窗口直接退出。

环境：

- 副本 B（`/tmp/adt-u2a/b.sock`）建两个 Desktop：ui-host（1440×1000，放 A 的主窗口）和 probe-home（探针出生的地方）。
- 副本 A（`/tmp/adt-u2a/a.sock`）显示主窗口，`AGENTDESKTOP_MAIN_WINDOW_DISPLAY` 指向 ui-host。
- A 主窗口里的操作都由 B 发出：`window bind`、`observe`、`act click` / `act type`。
- 截图只用 `screencapture -l <窗口ID>`，只截 A 的主窗口或预览窗口。

| 图 | 内容 |
| --- | --- |
| [real-p03-empty](real-p03-empty.jpg) | P03 没有 Desktop |
| [real-p04-name-required](real-p04-name-required.jpg) | P04 名称为空，原位提示（UC03） |
| [real-p04-launch](real-p04-launch.jpg) | P04 启动应用（探针的 .app 路径） |
| [real-p05-launching](real-p05-launching.jpg) | P05 创建中：「创建 Desktop」进行中，下一步等待（UC04） |
| [real-p05-bind-done](real-p05-bind-done.jpg) | P05 绑定已有窗口：两步完成，新的 desktopId（UC05） |
| [real-p05-launch-done](real-p05-launch-done.jpg) | P05 启动应用并绑定它的窗口：完成 |
| [real-p05-failed](real-p05-failed.jpg)、[real-p05-retry-failed](real-p05-retry-failed.jpg) | P05 启动不存在的 .app：失败，保留错误，重试只重做这一步，没有启动任何程序 |
| [real-p01-grid](real-p01-grid.jpg)、[real-p01-list](real-p01-list.jpg) | P01 网格 / 列表（UC21）；卡片画面来自 observe |
| [real-uc19-no-result](real-uc19-no-result.jpg)、[real-uc20-cleared](real-uc20-cleared.jpg) | 搜索无结果、清除筛选（UC19、UC20） |
| [real-p06-detail](real-p06-detail.jpg) | P06 详情：绑定窗口的实时画面（observe），控制者条，连接面板；停止 / 关闭禁用 |
| [real-p06-empty-desktop](real-p06-empty-desktop.jpg) | 空 Desktop 详情：等待接入，没有示例应用（UC06、UC52） |
| [real-p06-observe-error](real-p06-observe-error.jpg) | Runtime 拒绝观察时的显示（见下方发现 2） |
| [real-uc49-zoom-200](real-uc49-zoom-200.jpg) | 缩放切到 200%：点击前后读到的画面 ID 都是 `obs_8a11e7beab29`（UC49）。这个窗口高 775，画面 ID 那一行在滚动区下方，数值取自同一时刻的界面读数 |
| [real-p07-side-by-side](real-p07-side-by-side.jpg) | P07 并排：每个 Desktop 有自己的画面；停止显示「等待 A5」 |
| [real-p08-preview](real-p08-preview.jpg) | P08 独立预览窗口：尺寸、scale 2x、画面 ID |
| [real-uc16-after-close](real-uc16-after-close.jpg) | 用 CLI 销毁「失败示例」后，总览里不再出现它（UC16） |

UC14 真机：在预览窗口里点「隐藏预览」，窗口消失；前后两次 `desktop list` 完全一致。

### 是否触及用户屏幕

没有。每次启动探针前后都用 `CGWindowList` 核对它的窗口位置，始终在副本的虚拟显示器（12、22、23 号等）上；主显示器（3 号）上没有出现任何探针或测试副本的窗口。没有出现「refused to move its window」。

结束时：结束探针，销毁 A 和 B 的全部 Desktop，结束两个副本，用 `lsregister -u` 注销探针，删除 `/tmp/adt-u2a`。用 `ps` 和显示器列表核对，没有残留进程，只剩用户自己的显示器。

### 发现（交给 L-Runtime，本 PR 不修）

1. **显示器重排后，Desktop 的屏幕坐标是旧的。** 测试过程中有一个不属于本测试的显示器（10 号，525×800）被移除，所有虚拟显示器整体左移了 525 点。Runtime 的 `Desktop.screen.frame` 没有更新（仍是 5165，实际 4640），绑定窗口的截图因此截到了别的区域（壁纸）。见 [finding-stale-screen-frame](finding-stale-screen-frame.jpg)：界面如实显示了 Runtime 返回的图。之后重建了 Desktop，验收截图都在重建之后拍。
2. **observe 偶尔返回 `execution_failed`**：「macOS gave this screen the same unit number as another display」。这是引擎的保护措施，界面显示「画面没有更新：执行失败」，可以重试，不会伪造画面。
3. 没有绑定窗口的 Desktop 截的是整个虚拟屏幕，会带上系统菜单栏（显示当前前台应用的菜单名）。

## Wireframes 对照

| 页面 | 设计 | 已实现 | 差异与原因 |
| --- | --- | --- | --- |
| 总览 | P01 | 卡片（名称、desktopId、实时画面、控制状态、控制者、动作数）；全部 / 操作中 / 空闲；搜索；网格 / 列表；打开预览；进详情 | 卡片画面与详情共用同一路 ScreenCaptureKit 流，不显示画面 ID；控制者来自运行记录（`Desktop.control` 属 A5）；停止禁用（A5） |
| 空状态 | P03 | 「还没有 Desktop」加创建入口 | 没有「Agent 接入说明」入口（U4） |
| 创建 | P04 | 名称原位校验；空 / 启动应用 / 绑定已有窗口；高级尺寸默认收起 | 主窗口内的模态，不是独立窗口：用户和辅助功能看到的都是同一个窗口；「启动应用」接受 bundleId 或 .app 路径，以新实例启动 |
| 创建中 | P05 | 逐步显示 Runtime 每一步的真实结果；失败保留错误码；重试只重做失败的步骤 | 错误只显示错误码和通用说明，不显示 Runtime 原文（原文可能带参数值） |
| 详情 | P06 | 实时画面（ScreenCaptureKit，每秒最多 4 帧，不写盘），显示尺寸、scale、状态；缩放；独立预览；连接面板 | 停止、接管、关闭禁用并写明「等待 A5」；没有导出截图与 trace（U5b） |
| 并排 | P07 | 每个 Desktop 一个面板，各自的实时画面；详情、独立预览 | 停止禁用（A5） |
| 独立预览 | P08 | 每个 desktopId 一个窗口；缩放；打开详情；隐藏预览只关窗口；Desktop 被关闭后显示「已不存在」并自动关闭 | 停止禁用（A5）；窗口不可见时画面暂停 |
