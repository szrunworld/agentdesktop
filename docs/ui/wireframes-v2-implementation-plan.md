# Product Design v2.0 线框落地方案（可执行版）

依据：`~/Downloads/AgentDesktop-Product-Wireframes-v2.0.html`（32 个场景的可点击原型）与 `AgentDesktop-Design-Guide-v2.0.html`（设计册）。32 张 1440×1000 渲染图已存入 `docs/design/v2/P01.webp … P32.webp`，作为界面验收的视觉基准。

基线：`ai-gui-foundation@890195d`。设计稿与 CLI 方案不一致时以设计稿为准（Kevin，2026-10-08）。

## 0 范围与分工

| 项 | 决定 |
| --- | --- |
| 首发界面 | P01–P32：主窗口、独立预览、菜单栏三个表面，统一以 desktopId 为入口 |
| 不做 | Agent Hub、市场、组织后台、业务审批箱、全局模型预算（设计稿明确排除） |
| GUI Explorer G01–G08 | 学习层（PR4）已暂缓；只在 Desktop 详情右侧标签里预留 Explorer 入口位，不实现 |
| 主窗口与菜单栏界面 | 2ndscreen-1d 会话 |
| Runtime 能力补齐（下文 R01–R12） | 2ndscreen-5c 会话 |
| 合同字段 | 由 Runtime 一方维护；界面一方只消费，改字段先在 PR 里对齐 |

界面一律通过 Runtime 合同读写，与 CLI、MCP 走同一个 router。界面不直接调用输入引擎，不自建状态机，不用定时器伪造进度。设计册原话："本原型的 setTimeout 仅用来演示异步过程，正式产品必须由真实 Runtime 事件推进。"

## 1 前置（U0）

1. 把 ai-gui-foundation rebase 到含单仓迁移 #20 的 main，解决 Package.swift 与 Sources/AgentDesktop 的冲突，合入 PR #2。现在 foundation 仍依赖 2ndscreen 包，这一步之后界面代码只面对单仓。
2. 合入 #29（MCP stdio 与薄 SDK），后续 R09 在它上面加 `--desktop-id`。
3. 决定旧 2ndscreen 菜单（主虚拟显示、分辨率、HiDPI、搬窗口热键、按 screen 列出的 Agent Screens）的去留。建议：从产品里删除，测试副本也不保留。设计稿里没有这些功能。

## 2 界面架构

新建 target `AgentDesktopUI`（SwiftUI），宿主 `Sources/AgentDesktop` 只负责组装窗口与菜单栏。现有 `AgentDesktopAIUI`（W01–W08）在 U7 并入，作为可选分组。

| 层 | 内容 |
| --- | --- |
| Theme | 设计 token：画布 #f5f6f2、面板 #ffffff、主文字 #25352c、主色 #416b53、选中 #e0e9d8、边界 #dfe4dc；标题 27/17、正文 14、说明 12、标识 10–12；间距 4/8/12/16/24/32；按钮最小高 36、圆角 7；面板圆角 12；侧栏 206、标题栏 54、状态栏 28、内容内边距 32；状态色语义：绿运行、灰就绪/停止、琥珀接管/等待/未知、红停止类与错误，且必须配文字 |
| Store | `DesktopStore`（@MainActor ObservableObject），进程内 contract client，身份为本机 owner。对外暴露 desktops、status、activity、permissions。刷新：U1–U2 用 1 s 轮询 `runtime.status` + `desktop.list`；R12 落地后改为事件游标。按代数丢弃过期结果，轮询只保留一份（A02 复核时修过的两个缺陷，这里沿用同样的写法） |
| 组件 | 设计册建议的八个：DesktopCard、DesktopViewport、ConnectionPanel、ControllerBanner、ActionReceipt、SettingsPanel、ConfirmationDialog、ProviderForm；另加 StateBadge、CodeBox（复制）、EmptyState、SideNav、StatusBar |
| 画面 | DesktopViewport 用 ScreenCaptureKit 捕获 Desktop 所在 screen（`Desktop.screen.displayId`），显示尺寸、scale、frameId；预览缩放不改变 frameId |
| 窗口 | 主窗口（`.regular`，有 Dock 图标；关闭后转后台，可在设置里改）、每个 desktopId 一个独立预览窗口（关闭预览不关闭 Desktop）、菜单栏弹层；三者读同一个 Store |
| 测试副本 | 仍为后台角色：无主窗口、无 Dock、无菜单栏 |

