# AgentDesktop ACP 协议设计与实施方案 v1.0（输入原文）

> 来源：Kevin 于 2026-10-08 提供，基于 RFC 0002（2ndscreen PR #56）、CLI v1.2、Runtime/1、Agent Hub 与 ADR v2.2。本文件按原文保存，作为 ACP 各工作线的共同输入；协调者对现状的核对与修正见 [README.md](README.md) 第二节，冲突时以 README 的「核对结论」为准，并回报 Kevin。

**基于 RFC 0002、CLI v1.2、Runtime/1、Agent Hub 与 ADR v2.2**

## 一、我的总体判断

我认为 ACP 值得做，而且应该成为 AgentDesktop 对外开放的第三种重要接入方式。

但是，**ACP 不应该再开发一套 Agent Runtime，也不应该仅仅是把 MCP 包装成另一种协议。**

结合之前的 CLI 规划，我建议重新明确整个产品的协议架构：

> **CLI 是命令行入口，MCP 是工具调用接口，ACP 是 Agent 与编辑器的交互协议，Agent Hub 是外部 Agent 的连接和授权管理层。所有入口最终进入同一个 Runtime。**

这样，AgentDesktop 才能成为一个真正通用的 Computer Use Platform。

### 1.1 最终产品架构

```text
                  External Applications
                          │
       ┌──────────────────┼──────────────────┐
       │                  │                  │
    Terminal          AI Editors       External Agents
       │                  │                  │
  agentdesktop CLI    Zed / JetBrains   Independent Apps
       │                  │                  │
       │              ACP Adapter            │
       │                  │                  │
       ├──────── MCP ─────┤                  │
       │                  │                  │
       └──────────────────┴──────────────────┘
                          │
                  AgentDesktop Client
                          │
                 AgentDesktop Runtime/1
                          │
          ┌───────────────┼─────────────────┐
          │               │                 │
       Identity       Session/Run        Policy Engine
       & Auth         & RunStore         & Approval
          │               │                 │
          └───────────────┼─────────────────┘
                          │
                    GUI Executor
                          │
               ┌──────────┴───────────┐
               │                      │
           macOS Core             Windows Core
               │                      │
         Desktop/Window          Desktop/Window
               │                      │
           Observe / Act / Verify
```

这里的核心原则是：

**协议层可以有多个，但真正执行桌面操作的 Runtime 只能有一个。**

它还必须满足之前确定的几项架构约束：

1. AgentDesktop 是独立的通用产品，核心代码不包含任何特定业务 Agent。
2. 外部 Agent 是独立应用，通过身份、配对和授权连接 AgentDesktop，不由 AgentDesktop 托管其业务进程。
3. CLI、MCP、ACP、SDK 必须复用 `agentdesktop.runtime/1`。
4. 控制权、GUI 执行、Run 生命周期、状态、审计和停止能力都归 Runtime 管理。
5. ACP 不直接调用旧引擎，也不依赖将被退役的 2ndscreen 包。
6. 既然此前未正式发布，就不需要维持历史 ACP/CLI 兼容接口。

这里也需要纠正 RFC 草案中的一个产品命名问题：

**新的正式命令应该是 `agentdesktop acp`，而不是 `2ndscreen acp`。**

这与之前 CLI v1.2 的命名和单仓收敛策略一致。

---

## 二、先明确 ACP 的产品定位

我建议将 ACP 拆成两项独立能力，但共享同一个协议模块。

| 能力 | ACP Inbound | ACP Outbound |
|---|---|---|
| AgentDesktop 角色 | ACP Agent Server | ACP Client |
| 对端角色 | Zed、JetBrains 等编辑器 | Claude Code、Codex 等编程 Agent |
| 核心价值 | 让编辑器使用 AgentDesktop 的任务能力 | 让 AgentDesktop 调用外部编程 Agent 完成受限任务 |
| 入口 | `agentdesktop acp` | Execution Adapter |
| 内部路由 | ACP → Client → Runtime | Runtime → ACP Client Adapter → 外部 Agent |
| 权限来源 | Agent Hub 授权与 Runtime Policy | Runtime 授权与执行体能力策略 |
| 生命周期 | ACP Session + Platform Run | Platform Run + External Agent Session |
| 实施优先级 | P1 | P3 |

这里有一个非常重要的区别。

### Inbound：AgentDesktop 是执行服务提供方

例如用户在 Zed 中输入：

> 请在指定的 Desktop 中运行已经注册的测试任务，并告诉我是否成功。

Zed 不需要知道 GUI 的点击坐标，也不需要自己管理窗口。

它只需要调用 AgentDesktop 提供的 ACP 接口。

AgentDesktop 负责：

- 解析任务请求。
- 确认调用方身份。
- 检查任务权限。
- 创建 Runtime Run。
- 执行任务。
- 返回结构化事件。
- 按策略处理用户审批。
- 提供结果和证据引用。

这是一种 **Task-oriented Agent Interface**。

### Outbound：AgentDesktop 调度外部 Agent

例如：

> 使用指定的外部 Agent 分析某个任务的运行结果，并生成修复建议。

AgentDesktop 可以把已经过筛选的上下文交给外部 Agent。

但是，外部 Agent 不能因此获得整个电脑的访问权。

这是一种 **Restricted Agent Execution Interface**。

需要特别强调：ACP 本身是 Agent 与客户端之间的通信协议，不是天然的沙箱，也不是权限系统。要把 Claude Code 或 Codex 变成安全执行体，必须额外设计工具网关、进程隔离、数据边界和权限策略。

