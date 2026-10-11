# UI-B：U3 Desktop 控制（P12–P18）与 U2b 补齐 —— 组件验收记录（2026-10-11）

基线：`origin/ui-lane-seams@dd7efe9`（PR #260）。分支 `ui-b-desktop-control`。

**本记录只到组件验收。** 所有结论来自 Mock Runtime（A5 方法按 `RuntimeService+Control.swift` / `+Close.swift` 的回答方式建模，参数与结果都经契约校验）和离屏渲染。**页面验收待做**：没有接真实 Runtime 测试副本、没有打开真实窗口、没有做交互验证（02 §2.2）。

## 范围

| 页面 | 交付 | Runtime 方法 |
| --- | --- | --- |
| P06 详情 · 控制信息 | 连接面板显示控制状态、控制者、客户端、传输方式、动作次数、开始时间、控制运行；来源标「来自 Desktop.control」 | `desktop.list`（`Desktop.control`） |
| P12 接管确认 | 「停止并接管」；stop_pending、superseded 按 Runtime 原话显示 | `desktop.takeover` |
| P13 人工控制中 | 横幅「你正在控制这个 Desktop」+「交还控制」；说明外部动作被拒（control_busy） | `desktop.handback` |
| P14 停止中 | 「停止已受理，等待静止」，停止按钮置灰 | `desktop.stop`、`run.show` |
| P15 已停止 | 只有 `quiescence = confirmed` 或 `control.state = stopped` 才显示「已停止」 | 同上 |
| P16 连接断开 | 横幅 + 「清除并重新开放」（handback） | `desktop.handback` |
| P17 结果未知 | 先「重新观察」才开放「结束连接并保留记录」；不改原回执；结束后 Run 仍是 unknown；无重试按钮 | `observe`、`artifact.read`、`desktop.handback`、`run.show` |
| P18 关闭确认 | 关闭计划：将释放 / 将退出（本 Desktop 启动的） / 应用处理（宿主共享应用不退出） / 将保留 / 阻止关闭；被运行阻止时先「先停止输入」，静止后重读计划，`canClose` 才可关闭 | `desktop.closePlan`、`desktop.stop`、`desktop.destroy` |
| 应用与尺寸 | 退出本 Desktop 启动的应用（exited=false 显示「已请求退出，尚未确认」）；调整虚拟 Desktop 尺寸并说明旧观察失效 | `app.quit`、`desktop.resize` |
| U2b | 见下方清单 | — |

## 规则如何落实

- 接管先进入 stopping：接管请求先停 Agent 的运行；在途动作未完成时 Runtime 回答 `stop_pending`，界面显示「接管已受理，Agent 仍在结束在途动作」，不显示「由你控制」；静止后「再次接管」才是新的请求。
- 接管后外部动作被拒：Mock 在 manual 时拒绝 Agent 新运行（`control_busy`，reason `manual_control`），P13 横幅写明。
- 交还不重放：显示 `observationsCleared`，并说明 Agent 需重新观察；测试断言交还不新建 Run、旧 Run 不恢复。
- 关闭不结束宿主共享应用：关闭计划把 `keep` 单列为「归还宿主共享窗口，不退出应用」，`quit` 只列本 Desktop 启动的进程。
- 「已受理」与「已静止」分开：`DesktopControlFlow.StopProgress` 有 `accepted` / `quiescent` 两态；没有静止证据不显示「已停止」。
- superseded / stop_pending 原样展示：显示 Runtime 的错误码与 message 原文。
- 关闭页面不影响运行（ADR-02）：控制模型释放时不发任何调用（测试）。
- Runtime 不提供某个 A5 方法时（`runtime.capabilities` 没列），对应按钮置灰并写明「当前 Runtime 不提供 …」。

## U2b 清单（对照 10 文件 U2/U2b 与 06）

