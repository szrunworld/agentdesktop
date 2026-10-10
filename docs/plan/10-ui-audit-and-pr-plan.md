# 10 主窗口 UI 审计与分阶段 PR 计划（L-UI 第一阶段）

日期：2026-10-08 · 工作线：L-UI（AgentDesktop-UI）· 状态：第一阶段交付，只有文档，不含产品代码

依据（按权威顺序）：ADR v2.2；runtime/1 冻结目录（`docs/architecture/runtime-api-v1-freeze.md`、`contracts/runtime/v1/`）；本目录 02、03、06（含 PR #42 分支 `plan-ui-brief` 上的 6.4）、07、08、09；`docs/design/v2/`（P01–P32、`screen-map.json`、`ui-checks-54.json`）。

历史审计基线（2026-10-08）：

| 分支 | 提交 | 说明 |
| --- | --- | --- |
| `origin/ai-gui-foundation` | `5db0cec`（#41 合入后） | 本文所有「现状」的依据（历史快照；foundation 已于 2026-10-08 经 #2 合入 main，最新状态以 02 文件 2.2 节为准） |
| `origin/main` | `501ff01`（#20） | 含 `engine/` 与 `docs/migration/` |
| `origin/plan-ui-brief` | PR #42 | 09 文件与 06 的 6.4 |
| `origin/a02-main-window` | PR #1 | 旧 A02 主窗口，已过时 |