**我的建议是：Inbound 可以作为正式产品能力推进；Outbound 先作为受限执行体试验，安全边界验证通过后再开放。**

---

## 三、需要修正 RFC 0002 的三个关键问题

### 3.1 长任务不能依赖编辑器连接存活

我同意草案里提出要验证长任务展示，但不建议把生命周期语义交给不同编辑器决定。

根据 ADR v2.2，必须区分：

- ACP Connection：编辑器与 AgentDesktop 的通信连接。
- ACP Session：编辑器中一次可恢复的交互上下文。
- Platform Run：Runtime 实际执行的任务。
- Run Lifetime：运行由谁创建、谁拥有、断连以后如何处理。

因此，我建议：

**编辑器只是交互界面，不是长期任务的生命周期管理者。**

不过，这不代表所有 ACP 发起的任务都能在编辑器关闭后继续执行。

之前 ADR v2.2 已经区分：

| Run 类型 | 断开编辑器连接 | 能否继续执行 |
|---|---|---|
| `connection_scoped` | 控制连接失效，停止新输入，进入规定的收尾流程 | 不保证继续 |
| `platform_durable` | ACP 连接关闭，但平台任务仍有独立生命周期 | 可以 |
| 尚未被 Runtime 接受的请求 | 连接关闭 | 不执行 |

因此，草案中“关掉编辑器不影响任务”这句话需要改成：

> 对于已经由平台授权并接受的 Durable Run，ACP 连接断开不会取消其生命周期。对于 Connection-scoped Run，按照 ADR v2.2 执行断连停止与状态核实。

**不能因为一个任务预计运行几十分钟，就自动把它从委托运行升级为持久运行。**

这必须由可信的平台入口及其授权规则决定，而不是由 ACP 请求里的一个参数决定。

### 3.2 招聘等敏感场景默认禁用 Outbound

我赞成草案的建议。

但不建议在 AgentDesktop 核心代码中写死“招聘”这一具体业务类型。

应该建立通用的数据分类与执行体策略：

| 数据等级 | 默认允许外部 Agent | 条件 |
|---|---|---|
| Public | 是 | 正常授权 |
| Internal | 有条件 | 组织策略明确允许 |
| Confidential | 否 | 需要单独授权与受限处理机制 |
| Restricted / PII | 否 | 默认禁止向外部模型发送 |

这样可以适用于任何涉及个人信息、财务信息、企业机密的 Agent，而不只是招聘。

还有一个需要补充的限制：

**只读不等于可以外发。**

即使外部 Agent 不点击、不修改任何内容，只要它看到了包含个人信息的屏幕，就已经发生了数据披露。

因此 P3 的测试不仅要验证工具权限，还需要验证外发内容。

### 3.3 MCP 绕过检查链必须优先修复

这是我认为 RFC 0002 中最重要的发现。

如果目前 MCP 的原子点击等工具可以绕过 Runtime 的检查链，那么未来会形成：

```text
ACP ──→ Policy Engine ──→ Runtime ──→ GUI

MCP ─────────────────────────→ GUI
```

这样实际上存在两套安全模型。

即使 ACP 的权限设计非常严格，外部 Agent 仍可能通过 MCP 走另外一条路径执行同一个操作。

所以我建议明确裁决：

**MCP 绕过检查链单独建一个安全修复议题，但作为 ACP 发布的强制前置条件。**

可以保留 MCP 的原子操作接口，不必禁止它们。

真正需要禁止的是这些工具绕过身份验证、授权、控制权仲裁、执行前复核和审计。

目标应该是：

```text
CLI ──────┐
MCP ──────┤
ACP ──────┼──→ Authenticated Client
SDK ──────┤             │
GUI ──────┘             ▼
                  Runtime Policy
                        │
                  Execution Queue
                        │
                     GUI Core
```

否则 ACP 上线以后，平台安全边界仍然是不完整的。

---

## 四、协议设计：直接复用 CLI v1.2 的 Runtime 契约

这一部分是整个开发方案最关键的地方。

我不建议 ACP 再定义一份独立的 Run API。之前 CLI v1.2 已经形成统一的 Runtime 请求、会话、控制权、取消、去重及回执模型。

ACP 应该只负责**外部协议与内部契约的双向转换**。

### 4.1 协议版本选择

这里有一项值得更新到 RFC 0002 的技术信息。

我查阅了 ACP 官方协议仓库，目前已有 v2 协议文档。它与较早的 v1 存在明显差异：

- v2 使用 `session/resume` 取代 v1 的 `session/load`。
- `session/prompt` 的响应主要表示消息已受理，前台执行进度通过 `session/update` 推送。
- 会话列表、恢复、关闭及取消属于声明 Session 能力后的基础接口。
- 模式切换使用配置选项，而不是旧的 `session/set_mode`。
- 流式计划、工具调用和权限请求的结构也有更新。

因此，不建议直接照搬旧版 Octop 示例实现。

**我的建议：先冻结目标 ACP 协议版本，优先评估 v2；如果 Zed、JetBrains 所使用的 SDK 仍以 v1 为主，就用独立的版本适配层解决，而不是让 Runtime 理解两个版本。**

P1 必须明确选定一个可实际互通的协议版本，其他版本不能未经测试就宣称支持。

### 4.2 模块划分

