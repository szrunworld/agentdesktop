# owner 挂接显示器入口（Owner Display Attach）

依据：Kevin 2026-10-10 裁决（#143 合并之后）：

1. 做 owner 挂接显示器入口，单独一个 PR（本 PR）；
2. 只打开 `physicalDesktopsEnabled`，`bindsOnlyLaunchedProcesses` 保持开着不动；
3. 显示器来源判定的上限已接受，不研究私有接口；
4. 真机验收由 Kevin 本人完成。

前置：A4（#137）身份与授权、窗口级授权（#205）、物理窗口 Desktop（#143）都已在 main 上。它们留下的缺口是：A4 规定挂接显示器只属于 owner，而 owner 只存在于宿主进程（主窗口）里，主窗口又没有"挂接我的显示器、开放给某个 App"的操作，所以 App 拿不到物理 Desktop。本 PR 补这个入口，并按裁决打开物理 Desktop 的封印。

## 原则

- **只有 owner 挂接。** `desktop.create {physical}` 和新的 `hub.displays.attach` 对已配对客户端一律 `permission_denied / owner_only`，也**不是**可由客户端申请、由用户确认的管理操作（`confirmableMethods` 不含它）：客户端连"请把你的屏幕给我"这个提示都发不出来。
- **挂接不等于看见。** 显示器开放给 App 之后，App 的授权里多了一个 `desktopId`，仅此而已。它 `window.list` 得到空列表，`window.bind` 被拒 `bind_requires_grant`，观察、操作、保存每一项都要按 #205 逐窗口申请、由用户用 Touch ID 确认。本 PR 没有给 App 任何整屏能力。
- **每次挂接都要本人确认。** 走 A4 的可信确认窗口（`TrustedConfirmationWindow`）+ LocalAuthentication（Touch ID / 登录密码），新增确认类型 `displayAttach`。确认结果绑定到展示内容的 digest；用户决定期间客户端授权版本变了、显示器来源变了，都不写入（`target_changed` / `display_changed`）。
- **只开放证实为物理的显示器。** 来源判定沿用 #143 的 `DisplayOrigin.classify`（内建屏，或与硬件帧缓冲按厂商 + 型号 + 序列号一一匹配的外接屏）。虚拟屏和来源不确定的显示器在列表里可见但不可选；Runtime 对它们返回 `permission_denied / display_not_physical`。已接受的上限：公开 API 证明不了某个帧缓冲此刻在驱动哪块显示器；兜底是 owner-only 挂接 + 逐窗口 Touch ID。
- **一块显示器一个物理 Desktop。** 已挂接的显示器再开放给另一个 App 时复用同一个 Desktop（`created: false`），不会出现两个 Desktop 指向同一块屏。
- **收回和收窄一样。** `hub.displays.detach` 把 Desktop 从 App 的授权里去掉：在同一个事务里结束它在这个 Desktop 上的全部窗口授权（`desktop_removed`），切断它的连接（`grant_narrowed`），停止它在这个 Desktop 上的 Run 和会话。不带 `clientId` 时对所有 App 执行，然后只删除 Desktop 记录——显示器和它上面的窗口是用户的，不碰。

## 方法（runtime/1 契约增量，只新增，不改旧字段）

| 方法 | 调用方 | 参数 | 结果 |
| --- | --- | --- | --- |
| `hub.displays.list` | owner | 无 | `HubDisplayList`：每块活动显示器的 `displayId`、系统报告的名称、`frame`、`hiDPI`、`builtin`、`origin`（`physical` / `virtual` / `unconfirmed`）、`originDetail`、`attachable`（物理且未挂接）、`desktopId`（已挂接时） |
| `hub.displays.attach` | owner，本人确认 | `displayId`、`clientId`（`app:…`）、可选 `name` | `HubDisplayAttachment`：`desktop`（物理）、`grant`（新版本）、`created` |
| `hub.displays.detach` | owner | `desktopId`、可选 `clientId` | `HubDisplayDetachment`：`desktopId`、`destroyed`、被改动的 `grants` |

来源报告由宿主提供（`PhysicalDisplays.report()` → `EnginePlatform(engine:displays:)`），和注册给引擎的"宿主屏幕"用同一次分类：列表里标为物理的，就是 `attachDisplay` 会接受的；证实为物理但引擎尚未登记的显示器（刚插上）标为 `unconfirmed`，稍后再试。

## 流程（主窗口）

Desktops › 总览 › **开放我的显示器**：

