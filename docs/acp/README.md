# ACP 工作区（协调说明）

状态：开工版，2026-10-08。协调者：本仓库 `acp-skeleton` 分支的提交人（2ndscreen 会话 997716a3）。

ACP（Agent Client Protocol）是 AgentDesktop 的第三种接入方式，和 CLI、MCP 并列，全部进入同一个 Runtime。方案输入是 Kevin 的 [v1.0 方案原文](00-input-plan-v1.0.md)；它修订的是 2ndscreen 仓库的 RFC 0002（szrunworld/2ndscreen PR #56，只有文档）。分工见 [03-lanes.md](03-lanes.md)。

## 一、文件

| 文件 | 内容 | 负责 |
| --- | --- | --- |
| 00-input-plan-v1.0.md | Kevin 的方案原文 | 不改 |
| README.md | 本文：核对结论、冻结的内部接口、规则 | 协调者 |
| 01-rfc-0002-revised.md | RFC 0002 修订稿 | 工作线 D |
| 02-protocol-version.md | ACP v1/v2 决策与兼容矩阵 | 工作线 T |
| 03-lanes.md | 工作线、文件所有权、依赖、交付 | 协调者 |
| 04-gap-analysis.md | 现有代码与目标架构的差距 | 工作线 D |
| 05-pr-graph.md | PR 依赖图与合并顺序 | 工作线 D |
| 06-gates.md | G0～G5 验收清单 | 工作线 D |
| 07-runtime-requests.md | 需要 f1 / 40 提供的契约与能力 | 工作线 R |
| 08-event-mapping.md | Runtime 事件到 ACP 更新的映射规范 | 工作线 E |
| 09-outbound-isolation.md | 出站执行体隔离评估 | 工作线 O |
| tests/ | T01～T28 细化用例与 E2E 手册 | 工作线 Q |

## 二、核对结论（以代码为准，2026-10-08 ai-gui-foundation b2831ca，含 #47 A0 与 #51 G0）

方案原文写于未逐项核对代码之前。下面六条是协调者核对后的事实，各工作线以此为准；与原文冲突处已标出，需要 Kevin 确认的单列在第五节。

1. **新 MCP 不绕过 Runtime。** `agentdesktop mcp`（PR #29，草案，未合入）的每个工具都经 `RuntimeClient` 发 runtime/1 请求。旧引擎的 `control.sock` 已随 #47（f187ec7）停止监听。宿主现存的第二个入口是 AI/GUI 服务的 `ai.sock`（`AppController.swift` 约 157–178 行的 `RpcSocketServer`），同 uid 的连接一律当作可信 owner，不经 runtime/1 的身份与策略。`engine/` 里的旧 CLI 与 `AgentRuntime.start(socketPath:)` 仍在源码中，不在发布包内，但本机自行编译就能开出一个不经 Runtime 的 socket。原文 A0-05「修复 MCP 绕过」因此落在 **A2 单一端点**（f1 负责）：宿主只监听一个 endpoint，`ai.*` 全部经 runtime/1。ACP 不另开安全修复 PR，G0 以 A2 合入且 T18 通过为准。A2 之后 Runtime 端点将改名为 `control.sock`，与旧引擎 socket 同名，G0 检查要按监听进程判定，不能按文件名（04-gap-analysis C-19）。
2. **线协议上的 Run 一律是 Delegated。** ADR v2.2 与 docs/plan/02 A6 规定：任何经线协议的请求（CLI、MCP、SDK、外部 App，含本机 owner 的线连接）创建的都是 `external_client / connection_scoped`，参数里的 `origin`、`lifetime`、`ownership` 一律拒绝。`agentdesktop acp` 是一个线客户端，所以 **ACP 发起的 Run 都是 connection_scoped**，编辑器断开即停止输入。原文 P2「场景 A：从编辑器启动 Durable Run」在现行 ADR 下不成立；可行的替代是「主窗口发起的 Durable Run，在 ACP 里只读观察」。见第五节决策 K1。
3. **runtime/1 还没有任务入口。** 冻结目录（methods.json，33 个方法）里没有 `unit.run`；它在 A6（40 负责，PR #50 草案）。没有它，编辑器无法「交出一件任务」。在 A6 之前，ACP 只能暴露只读与控制命令（Desktop 列表、本身份 Run 的查看与取消）。P1 的真实端到端依赖 A6。
4. **身份与授权未实现。** Hub Core（A4，f1 负责）未开始。握手返回的是 Runtime 自己的身份，不返回调用方 principal（`RuntimeService.swift` handshake 分支）；每个本机连接都是 owner，能看见并控制所有 Run。请求去重键是 uid + requestId，同一用户的 CLI、MCP、ACP 共用一个 requestId 空间。在 A4 之前，T07、T15 无法真正验证。
5. **没有审批与提问的 Runtime 方法。** runtime/1 没有 approval / question 方法；Inbox 是 U9（P1）。原文 P2-04 审批需要 f1 的契约增量。在它之前，ACP 端只实现编辑器侧流程，Runtime 侧返回 `capability_missing`，并且绝不当作批准。
6. **事件类型目录未冻结。** `events.subscribe`（#41）已有游标与续传；事件类型目录（F1-01：run.started、action.accepted/dispatched/completed/failed/unknown、run.finishing、stop.accepted、run.quiescent、run.ended）计划在 A0 之后的契约 PR 里冻结。工作线 E 按这份目录写映射，目录冻结后对齐。