参考 CLI 的 `Protocol → Client → Runtime → Core` 分层，ACP 建议新增四个组件：

```text
AgentDesktop
│
├── Protocol
│   └── RuntimeV1
│
├── Client
│   └── RuntimeClient
│
├── CLI
│   └── Commands
│       └── ACPCommand
│
├── ACP
│   ├── Transport
│   │   ├── StdioTransport
│   │   └── JsonRpcCodec
│   │
│   ├── Inbound
│   │   ├── ACPAgentServer
│   │   ├── ACPSessionManager
│   │   ├── ACPCommandRegistry
│   │   ├── ACPRequestMapper
│   │   └── ACPEventMapper
│   │
│   ├── Outbound
│   │   ├── ACPClientAdapter
│   │   ├── ACPExecutionProfile
│   │   └── RestrictedToolGateway
│   │
│   └── Security
│       ├── ACPIdentityResolver
│       ├── ACPPolicyAdapter
│       └── ACPDataFilter
│
├── Runtime
│   ├── RunStore
│   ├── SessionManager
│   ├── PolicyEngine
│   ├── ControlLeaseManager
│   └── ExecutionQueue
│
└── Core
    └── GUI Executor
```

以上是建议的逻辑模块名称，不是已经核实存在的源码目录。具体文件位置由实施 Agent 在 A0 收敛后按现有工程结构确定。

ACP 模块不得创建自己的 GUI Executor、RunStore 或 Desktop 锁管理器。

### 4.3 ACP Session 与 Runtime Session 的关系

我建议显式建立一个 `ACPSessionBinding`。

示意内部模型：

```typescript
interface ACPSessionBinding {
  acpSessionId: string;

  // ACP 编辑器连接
  connectionId: string | null;

  // 由认证层确定的身份
  principalId: string;
  clientId: string;

  // 关联 Runtime 资源
  runtimeSessionId: string | null;
  activeRunIds: string[];

  // 用户可见的交互状态
  permissionMode: "ask" | "auto";

  // 生命周期元信息
  createdAt: string;
  lastEventCursor: string | null;
  revision: number;
}
```

需要注意，这只是 ACP 层保存的绑定信息。

`activeRunIds` 是对 Runtime Run 的引用或可重建投影，不是新的执行状态来源。

`clientId`、`principalId` 必须从可信认证上下文取得，不能直接相信编辑器传入的字符串。

另外，**ACP Session 不等于 Runtime Run**。

一个 ACP Session 可以对应多个连续运行的 Runtime Run。

一个 Runtime Run 也可以在 ACP 连接断开后，由平台自己的 UI 继续观察。

### 4.4 ACP 方法与 Runtime 的映射

建议先实现以下映射：

| ACP 方法 | 内部处理 | 是否创建 Runtime Run |
|---|---|---|
| `initialize` | 协议协商、能力声明 | 否 |
| `session/new` | 建立 ACP 会话与身份绑定 | 否 |
| `session/list` | 查询允许访问的 ACP 会话 | 否 |
| `session/resume` | 恢复绑定并按权限回放事件 | 否 |
| `session/prompt` | 解析命令、执行权限检查、提交任务 | 根据任务 |
| `session/update` | 将 Runtime 事件映射为 ACP 通知 | 否 |
| `session/cancel` | 向 Runtime 提交取消请求 | 否 |
| `session/close` | 关闭交互会话，按 Run 类型处理 | 否 |
| `session/set_config_option` | 修改 ACP 会话级配置 | 否 |

这里需要强调三个实现细节。

**第一，`session/prompt` 不应该直接执行 GUI 动作。**

它必须调用现有 Runtime 的任务入口，或经明确登记的任务处理器提交 Run。

**第二，`session/cancel` 不是强制终止一个线程。**

它是向 Runtime 提交取消意图，最终是否输入静止、是否执行完成、是否存在未知结果，都以 Runtime 的回执为准。

**第三，恢复 ACP Session 不等于恢复 Runtime Run。**

尤其是 `connection_scoped` Run，断连后不能借 ACP 恢复接口自动重新执行。

### 4.5 任务暴露方式

RFC 0002 提出了“每个任务类型生成一条斜杠命令”。

我建议保留，但增加一个独立的能力发现层。

外部编辑器不应该知道 AgentDesktop 的某个具体业务插件。

它只需要看到当前身份有权调用的任务。

建议内部抽象为：

```typescript
interface ExposedTask {
  taskType: string;
  displayName: string;
  description: string;

  inputSchema: object;
  outputSchema: object;

  allowFreeText: boolean;
  requiresApproval: boolean;

  requiredCapabilities: string[];
  dataClassification: string;
}
```

任务必须来源于已注册的 Agent 或平台通用任务目录。

比如：

```text
Available commands

/inspect-window
/run-procedure
/check-run
/cancel-run
```

这里的命令仅作接口示例。实际应由 Registry 根据授权生成，不要在核心代码中硬编码某种业务。

自由文本也不能直接无约束地路由到任意任务。

应该要求 Manifest 明确声明支持自由文本，并限定其处理范围。

### 4.6 Runtime Run 创建规范

复用现有 `unit.run`、`run.get`、`run.cancel`、`run.events` 等契约时，需要遵循：

```text
ACP prompt
    │
    ▼
Resolve authenticated principal
    │
    ▼
Resolve registered task
    │
    ▼
Validate input schema
    │
    ▼
Authorize task and capability
    │
    ▼
Resolve Run lifetime
    │
    ▼
Submit to Runtime
    │
    ▼
Persist acceptance / Run ID
    │
    ▼
Stream events
```