以下审计结论、可用方法与依赖图均保留上述基线的历史判断，不能当作最新 main 的交付状态。当前状态见 [02 实施计划 §2.2](02-implementation-plan.md#22-与-2ndscreen-f1-的-pr-编号对照)：A0、PR2b、主窗口、流式预览与 A4 已有合入记录；A6 Runtime 实现与完整 A5/A7 验收仍未完成。

---

## 0 历史审计结论摘要

1. **现在没有主窗口。** 产品宿主是纯菜单栏 App（`.accessory`，无 Dock）。唯一的窗口是「AI 与 GUI」（`AIWindowController`），里面是 `AIGUIRootView` 自带八项侧栏的 NavigationSplitView，D32 已裁决删除这个侧栏。
2. **现有 UI 代码只有 AI/GUI 八页（AgentDesktopAIUI 的 W01–W08）**，走的是 **ai/1 信封**（`ContractClient` → `AgentDesktopService.router`，进程内）。它们和 Hub v1 的 W01–W08 **同名不同物**，后文写成 `AIUI-W0x` 与 `Hub-W0x` 以免混淆。其中 AIUI-W05/W06/W07 调的是已撤销的 `gui.runs.*`，PR2d 之后只能重写。
3. **Runtime 对 UI 的可用面**：已实现 33 个方法（含 #41 刚合入的 `events.subscribe/unsubscribe`）；frozen 28 个（27 个 `ai.*` 现在只在 ai/1 上可用，等 PR2b；`unit.run` 等 PR2d）；reserved 31 个（`hub.*`、`inbox.*`、`run.reconcile`、`diagnostics.export`、`gui.*` 学习，参数都还没定稿，**Mock 也无法实现**）。
4. **UI 与 Runtime 的通信**：Runtime 只有 socket（`runtime.sock`），但 `RuntimeService.respond(to:on:)` 是 public 的，可以进程内调用；进程内调用**不得在主线程**（`EnginePlatform` 会切到主线程调引擎，主线程调用会死锁）。进程内目前只能拿到 `local:<uid>` owner 主体，建出的 Run 仍是 `external_client / connection_scoped`；平台所有的 Run（Explorer Durable、人工接管 `origin=user`）没有进程内入口，属于 A5/A6 范围。
5. **A0 仓库收敛未开 PR。** 开放 PR 只有 #42、#37、#29、#2、#1。U1 的接线部分（改宿主、菜单、Dock）按 09 要求等 A0；与宿主无关的 UI Shell 库（token、组件、页面容器、Store、Mock Adapter）可以先做。
6. **最先可开工的 PR：U1a「UI Shell 库」**（新 target `AgentDesktopUI`，不改宿主、不改 Runtime）。
7. **契约缺口**：交给 2ndscreen-f1 的 **12 条**新增需求（不含 03 §3.2 已列的增量，那些只给出 UI 侧优先级），交给 2ndscreen-40 的 **6 条**。最关键三条见第 5 节开头。

---

## 1 代码审计

### 1.1 宿主：`Sources/AgentDesktop`

| 文件 | 现状 | 对 UI 的影响 |
| --- | --- | --- |
| `main.swift` | `setActivationPolicy(.accessory)`：无 Dock、无主窗口；单实例检查用引擎 `ControlProtocol.isListening(control.sock)` | U1b 改为产品角色 `.regular`，测试副本保持 `.accessory` |
| `HostRole.swift` | `product` / `sideInstance(socket)`；`control.sock`（**仍是引擎 ControlServer**）、`runtime.sock`、`ai.sock` 三个端点；测试副本用文件凭据 | 冻结文档要求 `control.sock` 成为唯一 runtime/1 端点（PR2b），与引擎旧 socket 同名冲突，由 A0/PR2b 解决；UI 不碰端点 |
| `AppController.swift`（845 行） | 从 2ndscreen 移植的菜单栏：Virtual Display 开关、Resolution、HiDPI、Show Preview / Keep on Top / Full Screen、「Windows on …」搬窗口、⌃⌥⌘M 热键、「Agent Screens (n)」逐个预览/尺寸/销毁、Test Copies、「AI 与 GUI…」、Open Displays Settings、Quit。启动 `AgentRuntime`（引擎）+ `RuntimeServer`（runtime/1）+ `RpcSocketServer`（ai/1）+ `AgentDesktopService` | D35：Virtual Display / Resolution / HiDPI / 搬窗口 / 热键 / Agent Screens 菜单全部不进产品界面；U8 把菜单换成 P31。`applicationShouldTerminateAfterLastWindowClosed`、`applicationShouldHandleReopen` 都没有 |
| `AIWindow.swift` | `AIWindowController`：1180×760 窗口，`InProcessContractClient(router: service.router(callerScope: "uid:…", trustedOwner: true))`，内容是 `AIGUIRootView` | U1b 删除；页面挂进主窗口 Settings 与 Desktop 详情 |
| `HotKey.swift` | 搬窗口热键 | D35 不进产品 |

结论：宿主目前同时维护**两套执行状态**——引擎 `AgentRuntime`（`control.sock`，旧 CLI 能直接用）与新 `RuntimeService`（`runtime.sock`）。UI 只能消费后者；「旧控制 socket 不再由产品启动」是 A0 的验收项，UI 不处理。

### 1.2 页面：`Sources/AgentDesktopAIUI`

依赖只有 `AgentDesktopContracts`（ai/1）。

| 文件 | 页面 | 调用的方法 | 去向 |
| --- | --- | --- | --- |
| `AIGUIRootView.swift` | 八项侧栏 + 页面跳转 | — | **删除侧栏**（D32、整合设计 T27），页面视图与模型保留 |
| `Pages/W01Connections.swift` | AI 连接列表（P23） | `ai.connections.list/disable/delete` | U6 复用 |
| `Pages/W02ConnectionEditor.swift` | 添加/编辑 AI 连接（P24）；密钥只在 `secretInput`，提交即清空 | `ai.connections.create/get/update`、`ai.credentials.rotate`、`ai.models.list/refresh`、`ai.operations.get` | U6 复用；改成侧边抽屉 |
| `Pages/W03Profiles.swift` | GUI 配置（P25） | `ai.profiles.*`、`ai.modelProfiles.list/create`、`ai.connections.list` | U6 复用 |
| `Pages/W04CapabilityTest.swift` | 四层能力测试（P26），500 ms 轮询 | `ai.tests.start`、`ai.operations.get/cancel`、`ai.profiles.get/list` | U6 复用 |
| `Pages/W05RunStart.swift` | 启动 GUI 诊断（P27） | `gui.runs.start`（**已撤销**）、`runtime.capabilities`（ai/1 版，**已撤销**） | U7 重写为 `unit.run` |
| `Pages/W06RunDetail.swift` | 诊断详情（P28/P29），500 ms 轮询 | `gui.runs.get/events/cancel`（**已撤销**） | U7 重写为 `run.show/events/cancel` + 事件订阅 |
| `Pages/W07Attention.swift` | 结果未知的运行，无重试按钮 | 经 W06 模型 | U3 的 P17 与 U9 核实参考它的规则，代码重写 |
| `Pages/W08Usage.swift` | 用量与诊断（P30） | `ai.usage.summary`、`ai.connections.list` | U6 复用 |
| `Components.swift` | `ProblemBanner`、`EmptyState`、`LabeledValue` | — | U1a 并入新组件库，补 Loading / Disconnected / 样例标识 |
| `ContractClient.swift` | `ContractClient` 协议；`InProcessContractClient`、`SocketContractClient`（ai/1 信封）；`PollClock`；`SubmissionKey`（同一提交保留幂等键） | — | PR2b 删 ai/1 信封后整体换成 runtime/1；`SubmissionKey` 的语义保留（runtime/1 里 requestId 就是幂等键） |
| `Problem.swift` | `UIProblem`：ai/1 大写错误码 → 中文标题与建议；`LoadPhase`；`Format` | — | 换成 runtime/1 小写码（`errors.json`）；按冻结文档 §6 映射表一一对应，文案可复用 |

测试：`Tests/AgentDesktopAIUITests`（PagesTests 432 行 + Support 226 行），用真实 `AgentDesktopService` 进程内跑页面模型；`renderSmoke` 在 `NSHostingView` 里按 1440×1000 布局一次，但**不输出图片**。U1a 要把它扩成真正出 PNG 的离屏渲染（09 要求与 `Pxx.webp` 并排）。

### 1.3 客户端：`Sources/AgentDesktopClient`

| 文件 | 现状 | 对 UI 的影响 |
| --- | --- | --- |
| `RuntimeClient.swift` | 协议 `RuntimeClient`（`handshake`、`call`、`close`，#41 加了 `subscribe`、`nextEvent`）；`SocketRuntimeClient` 校验信封与 schema；**同步阻塞 API** | UI 不直接在主线程调用。U1a 定义 async 的 `RuntimeAPI` 端口，生产实现包装进程内 `RuntimeService`，Mock 实现同一端口 |
| `EndpointResolver.swift` | `--endpoint` > `AGENTDESKTOP_ENDPOINT` > 产品 `runtime.sock`；拒绝他人 socket | 进程内 UI 不需要；「Runtime 离线」状态只在 Runtime 启动失败时出现 |
| `Transport/UnixSocketTransport.swift` | 行帧 socket | 同上 |

### 1.4 Runtime 已向 UI 提供的方法（`contracts/runtime/v1/methods.json` @5db0cec）

| 状态 | 方法 | UI 用途 |
| --- | --- | --- |
| implemented | `runtime.handshake/status/capabilities`；`runtime.stopAll/enableInput` | 状态栏、权限（`capabilities.backend.permissions`）、全局停止、P32 |
| implemented | `desktop.list/show/create/destroy`；`app.list/launch`；`window.list/bind/unbind` | U2 |
| implemented | `session.open/show/close`；`observe`；`act`；`wait`；`request.show` | U2 详情画面（观察图）、U5 回执 |
| implemented | `run.start/attach/finish/show/events/wait/cancel/list` | U5、U3 的停止（暂以 `run.cancel` 代替 `desktop.stop`） |
| implemented | `artifact.show/read`（PR2c，#35） | 截图、回执图像 |
| implemented | `events.subscribe/unsubscribe`（PR2e，#41） | U1 Store 的唯一推送源 |
| frozen | `unit.run`（PR2d） | U7 |
| frozen（ai/1 上已实现，未迁 runtime/1） | `ai.connections.*`、`ai.credentials.rotate`、`ai.models.*`、`ai.modelProfiles.*`、`ai.profiles.*`、`ai.tests.start`、`ai.operations.*`、`ai.usage.summary`（27 个，PR2b） | U6 |
| reserved（无参数） | `hub.pairing.*`、`hub.clients.*`、`hub.grants.*`、`hub.connections.list`（PR3） | U4 |
| reserved（无参数） | `inbox.*`、`run.reconcile`、`diagnostics.export`（PR4） | U3 的 P17、U9 |
| reserved（无参数） | `gui.knowledge.*`、`gui.procedures.*`、`gui.validations.*`、`gui.demonstrations.*`、`gui.learning.settings.*`（PR7） | P2，U7 一级入口只显示说明 |

与 06 的出入：06 写「Settings › 权限：`runtime.status` 的 PermissionState」，实际 `PermissionState` 在 `runtime.capabilities.backend.permissions{screenRecording, accessibility}`，`RuntimeStatus` 里没有。UI 以 schema 为准。

事件现状（#41）：订阅只推 **Run 事件**（`RunEvent{runId, sequence, at, type, data}`），`type` 是自由字符串。Runtime 实际发出的有 `run.started`、`run.finishing`、`run.ended`、`run.quiescent`、`action.accepted`、`action.dispatched`、`action.completed`、`action.failed`、`action.unknown`。没有 Desktop 级事件。订阅连接与控制连接互斥（持有未结束 Delegated Run 的连接不能订阅）。

### 1.5 Desktop、Window、Screen 的关系

```
Desktop（desktopId，UI 唯一对外身份）
 ├─ screen: ScreenRef{displayId, frame, hiDPI}   ← 引擎 AgentScreens 的一块虚拟显示（只在详情显示）
 ├─ binding: Binding{generation, process, windowId, appName, boundAt} | null
 │            ← 至多一个绑定窗口；generation 每次重绑 +1
 ├─ state: ready | busy | destroying             ← 没有 creating / control（03 §3.3 增量）
 └─ openSessions
Window（window.list）= 系统窗口（windowId, process, frame, onScreen）；window.bind 把它搬进 Desktop
App（app.list）= 进程；app.launch 在 Desktop 上启动
Session = 某 Desktop 上的输入会话；Run = 一次执行（act / exec / unit），带 desktopId、sessionId
Observation = 某 Desktop 的一次观察（snapshotId，D20：界面显示为「画面 ID」）
```

- 旧菜单的「主虚拟显示」（Virtual Display、Resolution、HiDPI）**不是 Desktop**，D35 不进产品。
- P06 规则「不以 displayId / windowId 替代 desktopId」：列表、标题、复制按钮只用 desktopId；displayId、windowId、pid、generation 放详情的「详情」标签。
- 实时预览（P06、P08）在 UI 进程里按 `screen.displayId` 用 ScreenCaptureKit 取流，只作呈现；动作坐标与证据只认 `observe` 的图（`ImageArtifact` + `artifact.read`）。

### 1.6 UI 与 Runtime 的通信方式（U1 的设计约束）

| 方式 | 现状 | 用于 |
| --- | --- | --- |
| 进程内 `RuntimeService.respond(to:on: ConnectionState)` | 可用（public），主体 `local:<uid>` owner | 主窗口全部 runtime/1 调用（02 A2：「UI 走进程内 Client 同一 router」） |
| 进程内订阅：同一 `ConnectionState` 上 `events.subscribe` 后取 `pendingEventFrames` | 可用（public），但没有唤醒通知，只能定时取 | U1 Store；**订阅用独立的 ConnectionState**，不和控制连接共用 |
| 进程内 ai/1 `AgentDesktopService.router` | 现有 AIUI 在用 | PR2b 后删除，U6 跟着换 |
| socket `runtime.sock` | CLI、MCP、SDK 用 | UI 不用 |

约束：

1. 进程内调用一律放后台执行器，**不在主线程调用 `respond`**（`EnginePlatform` 在主线程调引擎，主线程调用会自锁）。
2. 进程内连接在主窗口关闭时**不调用** `connectionClosed`（ADR-02：关闭页面不影响 Run）；它属于宿主进程生命周期。
3. 目前进程内只能以 owner 身份建 `external_client / connection_scoped` 的 Run。Explorer 的 Durable Run（A6）和人工接管的 `origin=user` 平台 Run（A5）需要 Runtime 提供进程内平台入口，UI 不自己拼。
4. Store 只从快照方法与事件取数：Run 用 `run.list` 快照 + 全局 `events.subscribe` 增量（游标过期时退回 `run.list`/`run.show`）；Desktop 没有事件，暂用 `desktop.list` 定时快照（缺口 F1-02）。一个数据源只用一种更新方式（02 U1「轮询或事件唯一」）。

### 1.7 旧 UI 的复用与裁决（origin/main `engine/`、PR #1）

| 来源 | 内容 | 处置 |
| --- | --- | --- |
| `engine/Sources/SecondScreenCore/DisplayPreview.swift` | ScreenCaptureKit 预览窗口：按 displayId 取流、缩放、旋转、全屏、置顶、遮挡时暂停、工具栏按钮 | **复用**作 P08 独立预览窗口（07：缩放进 U2，旋转与音量随 M2）。它是 NSWindow 类，主窗口内嵌预览要另写 SwiftUI 视图（同样用 ScreenCaptureKit）；不改 engine 源码 |
| `engine/Sources/SecondScreenRuntime/AgentCursorOverlay.swift` + `SecondScreenCore/AgentCursorEvent.swift` | Agent 光标叠加层，经 DistributedNotification 驱动 | **复用**；P21「光标标记开关」只控制宿主是否创建叠加层（本地偏好），不进契约 |
| 菜单栏：Virtual Display、Resolution、HiDPI、Show Preview（主显示）、搬窗口、⌃⌥⌘M、Agent Screens 列表、Destroy All | — | **不进产品**（D35），U8 删除 |
| 菜单栏：Test Copies | 测试副本列表 | 保留在开发者区域或「诊断」下（不属于 P31，U8 决定位置，不删功能） |
| `engine/windows/.../PreviewForm.cs` | Windows 预览 | 不属 L-UI（L-Win） |
| PR #1 `UI/AppModel.swift` | **代数（generation）丢弃过期结果**：切换客户端代数 +1，迟到应答丢弃；**单定时器 + 引用计数**的轮询（窗口打开才轮询） | **复用设计**进 U1a Store（02 U1 明确要求） |
| PR #1 `PermissionStatus.check()`、设置页权限向导 | `CGPreflightScreenCaptureAccess`、`AXIsProcessTrusted`、申请与「打开系统设置」、重新检测 | **复用**进 U6（P02、P22）；与 `runtime.capabilities` 的权限对照显示 |
| PR #1 `MainWindowController` | `isReleasedWhenClosed = false`、关窗不退出、Dock 重开、`applicationShouldHandleReopen` | **复用**进 U1b |
| PR #1 `TaskClient`、`SampleTaskClient`、任务视图 | 基于已废弃的 C03 task 契约 | **不复用**；样例数据方式被 09「正式服务失败不回退样例」否定。#1 建议关闭，在关闭说明里指向本计划 |

### 1.8 开放 PR

| PR | 状态 | 与 UI 的关系 |
| --- | --- | --- |
| #42 `plan-ui-brief` | 开放 | 本文依据；6.4 三级展示规则 |
| #41 `runtime-events-subscribe` | **已合入**（5db0cec） | PR2e 完成，U1 Store 可用订阅 |
| #37 MAC-001 验收记录 | 开放 | 「投递成功而窗口无变化」：6.4 与 RT-24 的 UI 文案依据 |
| #29 CLI PR3（MCP、SDK） | 草稿 | P10 MCP 配置示例的 `--desktop-id` 依赖它（A7） |
| #2 foundation → main | 已合入 134b451（2026-10-08） | A0 的一部分 |
| #1 旧 A02 主窗口 | 开放，已过时 | 只取 1.7 所列 |
| **A0 仓库收敛** | **未开 PR** | U1b 起的全部接线 PR 阻塞于它 |

---

## 2 U1–U9 映射

图例：✅ implemented · 🧊 frozen · 🔖 reserved · ⛔ 缺口（第 5 节编号）。「Mock 字段」只列正式契约（runtime.schema.json / ai-gui v1 rpc.schema.json）里已有的方法与字段；reserved 方法没有参数定义，**不做 Mock**，页面显示「尚未启用」。

### U1 界面骨架

| 项 | 内容 |
| --- | --- |
| 页面 | 主窗口框架：侧栏 206、标题栏 54、状态栏 28，内边距 32，基准 1440×1000；六个一级入口 Desktops / Agents / Runs / GUI Explorer / Inbox / Settings（06 §6.1） |
| 已有组件 | `ProblemBanner`、`EmptyState`、`LabeledValue`、`UIProblem`、`LoadPhase`、`Format`、`SubmissionKey`（AIUI）；PR #1 的代数与轮询、关窗转后台 |
| 缺失组件 | `AgentDesktopUI` target；设计 token（画布 #f5f6f2、面板 #ffffff、主文字 #25352c、主色 #416b53、选中 #e0e9d8、边界 #dfe4dc；状态色：绿运行/可用、灰就绪/停止、琥珀接管/等待/未知、红停止与错误，颜色必须配文字；按钮圆角约 7、面板 12、按钮最小高 36；间距 4/8/12/16/24/32）；侧栏、标题栏、状态栏（Runtime 状态与输入准入）；页面容器四态 Loading / Empty / Error / Disconnected；样例模式常驻标识；`RuntimeAPI` async 端口、进程内实现、Mock 实现；`Store`（代数、快照 + 事件、游标过期退回）；离屏渲染出 PNG 的测试工具 |
| Runtime 方法 | ✅ `runtime.handshake/status/capabilities`；✅ `events.subscribe/unsubscribe`；✅ `run.list`、`desktop.list`（快照） |
| Mock 字段 | `RuntimeIdentity{product, productVersion, apiVersion, instanceId, pid, startedAt, endpoint, platform, build}`；`RuntimeStatus{instanceId, state, startedAt, uptimeSeconds, connections, desktops, sessions, runs, inputAdmission}`；`Capabilities.interface.methods[]{method, mutation, stage}`、`backend.permissions`；`EventFrame{apiVersion, event, cursor}`、`EventSubscription{subscribed, runId, next}`；错误 `runtime_offline`、`events_cursor_expired`、`capability_missing` |
| 验收 | 渲染图与 P01 布局对照；UC50（关闭主窗默认后台继续）；整合设计 T27（AIGUIRootView 不再有独立侧栏）；UC53/UC54 原生等价项 |
| 优先级 | P0，最先 |

### U2 Desktops

| 项 | 内容 |
| --- | --- |
| 页面 | P01 总览（网格/列表、搜索、运行/空闲筛选）、P03 空状态、P04 创建（三种方式：空 / 启动应用 / 绑定窗口；高级尺寸收起）、P05 创建中、P06 详情（预览 / 连接 / 输出 / 详情 / Explorer 标签）、P07 并排、P08 独立预览窗口 |
| 已有组件 | `DisplayPreview`（P08）；`EmptyState` |
| 缺失组件 | Desktop 卡片与行、筛选条、创建模态、内嵌实时预览视图（SCK）、观察图视图（`artifact.read` 分块拼装）、复制 desktopId、详情右侧标签容器、并排布局 |
| Runtime 方法 | ✅ `desktop.list/show/create/destroy`、`app.list/launch`、`window.list/bind`、`observe`、`artifact.read`、`run.list{desktopId, active}`（暂代控制者）；⛔ 03：`Desktop.control`、`desktop.create` 的 launch/bind 一步完成、`desktop.resize`；⛔ F1-02 Desktop 事件；⛔ F1-08 `desktop.create` 的 `hiDPI` |
| Mock 字段 | `Desktop{desktopId, name, state, createdAt, screen{displayId, frame, hiDPI}, binding{generation, process{pid,…}, windowId, appName, boundAt}, openSessions}`；`desktop_create_params{name, width, height}`；`DestroyResult{desktopId, destroyed, quitApps}`；`App{process, bundleId, name, active, hidden}`；`Window{windowId, process, appName, bundleId, title, frame, onScreen}`；`LaunchResult{desktopId, process, windows}`；`Observation{snapshotId, desktopId, capturedAt, screen, target, image{artifactId, mediaType, width, height, byteSize, sha256, transform}, elements}`；`ArtifactChunk{artifactId, offset, length, eof, dataBase64}`；`Run{runId, origin, ownership, clientId, desktopId, phase}`（控制者） |
| 降级规则 | `Desktop.control` 未落地前：「创建中」只在 `desktop.create` 请求在途时显示（不显示假百分比）；控制者由 `run.list{desktopId, active:true}` 推出，文案标「来自运行记录」；创建 + 启动分两次请求，第二步失败时 Desktop 保留并显示错误与重试 |
| 验收 | UC01–UC06、UC14、UC16、UC19–UC21、UC49、UC52 |
| 优先级 | P0；U1b 之后第一个页面 PR |

### U3 控制

| 项 | 内容 |
| --- | --- |
| 页面 | P12 接管确认、P13 人工控制中、P14 停止中、P15 已停止、P16 连接断开、P17 结果未知、P18 关闭确认 |
| 已有组件 | AIUI-W07 的规则（无重试、无强制成功）；`ProblemBanner` |
| 缺失组件 | 控制状态条（九态，见 03 §3.4）、两步停止视图（停止中 → 已停止，等 `quiescence=confirmed`）、接管/交还模态、未知动作处理弹窗（先重新观察才开放「结束本次连接」）、关闭计划弹窗 |
| Runtime 方法 | ✅ `run.cancel`（`CancelReceipt`）、`run.wait`、`run.show`、`observe`、`desktop.destroy`；⛔ 03：`desktop.stop`、`desktop.takeover/handback`、`desktop.closePlan`、`Desktop.control`；🔖 `run.reconcile`（PR4） |
| Mock 字段 | `CancelReceipt{cancelRequest{accepted, scope{kind, id}}, execution{phase, quiescence, outcome, revision}, alreadyTerminal}`；`Run{phase, outcome, quiescence, closingReason, unknownActions, revision}`；`RunEvent` 的 `run.quiescent`、`run.ended`；`DestroyResult.quitApps`；错误 `stop_pending`、`run_not_active`、`control_busy` |
| 降级规则 | `desktop.stop` 未落地前，P14/P15 只对「该 Desktop 上的活动 Run」逐个 `run.cancel`，文案写明「停止该 Desktop 上的运行」；接管、交还、关闭计划按钮显示「需要 Runtime 支持」并禁用，**不用 run.start 自造接管**（会建出 external_client Run，违反 ADR） |
| 验收 | UC07–UC13、UC15、UC17、UC18、UC29–UC31；ADR-02 界面部分 |
| 优先级 | P0；主体阻塞 A5 |

### U4 Agents

| 项 | 内容 |
| --- | --- |
| 页面 | Hub-W01 总览、Hub-W02 接入应用（含 P09 CLI、P10 MCP、P11 ACP 示例）、Hub-W03 Agent 详情与授权 |
| 已有组件 | 无 |
| 缺失组件 | 客户端列表（登记、连接、授权**三列分开**）、配对窗口（双方短码、逐项勾选、只能勾已请求项、期限 1h/8h/7d）、授权编辑、撤权确认（「应用仍在线；权限已撤销；N 个平台运行停止中」）、CLI/MCP 示例生成器（绑定 desktopId，MCP 为可校验 JSON）、只读连接检查 |
| Runtime 方法 | 🔖 `hub.pairing.start/status/approve/deny`、`hub.clients.list/show/revoke`、`hub.grants.list/set/revoke`、`hub.connections.list`（PR3）；✅ `runtime.handshake` 的 principal（PR2b 才进 schema）；⛔ F1-06 owner 侧待批配对列表；⛔ F1-07 只读连接检查 |
| Mock 字段 | **无**（reserved 方法无参数）。P09/P10 示例文本可先做：只依赖 desktopId 与 #29 的 `agentdesktop mcp --desktop-id` |
| 验收 | UC22–UC25；HB-UI-01…04 |
| 优先级 | P0（D01：首发至少有连接与授权管理）；阻塞 PR3、A7 |

### U5 Runs

| 项 | 内容 |
| --- | --- |
| 页面 | 全部运行（Hub-W04）、运行详情（Hub-W05）、动作记录（P19）、动作回执（P20） |
| 已有组件 | AIUI-W06 的时间线写法（需重写数据源） |
| 缺失组件 | 运行列表（按 origin、phase、desktop、active 筛选，游标翻页）、三轴状态徽章（phase / outcome / quiescence 分开显示）、事件时间线、回执卡（6.4 三级文案）、回执 JSON 导出、截图查看与下载 |
| Runtime 方法 | ✅ `run.list/show/events`、`events.subscribe`、`request.show`、`artifact.show/read`；⛔ 03：`request.list/export`、`businessResult`；⛔ F1-01 事件类型目录、F1-03 回执错误原因、F1-04 回执动作摘要、F1-05 观察图按 snapshotId 取、F1-09 `run.list` 按 kind 筛选 |
| Mock 字段 | `RunList{runs, next}`；`run_list_params{clientId, origin, phase, desktopId, active, cursor, limit}`；`Run`（全部必填字段）；`RunEvents{events, next, ended}`；`RunEvent{runId, sequence, at, type, data}`；`ActionReceipt{receiptId, requestId, runId, desktopId, sessionId, snapshotId, delivery, execution, verification, route, target{generation, process, windowId, elementRef, point}, timing{acceptedAt, dispatchedAt, completedAt}}`；`RequestRecord{requestId, method, state, acceptedAt, finishedAt, outcome}` |
| 规则 | 6.4：`kind=act` 且 `outcome=success` 的 Run 列表显示「已投递」；回执按 delivery/execution 显示「未发出 / 已执行，未验证 / 执行失败 / 结果未知」，`verification=not_requested` 一律「已执行，未验证」；`businessResult` 入契约前显示「业务结果：未评估」 |
| 降级规则 | `request.list` 未落地前，P19 由 `run.list` + 各 Run 的 `action.*` 事件（事件 `data.receipt`）组装，只覆盖 Run 内动作，页面注明范围 |
| 验收 | UC26–UC28；ADR-07 界面部分 |
| 优先级 | P0；运行列表与详情现在就能接真数据 |

### U6 Settings

| 项 | 内容 |
| --- | --- |
| 页面 | P21 通用（关窗后台、光标标记、默认尺寸）、P02 首次使用与权限、P22 权限缺失、P23 AI 连接、P24 添加连接（抽屉）、P25 GUI 配置、P26 能力测试、P30 用量 |
| 已有组件 | AIUI-W01/W02/W03/W04/W08 及模型；PR #1 `PermissionStatus` 与权限向导 |
| 缺失组件 | 设置二级导航；通用偏好存储（本地 UserDefaults）；权限卡（系统实测 + `runtime.capabilities` 对照）；runtime/1 版 `ContractClient` 与错误映射 |
| Runtime 方法 | ✅ `runtime.capabilities`（`backend.permissions`）；🧊 27 个 `ai.*`（PR2b 前只在 ai/1）；⛔ F40-04 用量按 runId 汇总（P30「本次诊断汇总」） |
| Mock 字段 | `Capabilities.backend{platform, permissions{screenRecording, accessibility}, features}`；`ai.*` 用 ai-gui v1 `rpc.schema.json` 的 `ai_*_params/result`（现有 AIUI 测试已经按它们走真服务，PR2b 后改信封不改字段） |
| 规则 | 缺权限时禁止进入创建（UC32）；密钥不进任何状态（UC38）；只接受 HTTPS 或本地 loopback HTTP（UC36）；更改默认尺寸不重建已存在 Desktop |
| 验收 | UC32–UC40 |
| 优先级 | P0；P21/P02/P22 不依赖 PR2b，可紧随 U1b |

### U7 GUI Explorer

| 项 | 内容 |
| --- | --- |
| 页面 | Desktop 详情 › Explorer 标签：P27 新建诊断、P28 执行中、P29 完成；一级 GUI Explorer：跨 Desktop 运行历史（学习层 P2 只放说明） |
| 已有组件 | AIUI-W05/W06 的表单与布局（数据源要重写） |
| 缺失组件 | 诊断范围确认、配置快照显示、模型建议 / 动作回执 / 新观察 / 三值验证同一时间线、计数分离（模型尝试数 vs 输入数） |
| Runtime 方法 | 🧊 `unit.run`（PR2d）；✅ `run.show/events/cancel/list{origin}`；⛔ F40-01 进程内 Durable 入口、F40-02 `Run.unit`、F40-03 unit 事件目录、F40-05 验证谓词 schema |
| Mock 字段 | `unit_run_params{desktopId, mode, goal{description, params}, verification, allowedActions, guiProfileId, expectedProfileRevision, limits{maxSteps, maxSeconds}}` → `Run{kind:"unit"}`；结果只能显示 `Run` 已有字段，`Run.unit` 入 schema 前不 Mock |
| 验收 | UC41–UC48；ADR-06 |
| 优先级 | P0（Explorer 标签）；阻塞 PR2d、X1 |

### U8 菜单栏与退出

| 项 | 内容 |
| --- | --- |
| 页面 | P31 菜单栏弹层（运行状态、打开主界面、打开某个 Desktop 预览、停止所有输入、设置）、P32 退出与后台确认 |
| 已有组件 | 现 `AppController` 的 NSStatusItem 与菜单代理；`DisplayPreview` |
| 缺失组件 | 新菜单内容；退出确认（取消 / 保留后台 / 停止输入并退出，等 `StopAllResult.pending` 清空） |
| Runtime 方法 | ✅ `runtime.stopAll{scope:"all_platform_runs"}`、`runtime.enableInput`、`runtime.status.inputAdmission`、`desktop.list`、`run.wait` |
| Mock 字段 | `StopAllResult{admission, runs[{runId, accepted, phase, quiescence, outcome}], pending}`；`EnableInputResult{admission}` |
| 删除 | D35 所列菜单项与热键 |
| 验收 | UC50、UC51；ADR-09 |
| 优先级 | P0；02 写依赖 A5，实际 `stopAll` 已实现，只有「停止某个 Desktop」等 A5 |

### U9 Inbox、核实、诊断（P1）

| 项 | 内容 |
| --- | --- |
| 页面 | Hub-W06 Inbox、Hub-W07 核实（含 P17 的核实部分）、Hub-W08 诊断与用量（诊断导出） |
| 已有组件 | AIUI-W07 的「只读证据、不重试」规则；AIUI-W08 用量 |
| 缺失组件 | Inbox 列表与处理（permit 一次消费、过期失效）、核实记录（只追加，原 outcome 保持 unknown）、诊断导出（无密钥） |
| Runtime 方法 | 🔖 `inbox.list/show/resolve`、`run.reconcile`、`diagnostics.export`（PR4） |
| Mock 字段 | 无（reserved）。U1 起 Inbox 入口显示「尚未启用：平台审批将在后续版本提供」 |
| 验收 | HB-UI-05…08 |
| 优先级 | P1 |

### HB-UI 用例归属

08 文件只给了 HB-UI 的合并描述。按 Hub v1 第 3.3 节暂定如下，U4、U9 开工前与集成负责人核对编号：

| 编号 | 内容 | 归属 |
| --- | --- | --- |
| HB-UI-01 | 登记、连接、授权三种状态分列 | U4 |
| HB-UI-02 | 服务离线时显示带同步时间的缓存，禁止变更 | U4（U1 Store 提供能力） |
| HB-UI-03 | 正式服务失败不回退样例数据 | U4（全局规则） |
| HB-UI-04 | 撤权提示：应用仍在线、N 个 Run 停止中 | U4 |
| HB-UI-05 | 停止两步：停止中 → 已停止 | U9（U3 已实现同一组件） |
| HB-UI-06 | 核实只追加 | U9 |
| HB-UI-07 | 诊断导出无密钥 | U9 |
| HB-UI-08 | 待核对（Hub v1 §3.3 原文；推测为 Inbox 审批过期与一次消费） | U9 |

### UC 归属总表

| U | UC |
| --- | --- |
| U1 | UC50（与 U8 共用）、UC53、UC54（每个 PR 都跑） |
| U2 | 01 02 03 04 05 06 14 16 19 20 21 49 52 |
| U3 | 07 08 09 10 11 12 13 15 17 18 29 30 31 |
| U4 | 22 23 24 25 |
| U5 | 26 27 28 |
| U6 | 32 33 34 35 36 37 38 39 40 |
| U7 | 41 42 43 44 45 46 47 48 |
| U8 | 50 51 |

---

## 3 分阶段 PR 计划

每个 PR 都交付：页面清单、组件清单、1440×1000 离屏渲染图与对应 `Pxx.webp` 并排、`swift test` 退出码（不经管道）、Runtime 集成情况（真 / Mock）、未完成项与阻塞。真机只在 `/tmp/adt-*` 测试副本做，不碰用户屏幕与登录钥匙串。PR 标题同时写本规划编号与 5c 编号（PR6）。

### 依赖总图

```
U1a UI Shell 库 ──（现在可开工）
A0 ──► U1b 主窗口接线 ──┬─► U2a Desktops（只读 + 创建）──► U2b 预览与并排
                        ├─► U5a Runs 列表与详情（真数据，#41 已合入）
                        ├─► U6a 通用 + 权限
                        ├─► U8 菜单栏与退出
PR2b ──────────────────► U6b AI 设置迁 runtime/1
A5 ────────────────────► U3 控制 ──► U5b 动作记录（request.list/export）
PR2d + X1 ─────────────► U7 Explorer
PR3 + A7 ──────────────► U4 Agents
PR4 ───────────────────► U9 Inbox / 核实 / 诊断
```

### U1a UI Shell 库（PR6-1）

| 项 | 内容 |
| --- | --- |
| 输入 | 本文；Design Guide v2.0 视觉系统（token 数值见 U1 表；Guide 原件在仓外，本 PR 把数值写进仓库）；P01.webp；PR #1 `AppModel` 的代数与轮询 |
| 范围 | 新增 `Sources/AgentDesktopUI/`：`Theme/Tokens.swift`、`Components/`（侧栏、标题栏、状态栏、状态徽章、页面容器四态、样例标识、`ProblemBanner` 迁入并改用 runtime/1 错误码）、`Navigation/MainNavigation.swift`（六个一级入口与二级视图枚举）、`Runtime/RuntimeAPI.swift`（async 端口：`call(method, params)`、`subscribe(after)`）、`Runtime/MockRuntime.swift`（只实现 implemented 方法，返回值逐个用 `RuntimeContract.validate` 校验）、`Store/`（`DesktopStore`、`RunStore` 视图模型：代数、快照 + 事件、游标过期退回快照）、`Pages/Placeholder`（Inbox「尚未启用」）；`Package.swift` 加 target 与 `Tests/AgentDesktopUITests/`；`docs/design/v2/tokens.json` |
| 不改 | 宿主、Runtime、Protocol、AI、GUI、engine |
| 测试 | Mock 每个方法的结果过 schema；Mock 调 reserved 方法得到 `capability_missing`；Store：切换数据源后迟到应答被丢弃；事件游标连续、`events_cursor_expired` 时退回 `run.list`；离屏渲染框架出 PNG（主窗口骨架 + 四态） |
| 验收 | 骨架渲染图与 P01 布局（侧栏 206、标题栏 54、状态栏 28、内边距 32）对照；`swift test` 退出码 0 |
| 阻塞 | 无（`Package.swift` 与 A0 可能有文本冲突，A0 合入后 rebase） |

### U1b 主窗口接线（PR6-2）

| 项 | 内容 |
| --- | --- |
| 输入 | A0 合入后的基线；U1a |
| 范围 | `Sources/AgentDesktop/main.swift`（产品 `.regular`，测试副本 `.accessory`）；`Sources/AgentDesktop/MainWindow.swift`（新，取 PR #1 `MainWindowController` 的关窗不退出与 Dock 重开）；`AppController.swift`：创建进程内 `RuntimeAPI` 实现（后台执行器调用 `RuntimeService.respond`，控制与订阅各一个 `ConnectionState`），`applicationShouldTerminateAfterLastWindowClosed=false`、`applicationShouldHandleReopen`；删除 `AIWindow.swift`；`AgentDesktopAIUI/AIGUIRootView.swift` 删侧栏，页面以视图形式挂进 Settings 与 Desktop 详情（数据源暂不变） |
| 测试 | 进程内端口在非主线程调用（断言）；关窗后 Run 与订阅不受影响（ADR-02 单测：关窗不调用 `connectionClosed`）；T27：AIUI 不再有独立 NavigationSplitView；HostRoleTests 补测试副本无 Dock |
| 验收 | UC50；测试副本真机：开、关、Dock 重开主窗口，宿主与 Desktop 继续 |
| 阻塞 | **A0** |

### U2a Desktops：总览、创建、详情（PR6-3）

| 项 | 内容 |
| --- | --- |
| 范围 | `Sources/AgentDesktopUI/Pages/Desktops/`：`OverviewView`（P01、P03）、`CreateSheet`（P04、P05）、`DetailView`（P06：观察图 + 右侧标签）；Store 接 `desktop.list` 定时快照与 `run.list{active}` 推控制者 |
| 测试 | 创建必填校验；创建中只在请求在途；新 desktopId 出现；搜索无结果与清除；网格/列表切换；空 Desktop 无示例应用；关闭后总览不显示；Runtime 失败显示错误不回退样例 |
| 验收 | UC01、03–06、16、19–21、52；渲染图对照 P01 P03 P04 P05 P06 |
| 阻塞 | U1b；`Desktop.control` 缺失时按降级规则显示 |

### U2b 预览与并排（PR6-4）

| 项 | 内容 |
| --- | --- |
| 范围 | 内嵌实时预览视图（ScreenCaptureKit，按 `screen.displayId`）；P08 独立预览窗口（复用 `DisplayPreview`，按 desktopId 管理，关闭预览不关闭 Desktop）；P07 并排 |
| 测试 | 隐藏预览不改变 Run 与控制；预览缩放不改变 snapshotId；两个 Desktop 并排各自停止（降级为 `run.cancel`） |
| 验收 | UC02、UC14、UC49；渲染图对照 P07 P08；测试副本真机截图 |
| 阻塞 | U2a |

### U5a Runs 列表与详情（PR6-5）

| 项 | 内容 |
| --- | --- |
| 范围 | `Pages/Runs/`：`RunListView`（Hub-W04）、`RunDetailView`（Hub-W05：三轴状态、事件时间线、回执卡按 6.4） |
| 测试 | 事件推进 Run 状态；UI 重载后同一 runId 与历史（ADR-07）；`stopping` 不显示为已停止；`kind=act` 成功显示「已投递」；`delivery=unknown` 无重试按钮 |
| 验收 | ADR-07 界面部分；与 `run.show` 一致性断言 |
| 阻塞 | U1b（#41 已合入，不再阻塞） |

### U6a Settings：通用与权限（PR6-6）

| 项 | 内容 |
| --- | --- |
| 范围 | `Pages/Settings/General`（P21）、`Permissions`（P02、P22，取 PR #1 `PermissionStatus`，与 `runtime.capabilities` 对照）；光标标记开关控制宿主 `AgentCursorOverlay` |
| 测试 | 缺权限不进入创建；两项授权后继续；授权后直接进入创建；默认尺寸只影响新 Desktop |
| 验收 | UC32–UC34；渲染图对照 P02 P21 P22 |
| 阻塞 | U1b |

### U8 菜单栏与退出（PR6-7）

| 项 | 内容 |
| --- | --- |
| 范围 | `AppController.swift` 菜单换成 P31；删除 D35 菜单项与 `HotKey` 使用；`QuitConfirm`（P32：`runtime.stopAll` → 等 `pending` 清空 → 退出） |
| 测试 | 停止所有输入后两类 Run 都进入 stopping 并逐项回执（ADR-09，Mock + 测试副本）；退出等待静止；保留后台不停止任何 Run |
| 验收 | UC50、UC51；ADR-09 界面部分 |
| 阻塞 | U1b |

### U6b AI 设置迁 runtime/1（PR6-8）

| 项 | 内容 |
| --- | --- |
| 范围 | `AgentDesktopAIUI/ContractClient.swift` 换成 runtime/1 端口；`Problem.swift` 改 runtime/1 错误码（按冻结文档 §6 映射）；W01–W04、W08 挂进 Settings（P23–P26、P30），W02 改抽屉 |
| 测试 | 现有 AIUI 测试全部经 runtime/1 重跑；密钥不进状态；非本地 HTTP 被拒；能力测试可取消且四层分开 |
| 验收 | UC35–UC40 |
| 阻塞 | **PR2b** |

### U3 控制（PR6-9）

| 项 | 内容 |
| --- | --- |
| 范围 | `Pages/Desktops/Control/`：P12–P18；控制状态条接 `Desktop.control` |
| 测试 | 停止不是立即终态；静止后才结束；停 A 不影响 B；接管前经过 stopping；交还不重放；未知结果先重新观察才开放结束；新观察不改原回执；关闭保留记录 |
| 验收 | UC07–UC13、15、17、18、29–31；ADR-02 |
| 阻塞 | **A5**（`desktop.stop/takeover/handback/closePlan`、`Desktop.control`）；P17 的核实入口等 PR4 |

### U5b 动作记录与回执（PR6-10）

| 项 | 内容 |
| --- | --- |
| 范围 | P19、P20：`request.list` 筛选分页、`request.export`、回执 JSON 导出、截图下载 |
| 测试 | 回执含 desktopId、requestId、画面 ID；不宣称业务成功；导出 JSON 可读且与 `request.show` 一致 |
| 验收 | UC26–UC28 |
| 阻塞 | **A5**（`request.list/export`）；F1-03、F1-04、F1-05 |

### U7 GUI Explorer（PR6-11）

| 项 | 内容 |
| --- | --- |
| 范围 | 重写 W05/W06 为 Desktop 详情 Explorer 标签（P27–P29）；一级 GUI Explorer 运行历史；W07 规则并入 |
| 测试 | 诊断范围需确认；绑定目标 Desktop；运行快照不被默认配置改；取消等待执行停止；被取消 Desktop 保留；关闭页面 Run 继续（ADR-06） |
| 验收 | UC41–UC48；ADR-06 |
| 阻塞 | **PR2d、X1**；F40-01…F40-05 |

### U4 Agents（PR6-12）

| 项 | 内容 |
| --- | --- |
| 范围 | `Pages/Agents/`：Hub-W01–W03，P09–P11 |
| 测试 | 三种状态分列；只能勾已请求项；撤权提示；离线缓存禁变更；CLI 示例含 desktopId；MCP 配置是有效 JSON；只读检查不接管 |
| 验收 | UC22–UC25；HB-UI-01…04 |
| 阻塞 | **PR3、A7（#29）**；F1-06、F1-07 |

### U9 Inbox、核实、诊断（PR6-13，P1）

| 项 | 内容 |
| --- | --- |
| 范围 | `Pages/Inbox`、`Settings/Verification`、`Settings/Diagnostics` |
| 测试 | 核实只追加；permit 一次消费；诊断导出无密钥 |
| 验收 | HB-UI-05…08 |
| 阻塞 | **PR4** |

---

## 4 阻塞依赖一览

| 依赖 | 状态（2026-10-08） | 阻塞的 UI PR |
| --- | --- | --- |
| A0 仓库收敛 | **未开 PR** | U1b 及之后全部接线 PR |
| PR2b 单端点 + ai.* 迁 runtime/1 | 未开始 | U6b；handshake principal |
| PR2c 产物按 ID | 已合入（#35） | — |
| PR2d `unit.run` 进 RunStore | 未开始 | U7 |
| PR2e `events.subscribe`（#41） | **已合入** | — |
| PR3 身份与授权（A4） | 未开始，`hub.*` 无参数 | U4 |
| A5 Desktop 控制面增量 | 未开始 | U3、U5b；U2 的完整控制者显示 |
| A7 / #29 MCP `--desktop-id` | 草稿 | U4 的 P10 |
| PR4 Inbox / 核实 / 诊断 | 未开始 | U9、U3 的 P17 核实 |
| X1 Explorer 基础 | 未开始 | U7 |

---

## 5 契约缺口清单

只列 UI 需要、而 runtime/1 冻结目录与 03 §3.2 增量都**没有**的内容。03 已列的增量不重复，只在 5.3 给出 UI 侧的优先顺序。按冻结规则第 3 条，所有新增先改 `methods.json` 与冻结文档，再写实现；UI 在此之前不 Mock 这些字段。

**最关键的三条**：F1-01 事件类型目录（没有它 Store 只能按字符串猜状态）、F1-03 回执带出「未发出」原因（6.4 与 RT-24 的界面硬规则无字段可用）、F40-01 主窗口进程内创建平台 Run 的入口（Explorer Durable Run 与人工接管都依赖，UI 不能自己拼）。

### 5.1 交给 2ndscreen-f1（12 条）

| 编号 | 需求 | 现状 | 建议形式 | UI 用途 | 优先级 |
| --- | --- | --- | --- | --- | --- |
| F1-01 | **冻结 RunEvent 的 `type` 目录与各类型 `data` 字段** | `RunEvent.type` 是自由字符串；实际发出 `run.started/finishing/ended/quiescent`、`action.accepted/dispatched/completed/failed/unknown` | schema 里给 `type` 枚举（允许将来加）与每类 `data` 的 `$defs`；`action.*` 的 `data.receipt` 引用 `ActionReceipt` | Store、Runs 时间线、6.4 文案 | P0 |
| F1-02 | **Desktop 级事件** | 订阅只推 Run 事件；`EventFrame.event` 必须是 `RunEvent`（runId 必填） | 全局流增加 `desktop.created/updated/destroyed`（含 `desktopId`、`revision`），或 `Desktop` 增加 `revision` 并允许 `EventFrame` 携带 DesktopEvent；与 03 的 `Desktop.control` 同批 | 总览与控制状态实时更新，去掉 `desktop.list` 轮询 | P0 |
| F1-03 | **回执带出未发出 / 失败原因** | `delivery=not_dispatched` 时原因只在错误响应的 code 里；`ActionReceipt` 无原因字段；`run.events` 与 `request.show` 回看时取不到原因 | `ActionReceipt.error?{code, message}`（不回显参数值），与错误响应的 code 一致 | 6.4「未发出（附原因）」：`target_moved`、`invalid_target`（RT-24）、`input_disabled` | P0 |
| F1-04 | **回执与请求记录带动作摘要** | `ActionReceipt` 不含动作种类；`RequestRecord.outcome` 是无类型 object | `ActionReceipt.action{kind, button?, count?, key?, modifiers?, direction?, textLength?}`（不含键入正文）；`RequestRecord.outcome` 定为 `ActionReceipt \| {error}` 的 oneOf | P19 列表「做了什么」、P20 | P0 |
| F1-05 | **按 snapshotId 取观察（或回执直接带图像 ID）** | 回执只有 `snapshotId`，没有按它取 `Observation` / `ImageArtifact` 的方法 | `observe.show {snapshotId}` → `Observation`（同主体可见），或 `ActionReceipt.imageArtifactId?`；产物保留 24 h 过期时返回 `not_found`，UI 显示「截图已过期」 | P20「查看关联截图」、P17 | P0 |
| F1-06 | **owner 侧待批配对列表** | `hub.pairing.status` 是给发起方等结果的；Owner 在 UI 看不到有哪些待批请求；04 §4.2「是否需要单独方法在 PR3 定稿」 | `hub.pairing.list {state?}` 或 `hub.pairing.open`（打开配对窗口）+ 全局事件 `hub.pairing.requested`；PR3 定稿时一并决定 | Hub-W02 配对 | P0（随 PR3） |
| F1-07 | **只读连接检查** | P09/P10「检查连接」需要看某 desktopId 上是否有外部客户端连着、但不接管 | `hub.connections.list {desktopId?}` 的参数里包含 desktopId 过滤，结果含 `transport` 与最近心跳；随 PR3 定稿 | UC24、UC25 | P0（随 PR3） |
| F1-08 | **`desktop.create` 的 `hiDPI` 参数** | 07 列为 A5 项，03 §3.2 未列 | `desktop_create_params.hiDPI: boolean` | P04 高级尺寸 | P1 |
| F1-09 | **`run.list` 按 `kind` 筛选、按时间范围** | 只有 clientId、origin、phase、desktopId、active | 增加 `kind`、`createdAfter`、`createdBefore` | Runs 筛选；一级 GUI Explorer 历史（外部 `unit.run` 是 origin=agent_hub，只能按 kind 区分） | P0 |
| F1-10 | **`RuntimeStatus` 带权限状态，或 06 改指向 capabilities** | 06 写 `runtime.status` 的 PermissionState，schema 里在 `runtime.capabilities` | 二选一：更正 06；或 `RuntimeStatus.permissions` 可选字段（状态栏轮询 status 时顺带取到） | 状态栏、P22 | P2（文档更正即可） |
| F1-11 | **进程内 Client 与订阅唤醒** | `pendingEventFrames` 只能定时取，没有新事件通知 | 进程内 `RuntimeClient` 实现（A2 范围）提供 async 事件序列或回调；UI 不直接依赖 `ConnectionState` | U1 Store 的事件延迟与 CPU | P0（随 A2） |
| F1-12 | **`runtime.stopAll` 之后的整体静止信号** | `StopAllResult.pending` 是受理时快照；退出确认要等到全部静止 | 全局事件 `runtime.quiescent`，或 `runtime.status` 增加 `pendingStops`；与 F1-02 同批 | P32 退出等待、P31 状态 | P1 |

### 5.2 交给 2ndscreen-40（Explorer 侧，6 条）

| 编号 | 需求 | 现状 | UI 用途 |
| --- | --- | --- | --- |
| F40-01 | **主窗口进程内发起 `unit.run` 的平台入口**：主窗口发起 → `platform / platform_durable / gui_explorer`；线协议一律 Delegated（GX-21） | 进程内只能以 `local:<uid>` 走 `respond`，得到的是 external_client | U7 P27；ADR-06 |
| F40-02 | **`Run.unit` 字段进 schema**：`{mode, goalHash, guiProfileId, guiProfileRevision, inferenceAttempts, inputs, steps, verification{verdict: matched \| contradicted \| inconclusive, predicates[]}}` | 03 §3.3 只有草案；`Run` 是 `additionalProperties:false` | P28/P29 配置快照、计数分离、完成条件 |
| F40-03 | **unit 事件类型目录**：`unit.step.proposed`（模型建议）、`unit.inference.attempt`、`unit.verification`、`unit.progress`、`unit.recovery` 及 `data` 字段 | 未定义 | P28「模型建议不等于已执行」的时间线 |
| F40-04 | **用量按 runId 汇总**：`ai.usage.summary` 增加可选 `runId`；或 `Run.unit.inferenceAttempts` 带 token 计数（未报告保持 null） | 只能按时间与 connectionId 查 | P29、P30「本次诊断汇总」 |
| F40-05 | **验证谓词 schema 迁入 runtime.schema.json**（`unit_run_params.verification` 现在只是 object） | PR2d 计划内 | P27 完成条件表单校验 |
| F40-06 | **启动前置检查**：Desktop 控制被占用、GUI 配置停用、能力不匹配时 `unit.run` 返回的错误码与 `details.reason` 固定（如 `control_busy`、`conflict{reason:"disabled"}`、`capability_missing`） | 未写明 | P27「控制权已占用或连接已禁用时不能启动」 |

### 5.3 03 §3.2 已列增量的 UI 优先顺序（不新增，只排序）

1. `Desktop.control`（U2 控制者、U3 全部）
2. `desktop.stop`（U3、U8 单 Desktop 停止）
3. `desktop.takeover` / `desktop.handback`（U3）
4. `desktop.closePlan`（U3 P18）
5. `request.list` / `request.export`（U5b）
6. ActionReceipt 的 `businessResult`、`clientId`、`elapsedMs`（U5）
7. `desktop.create` 的 `launch` / `bind`（U2 一步创建）
8. `desktop.resize`（U2 尺寸菜单）
9. 新错误码 `target_moved`、`grant_missing`、`pairing_required`、`client_revoked`、`audit_unavailable`（错误文案）

---

## 6 第一阶段之后

下一步开 U1a（不依赖 A0）。A0 合入后在新基线上开 U1b，再按第 3 节依次推进。本文随依赖状态变化更新「阻塞依赖一览」；契约缺口由集成负责人确认后改成 issue 编号。
