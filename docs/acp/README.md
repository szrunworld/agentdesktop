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

## 二、核对结论（以代码为准，2026-10-08 ai-gui-foundation fab099f）

方案原文写于未逐项核对代码之前。下面六条是协调者核对后的事实，各工作线以此为准；与原文冲突处已标出，需要 Kevin 确认的单列在第五节。

1. **新 MCP 不绕过 Runtime。** `agentdesktop mcp`（PR #29，草案，未合入）的每个工具都经 `RuntimeClient` 发 runtime/1 请求。真正的旁路是**宿主仍在监听引擎旧的 `control.sock`**（PR #47 A0 的「未完成」第一条：`AppController` 仍调用 `runtime.start(socketPath:)`），任何能连上它的进程都可以不经 Runtime 策略直接操作窗口；`engine/` 里的旧 `ScreenCLI` 和 `MCPServer.swift` 也还在，只是退出了发布路径。原文 A0-05「修复 MCP 绕过」因此落在 **A2 单一端点**（f1 负责）：宿主只监听一个 endpoint。ACP 不另开安全修复 PR，G0 以 A2 合入且 T18 通过为准。
2. **线协议上的 Run 一律是 Delegated。** ADR v2.2 与 docs/plan/02 A6 规定：任何经线协议的请求（CLI、MCP、SDK、外部 App，含本机 owner 的线连接）创建的都是 `external_client / connection_scoped`，参数里的 `origin`、`lifetime`、`ownership` 一律拒绝。`agentdesktop acp` 是一个线客户端，所以 **ACP 发起的 Run 都是 connection_scoped**，编辑器断开即停止输入。原文 P2「场景 A：从编辑器启动 Durable Run」在现行 ADR 下不成立；可行的替代是「主窗口发起的 Durable Run，在 ACP 里只读观察」。见第五节决策 K1。
3. **runtime/1 还没有任务入口。** 冻结目录（methods.json，33 个方法）里没有 `unit.run`；它在 A6（40 负责，PR #50 草案）。没有它，编辑器无法「交出一件任务」。在 A6 之前，ACP 只能暴露只读与控制命令（Desktop 列表、本身份 Run 的查看与取消）。P1 的真实端到端依赖 A6。
4. **身份与授权未实现。** Hub Core（A4，f1 负责）未开始。在它之前，ACP 拿到的调用方只能是握手返回的本机身份，T07（无权恢复他人会话）无法真正验证。
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

## 五、需要 Kevin 决定

| 编号 | 问题 | 协调者建议 |
| --- | --- | --- |
| K1 | ACP 发起的任务能否在编辑器关闭后继续（原文 P2 场景 A） | 维持 ADR v2.2：不能。ACP 可以只读观察主窗口发起的 Durable Run。如果要支持，需要修改 ADR，而不是给 ACP 开参数 |
| K2 | 安装 Zed（必需）与一个 JetBrains IDE（P2） | P1 前安装 Zed |
| K3 | ACP 是否随首版发布 | 产品设计 v2.0 把 ACP 列为「按需」。建议 G0～G3 通过后再进首版，不阻塞 M1/M2 |