这里不建议为了 ACP 新增一个 `acp.run()` 这样的核心 RPC。

如果有协议层需要的功能，例如列出可恢复 ACP Session、回放编辑器消息，可以放在 ACP Adapter 内部。

只有当 Runtime 本身确实缺少通用能力时，才通过 f1 审核的契约增量增加到 `runtime/1`。

### 4.7 幂等和重复提交

同一个 ACP 请求可能因为编辑器重连、RPC 超时或代理进程重启而被重发。

必须沿用 CLI 的幂等机制。

建议规则：

- 平台内部以认证后的 `clientId` 和 `requestId` 作为幂等范围。
- ACP Adapter 保存请求身份到 Runtime 请求身份的关联。
- 相同请求重复提交时，返回同一个 Run 的受理结果。
- 不同请求不能因为正文相同就被错误去重。
- 已执行但结果未知的动作不能因超时被重新执行。

ACP 适配层不能自行生成第二套执行去重账本。

如果 ACP 客户端无法提供稳定的重试标识，应由 Adapter 持久化提交记录，并确保重试只查询原请求状态；无法确认是否已经提交时，必须进入待核实状态，不能猜测后再次执行。

---

## 五、事件流设计

这部分需要比原 RFC 更细。

我建议所有事件先经过一个通用的 `ACPEventMapper`，不要让 GUI Core 或业务 Agent 直接构造 ACP JSON。

### 5.1 事件映射表

| Runtime 事件或状态 | ACP 输出 | 用户看到的内容 |
|---|---|---|
| Run Accepted | 状态通知 | 任务已接受 |
| Run Queued | 状态通知 | 等待执行 |
| Unit Started | Plan Update | 当前执行单元 |
| Action Accepted | Tool Call | 动作已受理 |
| Action Executed | Tool Update | 动作已执行 |
| Verification Succeeded | Tool Update | 结果已验证 |
| Verification Failed | Tool Update | 验证失败 |
| Policy Rejected | Tool Update | 动作被拒绝 |
| Approval Required | Permission Request | 等待用户批准 |
| Run Cancel Requested | 状态通知 | 正在停止 |
| Run Quiescent | 状态通知 | 已停止输入 |
| Run Unknown | 状态通知 | 结果待核实 |
| Run Completed | 最终状态 | 任务完成 |

这些是语义映射，不应理解为需要在 Runtime 中新增同名事件类型。

具体 ACP 输出结构必须符合所选协议版本。

### 5.2 不得混淆三个结果

尤其需要保留之前架构讨论中已经明确的区别：

```text
Action Accepted
      ≠
Action Executed
      ≠
Outcome Verified
```

例如：

```text
Step 3: Submit form

Status: Executed
Verification: Unknown
```

不能把它显示为：

```text
Step 3: Completed Successfully
```

因为 GUI 动作执行完成，不代表业务结果已经证实成功。

### 5.3 事件回放与游标

长任务支持重连的基础是持久事件，而不是维持一个长时间运行的 stdio 进程。

建议：

```typescript
interface ACPEventProjection {
  sessionId: string;
  runId: string;
  sourceEventId: string;
  cursor: string;
  timestamp: string;

  kind: string;
  payload: object;

  redacted: boolean;
}
```

内部保存事件来源和映射关系，用于去重、审计和回放。

协议层的游标属于内部实现字段，不应擅自加入标准 ACP 方法。

重连后：

1. 重新验证编辑器身份。
2. 验证是否仍有权限读取会话。
3. 查询 Runtime 的实际 Run 状态。
4. 按选定 ACP 版本的回放机制恢复可见历史。
5. 对缺失事件执行去重处理。
6. 对 `unknown` 结果展示待核实，而不是自动重新执行。

如果 Runtime 的事件源不能提供稳定顺序和回放能力，需要先补齐通用事件契约。

### 5.4 长任务的交互设计

针对运行几十分钟的任务，我建议编辑器中保持一种相对简单的视觉结构：

```text
AgentDesktop

Task: Run registered procedure

● Accepted
● Authorization passed
● Run started

Plan
  ✓ Prepare environment
  ✓ Validate target
  ● Execute procedure
  ○ Verify result

Current Status
  Running
  Run ID: run_12345

Last Update
  13:35:27 — Action executed
  13:35:29 — Verification started
```

对于支持持续通知的编辑器，主动更新状态。

对于不支持跨轮次持续展示的编辑器，至少要允许用户通过恢复会话或查询 Run 状态看到最新进度。

**P1 要验证的不是“所有编辑器都能持续显示几十分钟”，而是“即使编辑器做不到，Runtime 任务也不会产生错误生命周期或丢失状态”。**

---

## 六、审批、权限与安全设计

这一部分我建议直接复用 Agent Hub 的授权架构，不要再设计 ACP 专用权限系统。

### 6.1 三层权限检查

```text
Layer 1 — Identity & Pairing
    谁连接了 AgentDesktop？

Layer 2 — Capability Authorization
    这个客户端可以做什么？

Layer 3 — Runtime Action Policy
    这个动作现在能否在这个目标执行？
```

Layer 3 必须在动作真正执行前再次检查。

例如窗口在等待审批期间发生切换，就不能使用审批前的旧快照直接执行。

