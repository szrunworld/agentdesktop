# 2 实施计划

## 2.1 工作线与负责人

| 工作线 | 范围 | 建议负责人 |
| --- | --- | --- |
| 集成负责人 | 公共契约（contracts/runtime/v1）、合并顺序、跨模块 E2E、发布门禁 | 2ndscreen-5c（Runtime 会话，已实现 #21 #25 #26 #33） |
| L-Runtime | AgentDesktopRuntime、执行器、账本、Hub Core 的 Runtime 侧、CLI、MCP、SDK | 2ndscreen-5c |
| L-AIGUI | AgentDesktopAI、AgentDesktopGui（Explorer）、迁入 runtime/1、学习层 | 2ndscreen-40（原 1d）（已实现 #3–#8 #11 #13 #18） |
| L-UI | 主窗口、导航、各页面、菜单栏、预览窗口 | 待指派。09:40 决定是 2ndscreen-40；若 1d 同时负责 L-AIGUI，建议另开一个会话专做 UI |
| L-Win | Windows C# 对等实现与契约一致性 | 2ndscreen-40（已有 #16 #22 #23） |

规则：公共契约只由集成负责人改；其他线需要新字段时提 issue 或在 A1 之后的契约 PR 里加；各线不得各自定义临时状态机。

## 2.2 阶段与依赖

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

## 2.3 PR 清单

每个 PR 的「验收」只认执行过的断言、退出码与真机记录；测试编号见 08 文件。

### A0 仓库收敛（L-Runtime）

| 项 | 内容 |
| --- | --- |
| 输入 | main@501ff01（含 `engine/`）、ai-gui-foundation@c8833c4、PR #2 |
| 范围 | foundation rebase 到 main；新 Runtime、App 链接本地 `engine/` 的 SecondScreenCore / SecondScreenRuntime，删除远程 2ndscreen pin；`agentdesktop-cli` 退出发布路径，只发布新的 `agentdesktop`；合入 #2 到 main |
| 测试 | `swift test`（根包与 engine 包）、Windows CI、`scripts/verify-command-surface.py` 更新为新命令面 |
| 验收 | 干净 checkout 不下载 2ndscreen（整合设计 T30）；产品包只有一个 CLI；现有 349 项测试全过 |

### A1 契约冻结（集成负责人）

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
| 范围 | observe 与截图不得在持有 Desktop 锁时做无总时限的 AX 遍历，单次 deadline、离开主线程、超时返回明确错误（MAC-001：Safari 网页 AX 遍历拖住宿主）；每 Desktop 串行执行器（不同 Desktop 并发）；动作在原生入口重验几何与代次，不一致返回 `target_moved`；动作前后 captureSequence 栅栏；dispatch_intent 先落盘；停止先关准入再等在途动作；审计写失败返回 `audit_unavailable` 并暂停输入；模型请求可取消 |
| 测试 | RT-03…RT-12、RT-23 |
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
| 范围 | `Desktop.control`；`desktop.stop/takeover/handback/closePlan`；`desktop.create` 一步启动或绑定；`app.quit`；`request.list/export`；`action.reconcile`；ActionReceipt 新字段；`runtime.events`；Action 增加 hover、drag、press |
| 测试 | RT-13…RT-22 |
| 验收 | 停止 A 时 B 继续；接管后外部动作被拒；交还后不重放；关闭不结束宿主共享应用；unknown 只追加核实 |

### A6 AI/GUI 迁入统一 Runtime（L-AIGUI）

| 项 | 内容 |
| --- | --- |
| 输入 | A2、A3；整合设计 P03–P04；05 文件 |
| 范围 | `unit.run` 替代 `gui.runs.*`，Explorer 运行进 RunStore（UI 发起为 Durable Run，外部发起为 Delegated Run）；AiService 唯一推理账本，删除 GuiAuditPort 重复记账；GuiRunBinding 的 inferenceBinding 可空；RunRecorder 去掉 `try?` 吞错 |
| 测试 | GX-01…GX-12、ADR-06…ADR-08、ADR-10 |
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
| U1 | AgentDesktopUI target、主题 token、主窗口框架（侧栏 206、标题栏 54、状态栏 28）、六个一级入口、进程内 Client 与 Store（按代数丢弃过期结果、轮询或事件唯一）、Dock 与关窗转后台；删除 AIGUIRootView 独立侧栏 | A1 | 渲染图与 P01 布局对照；UC50；整合设计 T27 |
| U2 | Desktops：P01 P03 P04 P05 P06 P07 P08（预览走 ScreenCaptureKit，按 desktopId 的独立预览窗口） | U1、A5（creating 与 control 字段缺失时显示降级文案） | UC01–UC06、UC14、UC16、UC19–UC21、UC49、UC52 |
| U3 | 控制：P12–P18 | A5 | UC07–UC13、UC15、UC17、UC18、UC29–UC31；ADR-02 |
| U4 | Agents：Agent 总览、接入（P09–P11 + Hub W01–W03 配对与授权） | A4、A7 | UC22–UC25；HB-UI-01…04 |
| U5 | Runs：全部运行、运行详情（Hub W04–W05）、动作记录与回执（P19–P20） | A5 | UC26–UC28；ADR-07 |
| U6 | Settings：通用（P21）、权限（P02、P22）、AI 连接与 GUI 配置与能力测试与用量（P23–P26、P30） | U1、A2 | UC32–UC40 |
| U7 | Desktop 详情 Explorer 标签：发起与观察 GUI 运行（P27–P29）；一级 GUI Explorer 显示运行历史 | X1 | UC41–UC48；ADR-06 |
| U8 | 菜单栏（P31）、退出与后台（P32） | A5 | UC50、UC51；ADR-09 |
| U9 | Inbox（W06）、核实（W07）、诊断与用量（W08） | A5、inbox 方法 | HB-UI-05…08（P1） |

### L1–L4 学习层（L-AIGUI，P2，独立阶段）

见 05 文件第 4 节。

### M1–M2 设备后端（P2）

| PR | 内容 | 依据 |
| --- | --- | --- |
| M1 | Android：`engine/optional/mobile` 迁成 `AgentDesktopAndroid` target，设备服务进 Runtime，device 目标类型，手机窗口为呈现层 | 总计划 v2.1 第 17A 节 |
| M2 | iPhone Mirroring：粘贴确认、剪贴板租约与无损快照、窗口与几何绑定；WDA 作为完整手势基线另行评估 | iPhone 实现审查 |

## 2.4 合并顺序

A0 → A1 → A2 与 A3 并行 → A4、A5、A6 并行 → X1、A7 → U2–U8 按依赖逐个 → 发布门禁 G。U1 在 A1 后即可开始。每个 PR 合入 foundation 前 CI 全绿；foundation 合入 main 只在 A0（一次）与发布门禁时。