1. 窗口向 Runtime 读 `hub.displays.list` 和 `hub.clients.list`，列出显示器（名称、分辨率、来源判定结果；不可开放的置灰并写明原因）和已配对、授权有效的程序。
2. 用户选显示器和程序，可填 Desktop 名称，点"开放…"。
3. Runtime 弹可信确认窗口：显示器（名称、编号、分辨率、来源判定）、Desktop（新建或复用）、程序（自报名称、clientId、系统核实的代码身份、它可申请的 App、授权到期），以及"这是你自己正在使用的屏幕；开放后它看不到任何窗口"的警告。默认按钮"拒绝"；"批准…"后系统要求 Touch ID / 登录密码。
4. 批准后 Runtime 再核对一次客户端授权版本和显示器来源，然后：复用或新建物理 Desktop（`platform.attachDisplay`，不创建任何东西），把 `desktopId` 写进该 App 的授权（`hub.setGrant`，版本 +1，审计 `hub.displays.attach granted`）。扩大授权不切断连接。
5. 窗口只显示 Runtime 的回答：Desktop、开放给谁、授权版本。

Desktops › 详情（物理 Desktop）› **开放给的程序**：列出授权里含此 Desktop 的程序，每个可"收回"；"全部收回并解除挂接"调用不带 `clientId` 的 `hub.displays.detach`。

CLI：`agentdesktop displays list|attach|detach` 映射到同样的方法。产品里 socket 上的 CLI 是已配对客户端，只会得到 `owner_only`；这些命令是给测试副本（测试 owner 凭据）和脚本用的。

## 封印状态（按裁决）

| 开关 | 本 PR 之后 |
| --- | --- |
| `physicalDesktopsEnabled` | **开**。`desktop.create {physical}` 对 owner 可用；对已配对客户端仍是 `owner_only`。测试 `theSealsStayAsTheProductShipsThem` / `theSealsKeepTheirProductDefaults` 锁定新默认值 |
| `bindsOnlyLaunchedProcesses` | 开，不动：虚拟 Desktop 仍只能绑定在它上面启动的进程 |
| `refusesScreenCaptureWithoutBinding` | 开，不动 |

打开封印后逐一核对过的旁路：

- 无绑定的物理 Desktop 观察：仍 `invalid_target`，不截整屏（物理路径不看 `refusesScreenCaptureWithoutBinding`）；
- `window.list` / `desktop.show`：已配对客户端只看到有 observe 窗口授权的窗口与自己启动的窗口，绑定信息无权时为 `null`（#205 不变）；
- MCP / ACP / CLI：都是 socket 上的已配对客户端，`hub.displays.*` 对它们是 `owner_only`；MCP 工具表不含 hub 方法；
- 主窗口本身：owner，确认窗口由 Runtime 弹出，不是网页或可被脚本点击的控件；LocalAuthentication 不能被其他进程代按。

## 审计

`auth_events`：`hub.displays.attach` 的 `asked` / `confirmed` / `denied`（含 `user_denied`、`confirmation_timeout`、`no_trusted_ui`、`display_not_physical`、`target_changed`）、`granted`（reason `d_… display <id> revision <n>`）；`hub.displays.detach` 的 `revoked`（每个被收回的客户端）和 `ended`（Desktop 记录删除）。记录里只有 Desktop / 显示器编号与版本号，没有窗口内容。

## 测试

`Tests/AgentDesktopRuntimeTests/RuntimeDisplayAttachTests.swift`：owner 列表与来源；挂接经确认、写入授权、不建屏、App 仍无窗口、授权后可绑定；同一显示器复用；拒绝 / 超时 / 无可信窗口不写入；非物理显示器、不存在的显示器、已撤销或过期的客户端被拒；用户决定期间授权变化不写入；按客户端收回（窗口授权结束、连接切断、会话关闭、其他客户端不受影响）；全部收回只删记录；已配对客户端挂接 / 收回 / `desktop.create {physical}` 一律 `owner_only` 且不触发确认。`Tests/AgentDesktopUITests/DisplayAttachTests.swift`：窗口只提供可开放的显示器、经 Runtime 挂接、失败保留表单、详情面板列出与收回、渲染。CLI：`displaysCommandsSendTheirMethods`。

真机（Touch ID）由 Kevin 本人完成：`scripts/owner-attach-acceptance.sh`，记录模板 `docs/acceptance/physical-desktop/owner-attach-acceptance.md`；之后 `scripts/physical-desktop-acceptance.sh` 不再在第 2 步停下，而是等待 owner 在测试副本主窗口里开放显示器，然后跑完第 3–8 步。