| 项 | 状态 |
| --- | --- |
| `Desktop.control` 缺失时的降级：控制者来自运行记录，详情页横幅说明「Runtime 没有返回 Desktop.control …」 | 完成 |
| 创建中：保留请求在途时的步骤显示（U2a）；`control.state = creating` 显示「创建中」、停止与接管不可用；`error` 显示「出错」 | 完成（creating/error 在契约里是保留值，Runtime 目前不发） |
| 总览卡片、列表行、并排、独立预览窗口的「停止」接 `desktop.stop`（原来写「等待 A5」并禁用）；每个 Desktop 各自一个停止模型，停 A 不影响 B | 完成 |
| 删除所有「等待 A5」占位文案 | 完成 |
| 详情页「隐藏预览 / 显示预览」（只释放画面，不动控制与运行，UC14） | 完成 |
| 尺寸菜单（`desktop.resize`） | 完成（在「应用与尺寸」面板） |
| 传输方式（cli / mcp / sdk / ui） | 未完成：runtime/1 的 `Desktop.control` 和 `hub.connections.list` 都没有该字段（methods.json plannedFields 列为 `control.transport`）；界面显示「Runtime 未提供」。见契约请求 |
| 观察者数量（线框「观察者 1 个 · 当前预览」） | 未做：契约没有对应字段 |
| P16「检查连接」（只读连接检查） | 未做：属 Agents 线（`hub.connections.list`，F1-07）；本页用 handback 清除断开状态 |
| P17 核实记录（`run.reconcile`） | 未做：PR4 方法尚未进入目录；本页只做「重新观察 + 结束并保留 unknown」 |
| 窗口级采集（预览只显示绑定窗口） | 未做：Kevin 10-08 批准的过渡方案仍是整屏 + 标注，后续任务 |
| Desktop 级事件（F1-02） | 未做：契约缺口，Desktops 仍按 `desktop.list` 轮询 |
| `desktop.create` 一步 launch/bind、`hiDPI` | 未做：契约里仍是 planned |

## 离屏渲染与线框图对照（1440×1000，`SnapshotRenderer`，无屏幕窗口、无捕获）

渲染图在本目录，线框在 `docs/design/v2/Pxx.webp`。实时画面区域显示「画面暂不可用」，因为测试不接任何捕获源。

| 渲染图 | 线框 | 结论 |
| --- | --- | --- |
| `ui-b-P06-detail-control.jpg` | P06 | 结构一致；连接面板比线框多出客户端、传输方式、动作次数、开始时间、控制运行几行（任务要求） |
| `ui-b-P12-takeover-confirm.jpg` | P12 | 一致：控制者卡片、两段说明、「保留 Agent 控制 / 停止并接管」。遮罩只盖页面区域，线框盖整个窗口 |
| `ui-b-P12-takeover-stop-pending.jpg` | （无） | 线框没有这一态；按 Runtime 的 stop_pending 原话显示 |
| `ui-b-P13-manual.jpg` | P13 | 一致：琥珀横幅 +「交还控制」，徽章「由你控制」，连接面板「你（人工控制）」 |
| `ui-b-P14-stopping.jpg` | P14 | 一致：横幅「正在停止输入」、停止按钮置灰、徽章「正在停止」；多一条停止回执（已受理） |
| `ui-b-P15-stopped.jpg` | P15 | 一致：「输入已停止，Desktop 保留」；线框的按钮叫「重新连接」，本页叫「重新开放输入」（实际调用 handback） |
| `ui-b-P16-disconnected.jpg` | P16 | 一致；线框按钮「检查连接」，本页为「清除并重新开放」（原因见 U2b 清单） |
| `ui-b-P17-unknown-review.jpg`、`-reobserved.jpg` | P17 | 一致：警示、截图、请求 / 结果 / 原始画面 / 重试、「重新观察」；结束按钮在观察前置灰 |
| `ui-b-P18-close-blocked.jpg`、`-ready.jpg` | P18 | 一致：当前状态、连接者、将释放、应用处理、将保留；另加「将退出」「阻止关闭」与「先停止输入」 |
| `ui-b-U2b-*.jpg` | P01、P06、P07 | 无 control 时标「来自运行记录」；有 control 时卡片显示「已停止」「创建中」，停止按钮按状态启用 |

## 测试

第一轮（4dc1360）：