## 3 页面与数据来源

"现有"指 runtime/v1 已有的方法；"缺"指需要 Runtime 先补的能力（编号见第 4 节）。

| 场景 | 现有方法 | 缺 | PR |
| --- | --- | --- | --- |
| P01 Desktop 总览（网格/列表、筛选、搜索、最近动作） | desktop.list、runtime.status | R01 控制状态与控制者、R08 最近动作 | U2 |
| P02 首次使用与权限 | runtime.status 的 PermissionState | — | U6 |
| P03 没有 Desktop | desktop.list | — | U2 |
| P04 创建 Desktop（命名、启动应用 / 绑定窗口 / 空、高级尺寸） | desktop.create、app.list、app.launch、window.list、window.bind | R06 一步创建并启动或绑定、creating 态 | U2 |
| P05 正在创建 | — | R06、R12 | U2 |
| P06 单个 Desktop（画面、连接/输出/详情标签、复制 desktopId、导出截图与 trace） | desktop.show、observe | R01、R07、R08 | U2 |
| P07 两个并排 | 同 P06 | R01 | U2 |
| P08 独立预览窗口 | desktop.show | — | U2 |
| P09 CLI 接入 | runtime.handshake（只读检查） | — | U4 |
| P10 MCP 接入 | runtime.handshake | R09 `mcp --desktop-id` | U4 |
| P11 ACP 可选连接 | — | 无实现；页面写明"可选，未提供适配器"，按钮禁用 | U4 |
| P12 人工接管确认 | — | R04 | U3 |
| P13 人工控制中 | — | R04 | U3 |
| P14 正在停止 | run.cancel（已有 cancelling、quiescent） | R02 按 desktop 停止 | U3 |
| P15 输入已停止 | — | R02 | U3 |
| P16 Agent 连接断开 | run 的 interrupted | R10 断连态 | U3 |
| P17 动作结果未知 | request.show、observe | R01 unknown 态 | U3 |
| P18 关闭 Desktop（说明将释放什么） | desktop.destroy | R05 先停后关与释放清单 | U3 |
| P19 操作记录（按 Desktop/状态筛选、搜索 requestId、导出） | request.show | R08 | U5 |
| P20 动作回执与输出 | request.show | R07 | U5 |
| P21 通用设置（关窗转后台、光标标记、默认尺寸） | — | 本地偏好，不需要 Runtime | U6 |
| P22 系统权限缺失 | PermissionState | — | U6 |
| P23–P30 AI 与 GUI（可选） | ai/gui 现有操作 | — | U7 |
| P31 菜单栏快速控制 | 同 Store | R03 停止所有输入 | U8 |
| P32 退出与后台行为 | — | R03（退出前等输入停手） | U8 |

## 4 Runtime 需要补的能力（交给 2ndscreen-5c）

| 编号 | 能力 | 建议合同形态 |
| --- | --- | --- |
| R01 | Desktop 控制状态与控制者 | `Desktop.control = {state, controller?}`。state 取 creating / ready / running / manual / stopping / stopped / disconnected / unknown / error；controller 含 clientName、transport（cli、mcp、acp、ui）、since、actionCount。保留现有 `state` 字段作生命周期 |
| R02 | 按 desktop 停止输入 | `desktop.stop {desktopId}`：撤销写权限、清空待执行输入、释放按住的键，回执分"已受理"与"执行端已停"两步 |
| R03 | 停止所有输入 | `runtime.stopAll`，逐个 desktop 回执 |
| R04 | 人工接管与交还 | `desktop.takeover` 等当前输入停手后把控制者设为 ui；`desktop.handback` 后重新观察、等待新连接，不重放旧队列 |
| R05 | 先停后关，并给出释放清单 | `desktop.destroy` 先执行 R02；另加只读 `desktop.closePlan` 列出将结束的专有进程、保留的宿主共享进程、画面资源和结果文件，供 P18 弹窗显示 |
| R06 | 一步创建 | `desktop.create {name, launch?: {bundleId}, bind?: {pid, windowId}, size?}`，返回 creating，失败保留错误与重试 |
| R07 | 回执字段 | 加 frameId（现 snapshotId，统一命名）、`businessResult: "not_evaluated"`、elapsedMs、caller |
| R08 | 操作记录 | `activity.list {desktopId?, state?, query?, cursor, limit}` 覆盖输入、观察与生命周期事件；`activity.export` 输出 JSON 与图像 |
| R09 | 按 desktopId 直接调用 | observe 与 act 可只给 desktopId，Runtime 隐式建立 session；`agentdesktop mcp --desktop-id X` 把 MCP 限定到一个 desktop；CLI `--json` 别名 |
| R10 | 断连态 | 控制者连接断开时 desktop 进 disconnected，不自动接回、不把未知改为未执行 |
| R11 | 权限检查 | 已有 PermissionState，补"未授权时拒绝创建需要该权限的资源"并给出恢复入口 |
| R12 | 事件游标 | `desktop.events {afterSequence}`，界面和外部 Agent 共用，替代轮询 |

