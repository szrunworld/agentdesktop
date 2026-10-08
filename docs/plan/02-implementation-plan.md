# 2 实施计划

## 2.1 工作线与负责人

| 工作线 | 范围 | 建议负责人 |
| --- | --- | --- |
| 集成负责人 | 公共契约（contracts/runtime/v1）、合并顺序、跨模块 E2E、发布门禁 | **2ndscreen-f1（原 5c）**（已确认；已实现 #21 #25 #26 #33 #34） |
| L-Runtime | AgentDesktopRuntime、执行器、账本、Hub Core 的 Runtime 侧、CLI、MCP、SDK | **2ndscreen-f1**（已确认） |
| L-AIGUI | AgentDesktopAI、AgentDesktopGui（Explorer）、迁入 runtime/1、学习层 | **2ndscreen-40**（已确认；原名 1d） |
| L-UI | 主窗口、导航、各页面、菜单栏、预览窗口（U1–U9） | **新建独立会话**（已确认）。只经统一 Runtime Client 与 Store 接入，不自定状态机或 API |
| L-Win | Windows C# 对等实现与契约一致性 | **2ndscreen-40**（暂时确认，后续可再拆） |

规则：公共契约只由集成负责人改；其他线需要新字段时提 issue 或在 A1 之后的契约 PR 里加；各线不得各自定义临时状态机。

## 2.2 与 2ndscreen-f1 的 PR 编号对照

5c 在冻结文档里用 PR1–PR7 编号。本规划的 A、U、L 编号与之对应如下；以后 PR 标题同时写两个编号，避免两套计划。

| 本规划 | 5c 编号 | 状态（2026-10-08 更新） |
| --- | --- | --- |
| （Run 模型） | PR1（#33） | 已合入 |
| A1 契约冻结 | PR2a（#34）；增量 #45 | 已合入 |
| A0 仓库收敛 | 无（#47） | 已合入 6c18480。SEC-01（`ai.sqlite` 为 0644）未过，归 2ndscreen-40 |
| A3 执行修正：G0 窗口一致性（RT-24） | 无（#51） | 已合入 b2831ca，真机记录 docs/acceptance/g0-window-identity-2026-10-08.md |
| A3 执行修正：AX 隔离（RT-23A/B） | 无 | 进行中（2ndscreen-f1，下一项） |
| A2 单一端点 | PR2b | 未开始，排在 AX 之后 |
| 产物按 ID 读取 | PR2c（#35） | 已合入 |
| A6 unit.run 落 RunStore | PR2d（#50 草案） | 草案审核中；排在 PR2b 之后 |
| 事件订阅 | PR2e（#41） | 已合入 |
| A4 Hub Core 身份与授权 | PR3 | 未开始 |
| A5、A7 | 无 | 未开始 |
| U9 Inbox、核实、诊断 | PR4 | 未开始 |
| U1a 界面库 | PR6-1（#52） | **已合入 614ea7e，组件验收通过**：AgentDesktopUI（token、组件、页面四态、导航、RuntimePort、Mock、Store、离屏出图），398 项测试，与 A0/G0 后基线合并 404 项通过。P01、P06、P19、P21 只是组件样张，**不计正式页面交付**；页面以端到端验收为准 |
| U1b-1 主窗口结构与页面接线 | PR6-2（#71） | **已合入 604b5dd**：唯一主窗口、六个入口、Desktops 与 Runs 接进程内 Runtime（轮询，页面不感知轮询或推送）；删除独立 AI 窗口与旧引擎菜单。与 e920ae6 合并后本地 468 项测试通过（CI 因 Actions 额度未运行）。AIUI `ui004` 偶发失败由 #75 跟踪 |
| U1b-2 事件驱动集成 | PR6-3 | 等 PR2b：切到事件推送、状态同步、断连与重连 |
| U2a Desktops 与预览 | PR6-3（#98） | 未合入。Kevin 2026-10-08：实时预览改走 ScreenCaptureKit、不经 `observe`、不持久化每一帧（D48）；完成资源与生命周期测试后再合 |
| U8 菜单栏与退出 | PR6-4（#101） | 未合入，已与 #98 解耦。合并条件：CI 全绿 + UC51 真机验收（先查清副本 A 消失原因；不建虚拟显示器；Runtime 正常、断连、无响应三种情况；不得造成 WindowServer 卡死，不绕过运行中任务的安全收尾） |
| 产物运行期间过期 | #110 | 未合入，可独立推进。合并条件：f1 审核 + 验证运行期间清理生效；不改冻结契约 |
| U2b–U5 | PR6 | 按 2.4 依赖逐项开工 |
| U6 设置 | PR6 | 等 PR2b |
| U7 Explorer 标签 | PR6 | 等 A6、X1 |
| L1–L4 学习层 | PR7 | P2 |

