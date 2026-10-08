# U1b-1 主窗口结构与页面接线：验收记录（2026-10-08）

基线：`origin/ai-gui-foundation@49d266f`（含 A0 #47、G0 #51、U1a #52、#57）。

## 测试

| 命令 | 退出码 | 结果 |
| --- | --- | --- |
| `swift build` | 0 | — |
| `swift test`（全量） | 0 | 421 项通过；跳过 1 项，是原有的真实模型用例（需要密钥） |

新增测试 17 项：

- `AgentDesktopUITests/MainWindowPagesTests`，11 项：
  - 导航；每个入口和每个选中状态都能渲染；
  - 总览的筛选与搜索；
  - 列表页四态；详情页状态；Run 详情读取（含增量事件、未发出原因、离线）；Desktop 最近动作；
  - 断开后重连；轮询唯一；每轮更新的 tick；
  - 全局停止只显示 Runtime 的回答。
- `AgentDesktopTests/MainWindowHostTests`，5 项：
  - 激活策略与测试副本窗口开关；
  - 进程内端口走 runtime/1（未握手被拒、以 owner 身份连接、只轮询）；
  - Runtime 启动失败时显示 Disconnected；
  - 关窗不影响 Run；
  - 菜单状态行。
- `RenderTests/mockPagesWithActions`，1 项。
- 另外改了原有 `AIGUI pages / renderSmoke`：改为渲染 Settings 下的 AI 页面，并检查 AIUI 源码里不再有 `NavigationSplitView`（T27 / D32）。

## 真实界面截图（测试副本，窗口截图）

做法：

1. 起两个测试副本，都在 `/tmp/adt-u1b` 下，不连产品 endpoint，不写登录钥匙串（副本用文件凭据）。
   - 副本 B（`AGENTDESKTOP_SOCKET=/tmp/adt-u1b/b.sock`）建一个 1440×1000 的 Desktop，只用来放窗口（displayId 24）。
   - 副本 A（`AGENTDESKTOP_SOCKET=/tmp/adt-u1b/a.sock AGENTDESKTOP_MAIN_WINDOW=1 AGENTDESKTOP_MAIN_WINDOW_DISPLAY=24`）显示主窗口。窗口放在 B 的虚拟显示器上，不激活、不抢焦点，不出现在用户屏幕上。
2. A 里用 CLI 建两个 Desktop（「表单验证 A / B」），再用 `session exec` 建三个 exec Run：一个成功结束，一个运行中，一个被 `run cancel`。
3. 页面切换：B 用 `window bind` 绑定 A 的主窗口，然后 `observe` 加 `act click`（`ax.press`）。
4. 截图用 `screencapture -l <windowID>`，只截这一个窗口，再缩到 1440 宽。
5. 断开状态：起副本 C，把它的记录目录指到不可写的位置，Runtime 启动失败，主窗口显示 Disconnected。
6. 收尾：结束所有副本和 exec 进程，删除 `/tmp/adt-u1b`。

| 图 | 内容 |
| --- | --- |
| [real-overview.png](real-overview.png) | 总览：两个真实 Desktop，控制者和动作数都来自 `run.list` |
| [real-detail.png](real-detail.png) | Desktop 详情（只读部分） |
| [real-runs.png](real-runs.png) | 全部运行：运行中 / 已停止 / 成功 |
| [real-run-detail.png](real-run-detail.png) | 运行详情：phase、outcome、quiescence 分开显示，事件按序号列出 |
| [real-inbox.png](real-inbox.png) | Inbox：尚未启用 |
| [real-settings-ai.png](real-settings-ai.png) | 设置 › AI 连接：原 AI 页面挂在 Settings 下，没有独立侧栏 |
| [real-disconnected.png](real-disconnected.png) | Runtime 未启动：Disconnected，「停止所有输入」禁用，不显示样例数据 |
| [mock-run-detail-with-receipts.png](mock-run-detail-with-receipts.png) | 离屏（Mock）：运行详情里三种回执（已执行未验证 / 未发出附原因 target_moved） |
| [mock-desktop-detail-with-actions.png](mock-desktop-detail-with-actions.png) | 离屏（Mock）：Desktop 详情的最近动作（结果未知 / 已执行未验证） |