R01、R02、R04、R07 是 U3 的硬前置。R12 不阻塞任何界面，先用轮询。

## 5 PR 顺序与验收

| PR | 内容 | 前置 | 验收 |
| --- | --- | --- | --- |
| U0 | rebase、合 #2 #29、删旧菜单 | — | `swift test` 全过（看退出码）；CI 绿；产品包不再有虚拟显示菜单 |
| U1 | AgentDesktopUI target、Theme、主窗口框架（侧栏、标题栏、状态栏）、Store、Dock 与关窗转后台、空菜单栏 | U0 | 主窗口快照与 P01 布局尺寸一致；Store 测试：过期结果被丢弃、轮询唯一 |
| U2 | P01 P03 P04 P05 P06 P07 P08 | U1；R01 R06 缺失时显示降级文案 | 测试副本里创建两个 desktop，总览、详情、并排、独立预览都显示真实画面；关闭预览后 desktop 仍在 |
| U3 | P12–P18 | R01 R02 R04 R05 R10 | 停止 A 时 B 继续；停止中到已停止必须等执行端回执；接管后外部 act 被拒；断连显示 disconnected；unknown 不提供重做；关闭不结束宿主共享应用 |
| U4 | P09–P11 | U1；P10 需 R09 | 复制的 CLI 命令和 MCP JSON 在测试副本上实际可用；"检查连接"不抢占控制权 |
| U5 | P19 P20 | R07 R08 | 外部 CLI 发出的动作出现在记录里，requestId、frameId、desktopId 对得上；导出文件可读 |
| U6 | P02 P21 P22 | U1 | 权限缺失时创建被拒并显示恢复入口；偏好保存后不重建已有 desktop |
| U7 | P23–P30：把 W01–W08 改为侧栏可选分组并换主题；P24 改右侧抽屉；P27 从 Desktop 发起 | U1 | 未配置 AI 时主线全部可用；现有 AIUI 测试保持通过 |
| U8 | P31 P32 菜单栏与退出 | R03 | 主窗口隐藏后菜单栏可停止所有输入；退出前等输入停手 |

U1、U4 的 CLI 部分、U6、U7 可以与 Runtime 补齐并行；U2 先做现有方法能支撑的部分。

## 6 验收方法

- **不碰用户屏幕。** 所有运行验收在 `/tmp/adt-*` 下的测试副本里做，socket 路径不超过 104 字节，测试副本的凭据存文件不进登录钥匙串。
- **视觉对照。** 每个场景用 `ImageRenderer` 或 `NSHostingView.cacheDisplay` 在测试进程里渲染成 1440×1000 PNG，放进 PR 的 `docs/acceptance/ui-<PR>/`，与 `docs/design/v2/Pxx.webp` 并排对照。这样不需要截屏用户桌面。
- **行为验收。** 每个 PR 列出对应场景的"关键规则"（设计册每页都有），逐条写成测试或真机记录；只有执行过的断言才标通过。
- **最终产品验收。** U3 合入后，用产品界面重跑 M0：两个 desktop 由两个外部调用端并发驱动，宿主由人操作，P07 并排视图和 P19 操作记录作为证据的一部分。

## 7 待定事项

| 事项 | 建议 |
| --- | --- |
| 旧虚拟显示与搬窗口功能 | 删除 |
| frameId 与 snapshotId 命名 | 合同统一为 frameId，snapshotId 保留一个版本的别名 |
| ACP | 页面占位，适配器等有真实调用方时再做 |
| 响应式 760/390 单列 | 不做；设计册注明仅为审阅方便，不代表手机产品 |
| Windows 界面 | 不在本方案；C# 侧跟随 Runtime 合同 |