执行顺序（Kevin 确认）：A0 → G0 → AX → PR2b → A6。UI 只消费 Runtime 的状态和能力；UI 与 Runtime 独立演进，页面层只依赖冻结接口。

**foundation → main（Kevin 2026-10-08 批准）**：先修 SEC-01（`ai.sqlite` 0600、已有文件的权限修复、敏感目录 0700，在干净实例上验证）→ 重跑全量 CI、契约测试与 macOS 冒烟 → 集成负责人通过 PR #2 合入 main（不直接推送 main）→ 之后新分支从 main 创建，foundation 不再作为长期主线，进行中的 AX、PR2b、A6、U1b 在合适节点对齐 main。

**已完成**：#2 于 2026-10-08 合入 main（134b451）。从此 AgentDesktop 所有新 PR 以 `main` 为目标分支；`ai-gui-foundation` 只保留历史，不再作为集成分支。并行的 PR 之间不引入不必要的依赖，各自验收、各自合并；不自动合并。

**验收口径**：组件验收（单元测试、离屏样张）与端到端页面验收（真实 Runtime、真实 macOS 窗口截图、交互验证、Wireframes 对照）分开记录；只有后者计为页面交付。

## 2.3 阶段与依赖

```
A0 仓库收敛 ─ A1 契约冻结 ─┬─ A2 单端点 ─┬─ A4 Hub Core ─ A7 CLI/MCP/SDK
                          │             ├─ A5 Desktop 控制面
                          │             └─ A6 AI/GUI 迁入 ─ X1 Explorer 基础
                          └─ A3 执行修正（与 A2 并行）
U1 界面骨架（A1 后即可）─ U2…U9（各自依赖见表）
发布门禁 G：A0–A7、X1、U1–U8 完成后在同一提交上跑 08 文件全部套件
P2：L1–L4 学习层，M1–M2 设备后端，U9 剩余 Hub 页面
```

| 阶段 | 内容 | 优先级 |
| --- | --- | --- |
| Foundation | A0–A3 | P0 |
| Hub Core 与控制面 | A4、A5、A7 | P0 |
| Explorer 基础 | A6、X1 | P0 |
| 主界面 | U1–U8 | P0（U7 Explorer 标签为 P0，U9 为 P1） |
| Hub 完整管理 | U9：Inbox、核实、诊断与用量 | P1 |
| 学习层 | L1–L4 | P2（独立阶段） |
| 设备 | M1 Android、M2 iPhone | P2 |

## 2.4 PR 清单

每个 PR 的「验收」只认执行过的断言、退出码与真机记录；测试编号见 08 文件。

### A0 仓库收敛（L-Runtime）

| 项 | 内容 |
| --- | --- |
| 输入 | main@501ff01（含 `engine/`）、ai-gui-foundation@c8833c4、PR #2 |
| 范围 | foundation rebase 到 main；新 Runtime、App 链接本地 `engine/` 的 SecondScreenCore / SecondScreenRuntime，删除远程 2ndscreen pin；`agentdesktop-cli` 退出发布路径，只发布新的 `agentdesktop`；合入 #2 到 main |
| 测试 | `swift test`（根包与 engine 包）、Windows CI、`scripts/verify-command-surface.py` 更新为新命令面 |
| 验收 | A0 合入后它就是唯一代码基线，必须证明：不再有远程 `2ndscreen` 依赖（干净 checkout 无网络下载，整合设计 T30）；新 Runtime 使用仓库内的 `engine/`；只发布一个正式 CLI；只有一个 Runtime 入口；`engine/` 旧 AgentRuntime 与新 AgentDesktopRuntime 不分别维护执行状态（旧控制 socket 不再由产品启动）；现有全部测试通过；真机重跑 Stage 0 与 run-model 验收记录里的创建、截图、动作、停止；SEC-01…SEC-05 通过（见 08 文件） |

### A1 契约冻结（集成负责人）——已由 #34（PR2a）完成目录冻结；以下为剩余部分

| 项 | 内容 |
| --- | --- |
| 输入 | 03 文件；现有 runtime/v1 与 ai-gui/v1 operations.json |
| 范围 | AgentDesktopContracts 并入 AgentDesktopProtocol；methods.json 增补 03 文件 3.2 全部方法（含 P1/P2 标记）；errors.json 增补；schema 增补对象；正负 fixtures；Swift 与 C# golden |
| 测试 | CT-01…CT-08 |
| 验收 | 两种语言用同一 golden 逐字节一致；方法重复注册失败；ai/1 信封不再被解码 |

### A2 单一端点（集成负责人主导，L-AIGUI 配合）