另外：本机未安装 Zed，也没有 JetBrains IDE；真编辑器验收需要 Kevin 安装。本机有 node 22、claude、codex、gemini 命令。

## 三、冻结的内部接口

`Sources/AgentDesktopACP/Model/ACPModel.swift` 与 `Sources/AgentDesktopACP/Ports.swift` 是各工作线之间唯一的接口：

| 接口 | 实现方 | 使用方 |
| --- | --- | --- |
| `ACPIncoming`、`ACPReply`、`ACPSessionUpdate` 等版本中立模型 | 协调者 | 全部 |
| `ACPConnection` / `ACPPeer`：一个已协商版本的编辑器连接 | T | S |
| `ACPRuntimePort`：经 `RuntimeClient` 访问 Runtime | R | S |
| `ACPEventProjector`：Runtime 事件到编辑器更新，含脱敏 | E | S |
| `ACPSessionStore`：ACP 会话绑定的持久化 | S | S |

版本差异只存在于 T 的 Wire 适配器里；其余代码只认版本中立模型。接口需要改动时，向协调者提出，协调者在 `acp-skeleton` 上改并通知所有工作线。

## 四、规则

1. ACP 不建 GUI 执行器、RunStore、租约或第二套请求去重账本。Run 状态的唯一来源是 Runtime。
2. 不改 `contracts/runtime/v1`、`Sources/AgentDesktopRuntime`、`Sources/AgentDesktopClient`、`Sources/AgentDesktopProtocol`、`Sources/AgentDesktopCLI`、`Package.swift`。需要时写进 07-runtime-requests.md，由协调者转 f1。
3. 身份只取自 Runtime 的认证上下文，从不取自编辑器发来的字段。
4. 编辑器审批只能让执行更严，不能扩大平台权限；审批通道不可用时按拒绝处理。
5. 截图、页面文字、窗口标题、动作参数默认不进入任何 ACP 更新、日志或存储；脱敏只在工作线 E 一处实现。
6. `unknown` 只展示为「待核实」，从不重试；提交结果不明时只查询，不重发。
7. 只认执行过的断言、退出码与真机记录。看 `swift test` 的退出码，不用管道截断判断。真机验收用 `/tmp/adt-*` 下的测试副本，不碰产品 endpoint。

## 五、Kevin 的裁决（2026-10-08）

Kevin 批准 PR #53 作为七条工作线的共享开发基线（保持草案，接口审核后再合并），七条线并行推进。