这也是之前 MAC-001 窗口一致性问题和 TOCTOU 回归要求对 ACP 的直接影响。

### 6.2 ACP 审批选项

保留 RFC 的设计：

- Allow Once
- Deny Once

不允许通过 ACP 创建永久授权。

但需要明确：**编辑器侧批准只是完成当前动作的一项审批条件，并不赋予新的平台权限。**

假设调用方原本没有发送消息的权限，即使用户在编辑器内点击 Allow Once，Runtime 仍然要拒绝动作。

### 6.3 Ask / Auto 模式

建议定义：

**Ask 模式**

在已有平台权限之内，对配置为需要交互确认的动作逐次征求用户意见。

**Auto 模式**

在已有平台权限和组织策略允许的范围内执行，不额外请求编辑器逐次确认。

两种模式都不能提高已有权限等级。

还需要一个失败策略：

当用户审批渠道不可用时，待审批动作必须保持未执行或明确拒绝，不能自动转为允许。

### 6.4 隐私保护

除截图和页面文本以外，还需要防范事件元数据泄露。

例如：

```text
Tool:
Click send to candidate: example@email.com
```

虽然没有截图，但工具名称里已经包含个人信息。

所以不能只在截图层做过滤。

应该在发送 ACP 更新前统一处理：

```text
Runtime Event
     │
     ▼
Data Classification
     │
     ▼
Field-level Redaction
     │
     ▼
Allowed Content Projection
     │
     ▼
ACP session/update
```

默认事件卡片只显示：

- 动作类别。
- 执行状态。
- 耗时。
- 脱敏的目标标识。
- 非敏感错误代码。
- 必要的验证状态。

不默认显示页面正文、剪贴板、截图、窗口标题中的敏感内容或原始执行参数。

同时要保证 ACP 的错误日志、调试日志、崩溃报告不会成为绕过脱敏的通道。

---

## 七、Outbound：外部编程 Agent 如何成为执行体

这是一个独立工作包，我建议不要与 P1 混在一起实现。

### 7.1 执行体接口

建议在 AgentDesktop 内部定义通用的执行体契约：

```typescript
interface AgentExecutor {
  id: string;

  capabilities(): Promise<ExecutorCapabilities>;

  execute(
    request: ExecutorRequest,
    context: ExecutionContext
  ): AsyncIterable<ExecutorEvent>;

  cancel(executionId: string): Promise<void>;
}
```

示意请求：

```typescript
interface ExecutorRequest {
  runId: string;
  taskType: string;
  input: object;

  allowedCapabilities: string[];
  dataClassification: string;

  timeoutMs: number;
  requestId: string;
}
```

未来可以存在不同执行体：

```text
Agent Executor
     │
     ├── Native Procedure Executor
     ├── GUI AI Executor
     └── ACP External Executor
              │
              ├── Claude Code Adapter
              └── Codex Adapter
```

但不能为了 ACP 改造已经稳定的 Runtime 执行模型。

这个接口只表示执行体适配层，不是另一个 Run 生命周期管理器。

### 7.2 外部编程 Agent 的安全边界

我建议把外部执行体分为两层：

**第一层：任务级操作。**

外部 Agent 只能选择已经授权的任务级工具，例如：

```text
get_run_status
get_redacted_result
request_registered_procedure
```

不开放原子点击、键盘输入或无约束的屏幕读取。

**第二层：进程级隔离。**

必须防止外部 Agent 绕开这些工具，直接使用它自身的文件、终端、网络或原生插件能力。

仅仅不提供终端工具是不够的，因为外部 Agent 进程可能本来就具有这些能力。

因此：

- 外部进程不能继承不必要的环境变量和凭据。
- 必须限制可访问的目录和网络。
- 不允许现场下载未批准的执行程序。
- 对外部 MCP Server 采取明确的允许清单。
- 不支持有效隔离的平台，不能宣称实现了安全的受限执行体。

尤其是 Claude Code、Codex 等不同工具，其内部工具权限模型不完全相同。

所以 P3 必须逐个执行体验证，不应假设 ACP 协议天然能禁止其内置工具。

### 7.3 输出验证

外部 Agent 返回：

```json
{
  "status": "success",
  "result": "Task completed"
}
```

不能直接视为平台已验证成功。

正确流程：

```text
External Agent Result
        │
        ▼
Schema Validation
        │
        ▼
Runtime Result Correlation
        │
        ▼
Independent Verification
        │
        ▼
Verified / Failed / Unknown
```

其中，外部 Agent 的自述只能作为执行结果输入，不能替代 Runtime 的证据和验证。

---

# 八、分阶段实施计划

参考之前 CLI 方案的做法，我建议采用 **A0 + P1～P4 + G0～G5 验收门禁**。

原 RFC 可以保留 P1～P4 的功能分期，但需要增加基础架构准备阶段，并调整发布顺序。

## A0：架构与安全基础收敛

**目标：确认 ACP 所依赖的 CLI、Runtime 和 Agent Hub 能力已经成立。**

| 编号 | 开发任务 | 交付物 |
|---|---|---|
| A0-01 | 核对 CLI v1.2 与当前实际代码的差异 | Dependency Matrix |
| A0-02 | 确认 Runtime/1 接口和实际实现 | Contract Baseline |
| A0-03 | 核对 ADR v2.2 的 Run 生命周期 | Lifetime Mapping |
| A0-04 | 检查 Hub 的身份、授权与撤销能力 | Auth Integration |
| A0-05 | 修复 MCP 原子操作绕过执行检查链 | MCP Security Fix |
| A0-06 | 冻结 ACP 目标协议版本及 SDK | ACP Compatibility Matrix |
| A0-07 | 确认单一 CLI 入口与构建产物 | CLI Integration |
| A0-08 | 制定 ACP 事件脱敏策略 | Privacy Policy |