| 命令 | 退出码 | 结果 |
| --- | --- | --- |
| `swift build --build-tests` | 0 | — |
| `swift test --skip-build` | 0 | 1388 项通过（7 个原有 known issue） |
| `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test --skip-build`（两次） | 1、1 | 两次都是 `SingleEndpointTests` 三项（`aiMethodsAnswer…`、`aKeyReused…`、`concurrentDuplicatesMakeOneWrite`）等 Runtime 回复超时；第二次另有 `InferenceTransportTests.sec006_redirectIsNotFollowed` 一次超时。两组单独在严格模式下重跑全部通过（7/7、14/14）。都不在本 PR 改动范围（Runtime / AI 测试），已知问题是 SingleEndpoint 的两项，这次多出一项同组测试 |

新测试：`DesktopControlU3Tests`（16 项：UC07–UC18、UC29–UC31、superseded、物理 Desktop、app.quit、resize、U2b 降级、缺方法置灰、ADR-02、每 Desktop 独立停止）、`DesktopControlRenderTests`（2 项，出 PNG；本目录存的是转成 JPEG 的同一批图）。`MockRuntimeTests.answersStayInsideTheContract` 补了本线 6 个方法，并把已入契约的 `control` 从 planned 名单移出（改为 `transport`、`lastActionAt`）。

第二轮（Codex 在 4dc1360 上的 2 个 P1、2 个 P2 修复后）：

| 命令 | 退出码 | 结果 |
| --- | --- | --- |
| `swift build --build-tests` | 0 | — |
| `swift test --skip-build` | 0 | 1393 项通过（7 个原有 known issue） |
| `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test --skip-build` | 1 | 只有已知的 `SingleEndpointTests` 两项超时（`aiMethodsAnswer…`、`aKeyReused…`） |

修复：关闭计划重读前先清空，读失败就不能关闭；关闭前再读一次计划，与所显示的不同就显示新计划、不关闭；P17 必须拿到可显示的新画面才开放结束；stop_pending 之后要等被停运行静止才能再次接管；关闭对话框的「先停止输入」「关闭 Desktop」按 `runtime.capabilities` 置灰。新增 `DesktopControlReviewFixTests`（4 项）与 `DesktopControlAnswerTests`（1 项，旧回答在状态变化后撤下）。渲染图已按修复后的代码重出。

第三轮（Codex 在 11595f9 上的 1 个 P1、2 个 P2 修复后）：

| 命令 | 退出码 | 结果 |
| --- | --- | --- |
| `swift build --build-tests` | 0 | — |
| `swift test --skip-build` | 0 | 1396 项通过（7 个原有 known issue） |
| `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test --skip-build` | 1 | 已知的 `SingleEndpointTests` 两项超时；另有 `AgentDesktopAIUITests.ui004_capabilityTest` 在整套负载下一次时序失败（取消前测试已完成），严格模式下单独重跑 3 次都通过，本 PR 没有改动它 |

修复：结果未知时停止和接管都不可用（提示「先核对上一个动作的结果」），只能经过 P17 核对；P17 的结束只对 Desktop.control 当前指向的那次运行有效；总览、并排、预览窗口每轮刷新都会撤下状态已经过去的「已停止」。新增 `DesktopControlReviewFixTests2`（3 项）。

第四轮（Codex 在 acd2591 上的 1 个 P1、2 个 P2 修复后，并已 merge `origin/main@36f84e9`，即 #260 合入后的 main）：

| 命令 | 退出码 | 结果 |
| --- | --- | --- |
| `swift build --build-tests` | 0 | — |
| `swift test --skip-build` | 0 | 1427 项通过（7 个原有 known issue） |
| `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test --skip-build` | 1 | 只有已知的 `SingleEndpointTests` 两项超时 |

修复：结果未知时「关闭」不可用；P17 按 Desktop.control 的 controllerRunId 直接读那次运行的事件来找结果未知的动作（不依赖 Store 截断的 200 条运行快照），找不到时显示原因；只有在 `desktop.handback` 回答 handedBack = true 后才显示「已结束」。新增 `DesktopControlReviewFixTests3`（3 项）。

注：第三轮之后机器负载很高（load 25–175），整套测试里曾出现 Runtime / WDA / UnitRun 测试超时，全部是本 PR 没改的文件；在严格模式下单独重跑都通过，本轮负载下降后也没有再出现。