| 编号 | 结论 | 执行要求 |
| --- | --- | --- |
| K1 | **不支持编辑器关闭后继续执行，维持 ADR v2.2** | ACP 发起的 Run 一律 connection_scoped；断连后不再接受新的执行操作，Runtime 按 connection_scoped 规则收尾；无法确认结果的操作记为 `unknown`，不记失败。ACP 可以在授权范围内只读观察主窗口发起的 Durable Run。不得通过重连、后台 worker 或内部参数把 connection_scoped Run 变成 Durable。**会话恢复不等于 Run 恢复**：重连后只恢复会话历史、读取状态与结果，不自动恢复已终止的执行 |
| K2 | **批准安装 Zed**，作为 P1 主验收编辑器 | 已安装 Zed 1.23.2（2026-10-08，Homebrew）。JetBrains 延后到 P2，不阻塞 P1 |
| K3 | **ACP 不作为首版必交付功能** | G0～G3 并行开发、不阻塞其他工作线；G3 完成后评估是否进首版候选；正式发布须 G4、G5 与 Runtime 集成验收全部通过。Runtime 依赖未就绪时，ACP 保留为开发或实验特性 |

附加约束：

1. **PR #53 是共享接口基线，不替代 Runtime 契约。** Runtime 的真实行为以 runtime/1 与 ADR v2.2 为准；缺失能力只能向 Runtime 负责人提契约增量，ACP 不实现替代路径。
2. **S 与 R 严格分离。** S 负责 ACP 会话、编辑器交互和协议级状态；R 负责与 RuntimeClient 交互、查询实际 Run 状态、幂等与结果映射。S 不直接调用 GUI 引擎，任何线都不经旧 socket 或 `ai.sock` 绕过 RuntimeClient。
3. **E 做字段级隐私，事件分三级**：可完整展示的普通事件、需要脱敏的敏感事件、只能显示状态不能暴露内容的受保护事件。重点验证截图、窗口标题、输入内容和审批参数不泄露跨应用数据。
4. **O 只做受控隔离评估。** 不访问个人凭据或生产密钥；使用隔离的测试目录、资源与权限；记录文件系统、网络、进程与工具调用的隔离结果；需要额外登录、授权或付费资源时只记录依赖，不自行获取或使用；隔离不能可靠实现即标记未通过，提示词约束不算隔离。
5. **T 按真实规范与 Zed 的实际支持选版本**，不自行发明协议版本，不为兼容多个版本污染内部模型。
6. **Fake Runtime 测试与真实 Runtime 集成验收严格区分。** f1 的 A2、A4 与 40 的 A6 合入前，任何假实现通过都不算端到端验收。
7. **新增端到端场景**（Q 负责）：ACP-29 执行中直接关闭 Zed，Run 按 connection_scoped 结束、无新 GUI 输入、未确认结果保持 unknown；ACP-30 重连后在授权范围内查询先前的 Run，不自动恢复已终止的 Run；ACP-31 观察其他客户端发起的 Durable Run 必须经明确授权，不能凭会话 ID 或 Run ID 越权读取。

执行优先级：先稳定共享接口与协议传输（T），再完成入站服务（S）与 Runtime 桥（R），最后做真实编辑器与真实 Runtime 的集成验收。ACP、MCP、Agent Hub 是不同的接入协议或客户端能力，不是三个执行系统，最终收敛到同一套 Runtime、身份授权、Run 生命周期与审计。

## 六、协调者决定与 f1 审核（2026-10-08）

f1 对 ACP 契约需求的审核结论记在 [07](07-runtime-requests.md) 与 [08](08-event-mapping.md) 第〇节：大部分进 PR2b；R2 审批进 PR4；R6 任务目录不进 Runtime；R7 不加 never_received，ACP 按 `oldestAcceptedAt` 与 `instanceId` 判断能否重发一次；R9 子命令等 G1。

协调者决定：