| 项 | 内容 |
| --- | --- |
| 输入 | A1 |
| 范围 | RuntimeService 改为 async handler registry；AI 处理器改接 CommandContext；删除 RpcSocketServer 与 ai.sock；UI 走进程内 Client 同一 router |
| 测试 | 现有 AI/GUI 测试经 runtime/1 重跑；RT-01、RT-02 |
| 验收 | 宿主只监听一个 endpoint；`ai.*` 全部经 runtime/1 可用 |

### A3 执行修正（L-Runtime）

| 项 | 内容 |
| --- | --- |
| 输入 | Explorer 方案 B01–B10、`docs/migration/runtime-semantics-to-port.md` 七项接缝、M0 中性预演误点记录 |
| 范围 | **观察与输入同一目标**（MAC-001，PR #37）：截图、元素与输入必须针对同一个绑定窗口；截图按 windowId 取窗口图像而不是整屏，或在整屏截图时核对绑定窗口在最上层且未被遮挡；目标被遮挡或不在最上层时 act 返回 `target_moved` 或 `invalid_target`，dispatch=0；回执的 confirmed 只表示投递，不表示目标窗口已变化。**AX 观察的故障隔离**（MAC-001：Safari 网页 AX 遍历拖住宿主）：AX 遍历不在主线程、不在持有 Desktop 执行锁时进行；有总 deadline，同时限制节点数、遍历深度与单个 AX 查询等待；超时后立即停止接受该遍历的新工作；无法中断的底层 AX 调用放在隔离的有界执行资源里，不能占满共享执行资源；同一 Desktop 连续超时时后台遍历数有上限，不无限积累；超时返回成功、降级结果（只有截图、元素列表标为 partial）或明确错误。仅给外层 Task 加超时不算完成。**存储权限**：`ai.sqlite` 等配置库与账本 0600、目录 0700，数据库只存凭据引用，密钥在系统安全存储。每 Desktop 串行执行器（不同 Desktop 并发）；动作在原生入口重验几何与代次，不一致返回 `target_moved`；动作前后 captureSequence 栅栏；dispatch_intent 先落盘；停止先关准入再等在途动作；审计写失败返回 `audit_unavailable` 并暂停输入；模型请求可取消 |
| 测试 | RT-03…RT-12、RT-23A、RT-23B、RT-24、SEC-01…SEC-05 |
| 验收 | M0 误点复现用例改为被拒绝且 dispatch=0；两 Desktop 并发、同 Desktop 有序；无静默前台回退 |

### A4 Hub Core（L-Runtime）

| 项 | 内容 |
| --- | --- |
| 输入 | A2；04 文件；Hub v1 第 6–9 节；HUB-B01…B06 |
| 范围 | Client 注册表、配对（短码与一次确认）、凭据签发与撤销、Grant（能力、Desktop、目标应用、期限、限额）、policyEpoch 在原生入口生效、Connection 状态与心跳、clientId 维度的数据隔离 |
| 测试 | HB-01…HB-14、ADR-01、ADR-03…ADR-05 |
| 验收 | 撤权后零越权输入；未配对调用 `pairing_required`；跨 client 零泄漏；重连 connectionId 变、clientId 不变、旧 Run 不恢复 |

### A5 Desktop 控制面（L-Runtime）

| 项 | 内容 |
| --- | --- |
| 输入 | A2；03 文件 3.2 desktop 族与 request 族 |
| 范围 | `Desktop.control`；`desktop.stop/takeover/handback/closePlan`；`desktop.create` 一步启动或绑定；`app.quit`；`request.list/export`；`run.reconcile`；ActionReceipt 新字段；`events.subscribe`；Action 增加 hover、drag、press |
| 测试 | RT-13…RT-22 |
| 验收 | 停止 A 时 B 继续；接管后外部动作被拒；交还后不重放；关闭不结束宿主共享应用；unknown 只追加核实 |

### A6 AI/GUI 迁入统一 Runtime（L-AIGUI）

| 项 | 内容 |
| --- | --- |
| 输入 | A2、A3；整合设计 P03–P04；05 文件 |
| 范围 | `unit.run` 替代 `gui.runs.*`，Explorer 运行进 RunStore。**所有权只由已认证主体决定**：主窗口在进程内经 Runtime 创建 Durable Run（platform / platform_durable / gui_explorer），不经过线协议；任何线协议上的 `unit.run`（CLI、MCP、SDK、外部 App，含本机 owner 的线连接）都是 Delegated Run；参数里的 `origin`、`lifetime`、`ownership` 一律拒绝（`ownership_escalation_denied`），不得因 A6 接入破坏 #33 已实现的边界。AiService 唯一推理账本，删除 GuiAuditPort 重复记账；GuiRunBinding 的 inferenceBinding 可空；RunRecorder 去掉 `try?` 吞错 |
| 测试 | GX-01…GX-12、GX-21、ADR-05…ADR-08、ADR-10 |
| 验收 | 推理尝试只记一次；模型 finish 不等于成功；关闭 Explorer 页面运行继续 |