### A0 验收标准

必须满足：

1. CLI、MCP 与 ACP 规划共用同一 Runtime。
2. 没有新增第二套 GUI Executor。
3. 没有新增第二套 RunStore。
4. MCP 写操作不能绕过执行时的授权和目标复核。
5. Runtime 连接异常不会造成未受控的 GUI 输入。
6. 受理过的请求可通过 Runtime 查询状态。
7. `unknown` 不会触发自动重放。
8. 旧 `2ndscreen` 入口不是新功能的运行时依赖。

**A0 的安全检查是 P1 合并的前置条件。**

ACP 的协议解析器和 Mock 测试可以与安全修复并行开发，但不应在底层绕过问题存在时开放生产写操作。

---

## P1：Inbound 最小可用版本

**目标：从 Zed 通过 ACP 调用 AgentDesktop 完成一个真实任务。**

### 工作任务

| ID | 内容 | 测试 |
|---|---|---|
| P1-01 | `agentdesktop acp` CLI 命令 | 命令启动和退出 |
| P1-02 | Stdio JSON-RPC Transport | 帧解析、断连、错误处理 |
| P1-03 | ACP 初始化和能力协商 | 协议版本测试 |
| P1-04 | ACP Session 创建 | 身份及会话测试 |
| P1-05 | Task Registry 映射 | Manifest 与授权过滤 |
| P1-06 | `session/prompt` 到 Runtime | 真实 Run 提交 |
| P1-07 | `session/update` 事件流 | 计划和动作卡片 |
| P1-08 | Run 状态查询 | Runtime 状态一致性 |
| P1-09 | Zed 兼容性测试 | 真机 E2E |

### P1 端到端验收

```text
Zed
 │
 │ 启动 agentdesktop acp
 ▼
ACP initialize
 │
 ▼
session/new
 │
 ▼
Select registered task
 │
 ▼
session/prompt
 │
 ▼
AgentDesktop Runtime
 │
 ▼
Execute test procedure
 │
 ▼
Runtime Event Stream
 │
 ▼
ACP session/update
 │
 ▼
Zed displays progress and result
```

建议继续使用草案中的计算器测试作为 P1 的标准样本。

但需要注意，计算器测试只是通用 GUI 能力的验收载体，不应把计算器写入产品核心。

### P1 通过标准

- Zed 能启动 ACP Adapter。
- 能发现至少一个已授权任务。
- 可以发起实际 Runtime Run。
- 能看到动作卡片和执行结果。
- 未授权任务不可执行。
- 不产生第二套运行记录。
- 关闭 ACP 客户端后，Runtime 按 Run 类型正确处理生命周期。
- Stdio 中断不会导致 GUI Executor 崩溃。

P1 只需要完整贯通一条真实链路，不追求所有 ACP 功能。

---

## P2：审批、恢复和完整生命周期

**目标：使 ACP 具备可靠的日常使用能力。**

### 开发任务

| ID | 功能 | 实施要求 |
|---|---|---|
| P2-01 | Session List | 按认证身份过滤 |
| P2-02 | Session Resume | 重建 Runtime 关联 |
| P2-03 | Event Replay | 历史事件去重 |
| P2-04 | Approval | Allow Once / Deny Once |
| P2-05 | Ask / Auto | 不得扩大权限 |
| P2-06 | Cancel | 映射 Runtime 取消语义 |
| P2-07 | Unknown State | 明确展示待核实 |
| P2-08 | Privacy Filter | 字段级脱敏 |
| P2-09 | Long-running Task | 长运行与断连测试 |
| P2-10 | Client Compatibility | Zed、JetBrains 分别验证 |

### P2 重点验收场景

**场景 A：关闭编辑器**

```text
1. 从编辑器启动 Durable Run。
2. 等待 Runtime 确认受理。
3. 关闭编辑器。
4. Runtime 继续执行。
5. 重新打开编辑器。
6. 恢复 ACP Session。
7. 查询已存在的 Run。
8. 展示当前进度。
```

预期：没有重复执行；RunId 保持不变；事件可以回放。

这里的 Durable Run 必须事先通过平台授权规则创建，不能由编辑器直接选择升级。

**场景 B：委托 Run 断连**

```text
1. 创建 connection_scoped Run。
2. Run 正在执行。
3. ACP 连接断开。
4. Runtime 检测连接失效。
5. 停止接收新输入。
6. 按 ADR v2.2 收尾。
7. 不能证实的结果标记 unknown。
```

预期：不会因编辑器恢复而自动继续输入。

**场景 C：审批期间目标变化**

```text
1. 请求敏感操作。
2. 编辑器弹出审批。
3. 用户切换或遮挡原目标窗口。
4. 用户点击 Allow Once。
5. Runtime 重新检查目标。
6. 检查不通过则拒绝动作。
```

预期：不能对错误窗口执行操作。

**场景 D：审批通道不可用**

```text
1. 请求需要批准的动作。
2. 编辑器没有实现权限交互。
3. Runtime 保持动作未执行。
4. 返回可解释的拒绝状态。
```