| 问题 | 决定 | 理由 |
| --- | --- | --- |
| 超长帧（02 第四节与 06 G1-02 冲突） | 回错误、丢弃该帧、从下一个换行继续读，**不断开连接** | 断开会让这条连接上所有 connection_scoped Run 停止，一帧坏数据不该付这个代价；进程不退出 |
| `session/load` 的顺序 | 先回放历史，再回复 load（ACP v1 要求）；回放包含脱敏后的用户输入与任务结果摘要 | v1 规定；会话存储只存经 E 脱敏的文本 |
| stdin 关闭后是否补写回复 | 不补写 | stdin 关闭即编辑器离开，按 ADR v2.2 处理；已受理的 prompt 不能因此再建 Run |

## 七、Kevin 的第二次裁决（2026-10-08 晚）

**结论**：七条工作线协议层验收通过；阶段 3 可以继续真实集成；ACP v1 暂不宣布完成、暂不批准发布；#53 保持草案。PR #2 合入 main 的授权状态不变，仍未批准。

| 编号 | 决定 | 执行要求 |
| --- | --- | --- |
| O1 | 真实模型验收使用独立测试凭据 | 由用户明确提供或授权；存系统钥匙串或受控密钥存储，不进 Git、日志、会话历史；设调用预算与工具白名单；先只读、规划、模拟执行；真实写操作一律经 Runtime 授权与审批，不另建权限系统 |
| O2 | 接受 Codex 为 Experimental 执行适配器 | 经 RuntimeClient 执行 GUI 操作；不碰 Runtime 内部 socket；不绕过审批；结果未知的动作不因模型自行重试而重复执行。正式支持等真实模型端到端验收后再定 |
| O3 | 允许在隔离环境做「agent 修改自身 MCP 配置」实验，不进正式产品 | 先产生 diff，人工审批后应用；配置路径白名单；备份、回滚、审计；不得借此添加未授权工具或扩大权限。将来可发展为 Tool Configuration Management，不阻塞 ACP v1 |
| P1 | 不接受默认明文显示窗口标题里的人名 | 页面正文：在明确授权的观察任务中可读取，仍遵守脱敏与日志规则。窗口标题与身份信息：默认敏感，在事件与日志中一律脱敏；只在用户授权的本地界面（主窗口）展示，不进入 ACP 事件流 |
| P2 | 结果不明的动作改为明确终态 | 区分执行状态与结果状态：Run 结束后为 execution = terminated、outcome = unknown，显示「结果未知 · 需要核实」；不显示进行中，也不标记失败；之后只能查询与核实，不得未经确认重发 |
| Z1 | Zed 手工验收纳入协议验收 | 按 tests/e2e-runbook.md §三.1 保存真实 initialize 请求与响应、协议版本与必要的脱敏日志；取得真实帧之前不得据模拟结果填写协议版本文档，也不得标记通过 |

**P2 的协议约束（协调者）**：ACP v1 的工具调用状态只有 pending、in_progress、completed（定义为成功完成）、failed（定义为出错失败），没有中性终态。实现为：Run 结束后，结果未知的动作在 v1 线上用 `failed`，标题为「结果未知 · 需要核实」，`rawOutput` 带 `{execution: "terminated", outcome: "unknown"}`；内部模型始终是 unknown，不记为失败、不重试。选 `failed` 而不是 `completed`，是因为后者会被读成已经成功。映射集中在 Wire 适配器一处，Kevin 若改选 `completed` 可单点切换。

**下一阶段优先级**：真实编辑器 → ACP → AgentDesktop Runtime → GUI 执行 → 结果返回编辑器，至少覆盖正常完成、取消、断连、审批拒绝、结果未知五类情况。

**架构原则**：ACP 是 AgentDesktop 的通用协议入口，不是第二套 Runtime。所有 Agent、编辑器与模型适配器都经统一的 RuntimeClient、授权机制、运行生命周期与审计；不为 ACP 另建 Session Execution Engine，不为 Codex 特殊处理而破坏通用协议。