### X1 Explorer 基础能力（L-AIGUI）

| 项 | 内容 |
| --- | --- |
| 输入 | A6；05 文件第 2 节 |
| 范围 | 三值验证（matched / contradicted / inconclusive）与首批谓词；进展与循环检测；有界恢复；学习预留字段落库 |
| 测试 | GX-13…GX-20 |
| 验收 | 不完整观察下 not(found) 为 inconclusive；同名控件歧义 dispatch=0；无进展有界结束 |

### A7 CLI / MCP / SDK 对齐（L-Runtime）

| 项 | 内容 |
| --- | --- |
| 输入 | A4、A5；PR #29 |
| 范围 | #29 rebase；`agentdesktop mcp --desktop-id`；CLI 支持只给 desktopId 的 observe/act；`--format json|jsonl|text`；Python 与 TypeScript SDK 加配对与凭据；中性示例客户端 `examples/neutral-agent`（Python） |
| 测试 | SDK-01…SDK-06 |
| 验收 | 中性 Python 客户端完成配对、授权、动作、断开、重连；SDK 与 CLI 结果一致 |

### U1–U9 界面（L-UI）

详细页面见 06 文件；每个 U 的验收包含对应 UC 检查与关键规则。

| PR | 内容 | 依赖 | 验收 |
| --- | --- | --- | --- |
| U1 | AgentDesktopUI target、主题 token、主窗口框架（侧栏 206、标题栏 54、状态栏 28）、六个一级入口（Inbox 在 U9 前显示明确的「尚未启用」状态，不放静态假数据）、进程内 Client 与 Store（按代数丢弃过期结果、轮询或事件唯一）、Dock 与关窗转后台；删除 AIGUIRootView 独立侧栏 | A1 | 渲染图与 P01 布局对照；UC50；整合设计 T27 |
| U2 | Desktops：P01 P03 P04 P05 P06 P07 P08（预览走 ScreenCaptureKit，按 desktopId 的独立预览窗口） | U1、A5（creating 与 control 字段缺失时显示降级文案） | UC01–UC06、UC14、UC16、UC19–UC21、UC49、UC52 |
| U3 | 控制：P12–P18 | A5 | UC07–UC13、UC15、UC17、UC18、UC29–UC31；ADR-02 |
| U4 | Agents：Agent 总览、接入（P09–P11 + Hub W01–W03 配对与授权） | A4、A7 | UC22–UC25；HB-UI-01…04 |
| U5 | Runs：全部运行、运行详情（Hub W04–W05）、动作记录与回执（P19–P20） | A5 | UC26–UC28；ADR-07 |
| U6 | Settings：通用（P21）、权限（P02、P22）、AI 连接与 GUI 配置与能力测试与用量（P23–P26、P30） | U1、A2 | UC32–UC40 |
| U7 | Desktop 详情 Explorer 标签：发起与观察 GUI 运行（P27–P29）；一级 GUI Explorer 显示跨 Desktop 的运行历史。两个入口是同一 RunStore 的两个视图，不是第二个主窗口或第二套执行系统 | X1 | UC41–UC48；ADR-06 |
| U8 | 菜单栏（P31）、退出与后台（P32） | A5 | UC50、UC51；ADR-09 |
| U9 | Inbox（W06）、核实（W07）、诊断与用量（W08） | A5、inbox 方法 | HB-UI-05…08（P1） |

### L1–L4 学习层（L-AIGUI，P2，独立阶段）

见 05 文件第 4 节。

### M1–M2 设备后端（P2）

| PR | 内容 | 依据 |
| --- | --- | --- |
| M1 | Android：`engine/optional/mobile` 迁成 `AgentDesktopAndroid` target，设备服务进 Runtime，device 目标类型，手机窗口为呈现层 | 总计划 v2.1 第 17A 节 |
| M2 | iPhone Mirroring：粘贴确认、剪贴板租约与无损快照、窗口与几何绑定；WDA 作为完整手势基线另行评估 | iPhone 实现审查 |

## 2.5 合并顺序

A0 → A1 → A2 与 A3 并行 → A4、A5、A6 并行 → X1、A7 → U2–U8 按依赖逐个 → 发布门禁 G。U1 在 A1 后即可开始。每个 PR 合入 main 前 CI 全绿（2026-10-08 起目标分支统一为 main，见 2.2）。
