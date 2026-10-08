# 1 架构裁决矩阵

每一行是一处文档或代码之间的冲突，给出最终裁决与依据。"K"指 Kevin 2026-10-08 的最终裁决消息；"ADR"指 ADR v2.2。

## 1.1 产品与范围

| # | 冲突 | 各方说法 | 最终裁决 | 依据 |
| --- | --- | --- | --- | --- |
| D01 | Agent Hub 做不做、何时做 | Design v2.0：首发无 Hub；09:40 决定：推迟；Hub v1 指令：立即执行；总计划 v2.1：P2 | Hub 是正式核心模块。Runtime Foundation 与 Hub Core（配对、认证、连接、授权、撤权、Run 接入）现在做，P0；完整管理 UI 分阶段（P1/P2）。首发 UI 至少有 Agents 的连接与授权管理，信息架构按最终形态预留 | K 第一节；ADR 第一、六节 |
| D02 | Hub 形态 | 总计划 v2.1：插件托管；Hub v1、BOSS 方案、整合设计：独立 App 配对 | 独立 App 配对授权，平台不托管外部 Agent 进程、业务任务与生命周期。Plugin Hosting、Process Supervisor、Managed Resident Agent 标为 deprecated | ADR 第一节 |
| D03 | GUI Explorer 学习层 | 09:40：PR4 暂缓；整合设计 P05–P06 与 Explorer 方案列入主线 | P00–P04 立即实施；P05–P06 作为独立阶段，正式产品功能。当前 Run、Event、Action、Observation 的数据结构必须为学习数据复用留好字段（见 05 文件第 3 节） | K 第二节 |
| D04 | 平台是否依赖业务 Agent | 历史 builtin BOSS、TS task-runtime 的 boss 模块 | 平台层不依赖任何具体业务 Agent，不加特殊判断。BOSS、微信等是独立 App，经 SDK/API 接入 | K 第三节；ADR 第一节 |
| D05 | 旧文档缺失 | 架构 FINAL v1.3、单仓合并 FINAL v1.3、产品策略 v4 不在本机 | 不阻塞开发。ADR 已宣布前两份过期。旧文档中未被新版本覆盖的功能列入 07 文件的历史功能对照 | K 第六节；ADR 开头 |

## 1.2 契约与 Runtime

| # | 冲突 | 各方说法 | 最终裁决 | 依据 |
| --- | --- | --- | --- | --- |
| D10 | 幂等键 | Explorer 方案：顶层 idempotencyKey；总计划 v2.1 与整合设计：requestId | 只用 requestId。唯一键为（已认证主体, requestId）；语义指纹覆盖方法、参数、目标与执行 deadline；同键不同语义返回 `idempotency_conflict` | K 第三节表；整合设计 5.1 |
| D11 | 协议与入口 | `agentdesktop.ai/1`（ai.sock）与 `agentdesktop.runtime/1`（runtime.sock）并存 | 只保留 runtime/1 与一个 RuntimeServer 端点；删除 RpcSocketServer、ai.sock 与 legacy 解码 | K；整合设计第 2 节 |
| D12 | 协议模块 | AgentDesktopContracts 与 AgentDesktopProtocol 两个模型模块 | 合并为 AgentDesktopProtocol | K 第三节表 |
| D13 | GUI 运行接口 | `gui.runs.start/get/cancel/events` 与 Runtime `run.*` | 收敛为 `unit.run` + `run.show/list/events/wait/cancel`，同一 RunStore；`origin=gui_explorer` | K；ADR 第二、四节 |
| D14 | 模型记账 | GuiAuditPort 的 reserveInference 与 AiService ledger 并存 | AiService 唯一写推理尝试；Explorer 只引用 attemptId | K；整合设计 4.3 |
| D15 | 动作记账 | GUI 动作表与 Runtime ActionReceipt 并存 | Runtime 唯一写 ActionReceipt；proposalId、attemptId 是可选来源字段 | K；整合设计 4.3 |
| D16 | unknown 与控制权 | AI/GUI v1.0：unknown 永久锁 Desktop | 两轴分离：输入确认静止即可释放控制权；动作结果保持 unknown，持久化，永不自动重发，只追加核实记录 | K；ADR 第三节；Explorer 方案 B01 |
| D17 | 连接断开与 Run | 旧实现：连接 EOF 即取消一切 | 按 ADR 两类 Run：Delegated（external_client / connection_scoped）在控制连接失效后停止新输入并进入停止流程；Durable（platform / platform_durable）不受 UI 页面、订阅断开影响。外部 Agent 不能经参数申请 Durable | ADR 第三节；已在 #33 实现 |
| D18 | 控制权仲裁 | 旧引擎每次输入 `Task.detached`；Design：单 Desktop 单写控制者 | Runtime 统一仲裁：每个 Desktop 至多一个写租约、动作有序；不同 Desktop 并发；不同 Agent 不能绕过 Runtime 向同一目标注入 | K 第三节；Design 交互规则 |
| D19 | 目标类型 | Runtime 目标只有窗口 | 目标分 `window` 与 `device` 两类，同一张契约 PR 冻结；首发 UI 只实现 window | K 第三节表；总计划 v2.1 17A.4 |
| D20 | 观察标识名 | Design 示例用 frameId；契约用 snapshotId | 契约名为 `snapshotId`，不改名。UI 把它显示为「画面 ID」；设计稿示例里的 `--frame-id` 改为 `--snapshot-id` | 整合设计用 snapshotId；Design 注明参数随契约冻结 |
| D21 | 回执与业务结果 | Design：`businessResult: not_evaluated` | ActionReceipt 增加 `businessResult`，平台只写 `not_evaluated`；业务结果由调用方判断 | Design 交接规则 |