关窗验证（真实副本）：在 B 上点 A 主窗口的关闭按钮。窗口隐藏，进程还在；关窗前后的 `run list` 完全一致，运行中的那个 Run 仍是 running。

### 偏差与发现

- **曾短暂碰到用户屏幕**：第一次试 `app launch --bundle-id com.apple.calculator --new-instance`，副本返回 `the app refused to move its window`；TextEdit 新实例 15 秒内没有窗口。两个新实例的窗口可能在用户主显示器上出现过几秒，我立即按 pid 结束了它们（用户自己的 TextEdit 进程 549 没碰）。之后不再启动任何应用，所以真实截图里没有绑定窗口和动作回执；回执改用 Mock 离屏图展示。
- 在 B 上用 `act` 点主窗口，偶尔返回 `action_delivery_unknown`（`target_changed_during_dispatch`）：被点的窗口在投递过程中换了页面或关闭了，Runtime 如实给了 unknown。点击本身生效了，下一次 observe 能看到变化。
- 引擎在用户主显示器上留了一个 layer 25 的透明窗口（属于副本 A，坐标 (0,280)，1280×800），看起来是某个 Agent Desktop 的光标叠加层在显示器重排时位置算错了。这是引擎行为，不在本 PR 范围，交给 L-Runtime。
- 回执里已经出现 `businessResult: not_evaluated`（A3/A5 的计划字段已落地），UI 仍固定显示「业务结果：未评估」，结论一致。

## Wireframes 对照

| 页面 | 设计 | 已实现 | 差异与原因 |
| --- | --- | --- | --- |
| Desktops › 总览 | P01、P03 | 卡片网格；全部 / 操作中 / 空闲筛选；按名称、ID、应用搜索；空状态；每张卡片进详情；侧栏列出 Desktop，点击进详情 | 「创建 Desktop」「并排预览」「打开预览」「停止」都禁用（U2 / U3）；画面是占位（U2 接 ScreenCaptureKit）；控制者与动作数来自运行记录（`Desktop.control` 属 A5）；没有列表视图切换（U2） |
| Desktops › 详情 | P06 | 标题与 desktopId；控制者条；画面占位；连接 / 输出 / 详情三个标签（displayId、windowId 只在「详情」里）；最近动作（来自该 Desktop 最近 5 个 Run 的事件，未发出的附原因）；跳到对应 Run | 独立预览、停止输入、我要接管都禁用（U2 / A5）；没有「导出截图与 trace」（U5b） |
| Runs › 全部运行 | Hub W04 | 全部 / 进行中 / 已结束；列：开始、runId 与 kind、Desktop、来源与 clientId、状态（6.4 规则：act 成功显示「已投递」，停止中要等静止确认）、回执数；结果未知的数量；进详情 | 没有按 origin、desktop 筛选和翻页（runtime/1 支持，界面后续加）；不能停止 Run（U3 / U5） |
| Runs › 运行详情 | Hub W05、P20 部分 | 三轴状态分开；ownership、lifetime、clientId、connectionId、closingReason、revision；事件时间线（增量读取）；每个动作的回执卡（6.4 三级文案，未发出附错误码） | 回执截图与导出属于 U5b；事件类型照原样显示（类型目录未冻结，F1-01） |
| Inbox | W06 | 「尚未启用：平台审批将在后续版本提供」 | U9 |
| Settings | P21–P26、P30 | 七个二级入口；AI 连接 / GUI 配置 / 能力测试 / 诊断与用量挂原 AIUI 页面（ai/1 客户端）；编辑连接、启动诊断、详情、需要处理在同一入口内打开，可返回；核实显示尚未启用 | 通用、权限显示「页面待接入（U6）」；AI 页面的样式还是原 AIUI 的，统一到设计 token 与 runtime/1 是 U6 |
| 菜单栏 | P31 | 运行状态（Desktop 数、进行中的运行、输入是否已停止）；打开主窗口（⌘O）；停止所有输入（确认后调 `runtime.stopAll`）/ 恢复输入；测试副本；退出 | 「打开某个 Desktop 预览」随 U2；退出确认（P32）是 U8 |
| Agents、GUI Explorer | Hub W01–W03、G 系列 | 入口固定，显示「页面待接入（U4 / U7）」 | 依赖 PR3 / A7、PR2d / X1 |