预期：绝不因为客户端能力不足而自动批准。

---

## P3：Outbound 受限外部执行体

**目标：用一个外部编程 Agent 完成只读、脱敏任务。**

### 开发任务

| ID | 功能 | 实施要求 |
|---|---|---|
| P3-01 | Executor Interface | 通用执行体抽象 |
| P3-02 | ACP Client Adapter | 连接外部 ACP Agent |
| P3-03 | Execution Profile | 限定模型及执行环境 |
| P3-04 | Tool Allowlist | 仅允许任务级工具 |
| P3-05 | Process Isolation | 限制文件、终端、网络 |
| P3-06 | Data Classification | 检查外发数据等级 |
| P3-07 | Result Validation | Schema 和结果核实 |
| P3-08 | Cancellation | 外部执行体停止 |
| P3-09 | Audit | 记录执行体和授权结果 |
| P3-10 | Real-world E2E | Claude Code 只读任务 |

### P3 验收

通过条件：

1. 外部 Agent 只获得明确授权的任务工具。
2. 尝试执行未授权的终端命令被阻止。
3. 尝试访问未授权文件被阻止。
4. 尝试使用未授权网络能力被阻止。
5. 未经许可不能启动其他 MCP Server。
6. 敏感数据不能发送到外部模型。
7. 取消后不能继续执行新的受限操作。
8. 外部 Agent 失败时，Runtime 状态仍然可靠。
9. 审计可以追踪外部执行体身份及操作。

如果所选外部 Agent 无法实现进程级隔离，就不能通过 P3 的安全验收。

可以保留实验性适配器，但不应将其作为可信的生产执行体。

---

## P4：Registry 与分发

**目标：让普通开发者能够安装和使用 AgentDesktop ACP。**

主要内容：

- CLI 正式打包。
- ACP Manifest。
- Registry 元数据。
- 安装说明。
- Zed 集成文档。
- JetBrains 集成文档。
- 版本兼容声明。
- 权限和隐私说明。
- 自动化兼容性测试。
- 安装、卸载、重装测试。

### P4 验收

新设备安装 AgentDesktop 后，应能通过标准配置启动 ACP。

不需要安装历史 2ndscreen，也不需要配置独立的旧 Agent Bridge。

Registry 上架应该是产品分发事项，而不应该影响 Runtime 架构。

---

# 九、测试矩阵与发布门禁

建议专门建立一套 ACP 回归测试。

下面是建议的最低测试集合。

| 类别 | 编号 | 测试内容 | 预期 |
|---|---|---|---|
| Transport | T01 | JSON-RPC 合法请求 | 正常处理 |
| Transport | T02 | 错误消息和过大帧 | 安全拒绝 |
| Transport | T03 | Stdio 异常关闭 | 不崩溃、不误执行 |
| Protocol | T04 | 版本不兼容 | 明确拒绝 |
| Protocol | T05 | 不支持的 Capability | 不错误宣告支持 |
| Session | T06 | 创建、查询、恢复 | 关联正确 |
| Session | T07 | 无权恢复其他身份的 Session | 拒绝 |
| Session | T08 | 多 Session 并发 | 不串流 |
| Runtime | T09 | ACP 创建 Run | RunStore 有唯一记录 |
| Runtime | T10 | 重复提交 | 不重复外发 |
| Runtime | T11 | Unknown 结果 | 不自动重试 |
| Runtime | T12 | Cancel | 停止新输入并收尾 |
| Runtime | T13 | Durable Run 断连 | 按授权继续 |
| Runtime | T14 | Scoped Run 断连 | 按 ADR 停止 |
| Security | T15 | 无权限 Task | 不可执行 |
| Security | T16 | 审批拒绝 | 动作不发生 |
| Security | T17 | 目标窗口变化 | TOCTOU 检查拒绝 |
| Security | T18 | MCP 绕过尝试 | 必须进入统一检查链 |
| Privacy | T19 | 截图泄露测试 | 默认不外发 |
| Privacy | T20 | 页面文字泄露测试 | 默认不外发 |
| Privacy | T21 | 事件元数据泄露测试 | 脱敏 |
| Outbound | T22 | 未授权工具 | 拒绝 |
| Outbound | T23 | 文件/终端/网络越权 | 阻止 |
| Outbound | T24 | 外部 Agent 取消 | 不继续产生受限动作 |
| Outbound | T25 | 外部 Agent 虚假成功 | 不标记已验证 |
| Compatibility | T26 | Zed E2E | 通过 |
| Compatibility | T27 | JetBrains E2E | 通过 |
| Compatibility | T28 | macOS Runtime 回归 | 通过 |

这 28 项是测试场景组，不是逐条单元测试数量。实施时每组还需要细分成功、拒绝、超时与故障注入等用例。

此外，Windows 的 Runtime 与 ACP 适配层测试应列入对应平台发布门禁，而不是由 macOS 测试代替。

### 发布门禁

| 门禁 | 必须满足 |
|---|---|
| G0 | Runtime、CLI、Hub 契约和 MCP 安全边界完成核对 |
| G1 | ACP Inbound 端到端执行成功 |
| G2 | Session、审批、取消、恢复可靠 |
| G3 | 长运行、unknown、断连和窗口一致性通过回归 |
| G4 | Outbound 隔离与数据外发安全验收通过 |
| G5 | Registry 安装和真实编辑器兼容测试通过 |