## 1.3 界面

| # | 冲突 | 各方说法 | 最终裁决 | 依据 |
| --- | --- | --- | --- | --- |
| D30 | 主窗口导航 | Design v2.0 侧栏：Desktops / Agent 接入 / 操作记录 / AI 与 GUI / 设置；ADR 树：Home / Agents / Runs / GUI Explorer / Inbox / Settings | 一套侧栏，按 ADR 分组：Desktops（即 ADR 的 Home）、Agents、Runs、GUI Explorer、Inbox、Settings。Design v2.0 的 32 个页面全部保留，只调整入口：Agent 接入并入 Agents；操作记录成为 Runs 下的「动作记录」视图；AI 与 GUI 设置并入 Settings，诊断运行并入 Desktop 详情的 Explorer 标签 | ADR 优先；K 第四节「最终信息架构不能推翻」 |
| D31 | Explorer 位置 | K：集成在 Desktop 相关工作界面；ADR：一级菜单 GUI Explorer | 两者都有：在 Desktop 详情的 Explorer 标签发起与观察运行；一级菜单 GUI Explorer 放跨 Desktop 的「已学流程」「回放与验证」库。学习层未上线前，一级菜单只显示 Explorer 运行历史与说明 | K 第四节；ADR 第二节 |
| D32 | AI/GUI 自带侧栏 | AgentDesktopAIUI 的 AIGUIRootView 有独立八页 NavigationSplitView | 删除；W01–W08 的视图与模型挂到 Settings 和 Desktop 详情。整合设计 T27 作为回归 | K 第四节；整合设计第 9 节 |
| D33 | Hub 八页 | Hub v1 W01–W08 独立页面 | 成为 Agents、Runs、Inbox、Settings 下的视图（见 06 文件）；首发交付 W01–W05，W06–W08 第二批 | ADR 第二节；K 第一节 |
| D34 | 验收依据 | 自定规则 | 设计源码包的页面映射（screen-map.json）与 54 项交互检查（ui-checks-54.json）作为 UI 验收依据；原生实现逐项重做，不转记网页原型的通过 | K 第四节 |
| D35 | 旧引擎菜单 | 主虚拟显示、分辨率、HiDPI、搬窗口热键、按 screen 列出的 Agent Screens | 产品界面删除；`engine/` 中的实现保留为历史来源，不进产品菜单 | Design v2.0 无此功能；见 07 文件 |

## 1.4 仓库与负责人

| # | 冲突 | 现状 | 最终裁决 |
| --- | --- | --- | --- |
| D40 | 两套核心并存 | main 有 Codex 迁入的 `engine/`（旧 2ndscreen 引擎、旧 CLI `agentdesktop-cli`、Windows C# 引擎、Android 可选模块）；foundation 有新的 AgentDesktopRuntime/Protocol/Client/CLI/AI/GUI，且仍 pin 远程 2ndscreen 0.2.0 | 第一张 PR（A0）把 foundation rebase 到 main：新 Runtime 链接本地 `engine/` 的 SecondScreenCore，删除远程 pin；产品只发布一个 `agentdesktop` CLI，`agentdesktop-cli` 退出发布路径 |
| D41 | 跨模块 PR 负责人 | P01 横跨 Runtime 与 AI/GUI | 已确认：集成负责人与 Runtime / Hub Core 为 2ndscreen-f1（原 5c）；AI/GUI Explorer 与 Windows 为 2ndscreen-40；主窗口 UI 另设独立会话 |
| D42 | 契约文件的权威 | 本规划 03 文件与 #34 冻结文档的方法名有差异 | 以 #34 冻结文档为准；本规划的方法名已对齐；03 文件只列待纳入的增量 |
| D43 | AX 超时修复的验收 | 只检查 observe 返回超时 | 必须同时证明故障隔离与资源有界（RT-23A、RT-23B）；外层 Task 超时不算修复 |
| D44 | 凭据与测试隔离 | `ai.sqlite` 曾为 0644 | 配置与账本 0600、目录 0700，库内只存凭据引用；测试副本与产品各自独立；在干净实例上测（SEC-01…05） |
| D45 | `unit.run` 的所有权 | 同一方法既服务 UI 又服务外部 Agent | 只由已认证主体决定：主窗口进程内为 Durable，任何线协议调用为 Delegated，参数不能提升（GX-21） |
| D47 | 截图与输入的目标 | MAC-001：截图按屏幕、输入按绑定窗口，叠窗时模型看到的不是输入目标 | 观察与执行必须针对同一绑定窗口；遮挡时拒绝而不是投递（A3、RT-24） |
| D46 | M0 与正式组合的门禁 | 原写法允许 E2E-13 经确认后延后 | 中立双 Desktop 并发与宿主隔离（E2E-09、M0）为首发必过；E2E-13 单独验收，未执行只能记 not_run 或 blocked，不得标 passed |