我建议 **G0～G3 是 Inbound 正式发布的必要条件，G4 是 Outbound 正式启用的额外条件，G5 是公开分发条件。**

这允许 Inbound 先发布，而不用等待 Outbound 完成。

---

# 十、和现有开发计划如何衔接

这部分非常重要，因为你现在有多个 Agent 并行开发。

我不建议让 ACP 工作组直接修改 Runtime 的核心契约。

应该明确负责人边界。

| 负责方 | 工作内容 |
|---|---|
| Runtime 负责人 f1 | 审核 Runtime 契约、Run 生命周期与执行安全 |
| CLI 工作组 | 接入 `agentdesktop acp` 和构建、分发 |
| Hub 工作组 | 复用身份、配对、能力授权及撤权 |
| ACP 工作组 | 协议适配、Session Binding、事件映射、编辑器集成 |
| QA/Integration | 端到端、安全、断连、跨协议回归 |

目前 CLI、Hub、Explorer 等项目正在并行推进。

我建议将 ACP 放在现有统一 Runtime 的下游，而不是再开一个核心架构分支。

**合并顺序建议：**

```text
Existing Runtime / CLI Baseline
              │
              ▼
      A0 Contract Audit
              │
        ┌─────┴──────┐
        │            │
        ▼            ▼
   MCP Security   ACP Mock Adapter
        │            │
        └─────┬──────┘
              │
              ▼
        P1 Inbound
              │
              ▼
        P2 Lifecycle
              │
              ├──────────→ Inbound Release
              │
              ▼
        P3 Outbound
              │
              ▼
        G4 Security Gate
              │
              ▼
        P4 Distribution
```

ACP 可以提前开始协议解析和 Mock Adapter 开发，但应等待安全基线通过后再合并真实写操作。

---

# 十一、建议对 PR #56 作出的具体修改

| 修改项 | 建议 |
|---|---|
| 正式命令 | `2ndscreen acp` 改为 `agentdesktop acp` |
| 统一 Runtime | 明确 ACP 必须经过 Runtime Client |
| ACP 版本 | 增加 v1/v2 兼容性决策 |
| Session | 区分 ACP Session 和 Runtime Session |
| Run 生命周期 | 明确 Scoped 和 Durable 的不同断连行为 |
| 持久执行授权 | ACP 参数不能自行升级 Run Lifetime |
| 任务发现 | 从 Registry 动态生成可用任务 |
| 事件 | 增加 Accepted / Executed / Verified / Unknown 的区分 |
| 幂等 | 复用 Runtime 请求去重和执行账本 |
| 审批 | 明确编辑器审批不能扩大平台权限 |
| TOCTOU | 等待审批后重新检查目标窗口 |
| 隐私 | 增加事件元数据和日志的脱敏 |
| Outbound | 增加进程隔离和工具绕过防护 |
| MCP | 单独安全修复 PR，作为发布门禁 |
| 测试 | 加入 T01～T28 与 G0～G5 |
| 发布 | Inbound、Outbound 分开验收和启用 |

我建议先保持 **PR #56 为 docs-only**。

不要让协议设计工作组在 RFC 未获得 Runtime 负责人认可之前，同时修改 Runtime、CLI 和 Hub 的公共契约。

---

# 十二、开发 Agent 执行指令（摘要）

原文第十二节的完整指令由 [03-lanes.md](03-lanes.md) 拆分到各工作线。要点：

1. 正式 CLI 命令为 `agentdesktop acp`；不兼容历史 2ndscreen / agent-bridge。
2. ACP、MCP、CLI、SDK 使用同一 Runtime API；ACP Session 只保存交互和 Runtime 关联。
3. 遵循 ADR v2.2 两类 Run 生命周期；ACP 不允许通过请求参数升级为 Durable Run。
4. Runtime 的身份、授权、动作复核、幂等、unknown、取消和审计语义不得被覆盖。
5. MCP 原子工具绕过执行检查链的问题单独登记并在发布前修复。
6. 协议版本以官方规范、当前 SDK 和真实编辑器兼容性测试为依据。
7. 先交付：RFC 修订稿、Gap Analysis、v1/v2 决策、API/Event Mapping、PR 依赖图、测试矩阵、G0～G5 清单。
8. f1 完成契约审核前，不修改 Runtime 冻结公共接口。

---

# 十三、最终架构裁决

| 决策 | 结论 |
|---|---|
| ACP 是否值得做 | **做，作为 AgentDesktop 标准协议接口** |
| ACP 是否替代 MCP | 不替代，两者并存 |
| ACP 是否替代 CLI | 不替代，复用 CLI 和 Runtime |
| 是否需要独立 ACP Runtime | 不需要 |
| 是否支持长任务 | 支持，但遵循 Runtime Run Lifetime |
| 编辑器关闭是否继续 | 仅符合 Durable 规则的任务继续 |
| 是否支持审批 | 支持，但不能创建长期授权 |
| 是否支持外部编程 Agent | 支持，先以受限执行体试验 |
| 敏感数据是否默认外发 | 不允许 |
| MCP 旁路是否需要修复 | **需要，作为正式发布门禁** |
| 是否立即上架 Registry | 不立即，完成兼容和安全验收后上架 |

**第一优先级：统一 CLI、MCP、ACP 的 Runtime 和安全执行路径。第二优先级：让 Zed 等编辑器可以把 AgentDesktop 当成一个真正的 Agent。第三优先级：把外部编程 Agent 变成安全、可审计、按任务授权的执行体。**
