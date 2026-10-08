# AgentDesktop Architecture Decision v2.2

日期：2026-10-08 · 决策人：Kevin · 状态：生效

本决策覆盖旧文档中与之冲突的描述。相关文档：总计划 v2.1（existing-code-and-execution-plan）、产品设计 v2.0、AgentHub v1 执行方案、GUI Explorer 实施方案 v1.0、GuiAiProvider × Explorer 整合设计 v2.0、RemoteDesk BOSS Agent 方案。已过期：Architecture FINAL v1.3 及其 single-repository merge plan。

## 一、Hub 形态：独立 App 配对授权，平台不托管

以 AgentHub v1、BOSS 方案与整合设计中的独立 App 模型为准。总计划 v2.1 的"插件托管"废弃。

AgentHub 负责：Agent Registration、Pairing & Authentication、Capability Grants、Connection Management、Platform Run Management、Approval Inbox、Diagnostics。

AgentHub 不负责启动、托管、重启或终止外部 Agent App。外部 Agent 自行管理业务任务、模型、业务数据和应用生命周期；AgentDesktop 只管理它提供的平台能力及由此产生的执行。

标记为 deprecated：Plugin Hosting、Agent Process Supervisor、Managed Resident Agent、Hub-managed Agent Lifecycle。旧 `agent-host.ts` / `agent-daemon.ts` 的进程托管不作为默认运行模式，可复用其协议处理、状态跟踪、授权和运行管理设计。将来如需托管，另设可选的 Managed Agent Runtime，不属本版。

## 二、界面：Design v2.0 主窗口是唯一主窗口

AgentHub v1 的八个页面是主窗口内 AgentHub 模块的子视图，不新建第二个应用或第二套导航。

```
AgentDesktop
├── Home
├── Agents        Overview[W01] · Connections[W03] · Add Agent[W02] · Agent Details
├── Runs          All Runs[W04] · Run Details[W05]
├── GUI Explorer  Explore · Learned Workflows · Replay & Verify
├── Inbox         [W06]
└── Settings      AI Providers · Permissions · Verification[W07] · Diagnostics & Usage[W08]
```

三条 UI 原则：不创建第二个主窗口；Runs 统一（AgentHub 与 GUI Explorer 发起的执行进入同一平台 Run 系统，以 `origin` 区分）；Inbox 统一（所有审批进入全局 Inbox）。

## 三、连接断开：区分 Connection、Run 和 Ownership

连接断开不天然等于取消 Run；是否继续取决于 Run 的权威所有者和生命周期策略。客户端不能自行决定断开后继续执行。

### 两类 Run

**A. Delegated Run**（外部 Agent 委托执行）：执行控制权来自该 Agent 的当前有效授权。
- 正常连接：允许执行。
- 断开：立即撤销后续输入准入；执行中的原生动作尝试安全取消并完成静止确认；无法确认的动作进入 unknown。
- 重连：不自动恢复旧 Run。Agent 进程不由平台终止。
- "立即停止"指禁止新输入进入执行器，不代表已开始的原生动作瞬间停止；UI 先显示 `stopping`，拿到静止证据后才显示 `stopped`。

**B. Durable Run**（平台拥有的持续执行，如用户在 GUI Explorer 点"开始探索"）：
- 关闭 Explorer 页面、关闭订阅连接、UI 重载、主窗口关闭但 Runtime 仍在：继续执行。
- 用户点停止：开始停止流程。授权撤销或安全问题：停止或进入安全终态。
- Runtime 异常退出：按持久账本恢复或标记 unknown，不盲目重复执行。
- Durable 不代表可绕过权限、取消、超时或资源控制。

### 生命周期模型

```
RunOwnership = external_client | platform
RunOrigin    = agent_hub | gui_explorer | workflow_replay | user
RunLifetime  = connection_scoped | platform_durable

PlatformRun { runId, origin, ownership, lifetime, clientId?, connectionId?,
  phase: queued | running | waiting_approval | waiting_input | stopping | ended,
  outcome?: success | failed | cancelled | unknown,
  quiescence: not_confirmed | pending | confirmed }
```

Runtime 强制：`external_client → connection_scoped`，`platform → platform_durable`。外部 Agent 不能通过传入 `platform_durable` 把委托执行变成平台自主运行；跨所有者的工作流交接需要独立的、经用户确认的接口，不是 `runs.start` 的参数开关。

### 断开行为矩阵

| 事件 | Delegated Run | Durable Run |
|---|---|---|
| 客户端正常连接 | 继续 | 继续 |
| 关闭 AgentHub 页面 | 继续 | 继续 |
| 关闭 GUI Explorer 页面 | 不受影响 | 继续 |
| UI 订阅断开 | 继续 | 继续 |
| 外部 Agent 连接断开并确认失效 | 停止新输入，进入停止流程 | 不受影响 |
| 外部 Agent 进程退出 | 检测连接失效后停止 | 不受影响 |
| 外部 Agent 重连 | 旧 Run 不自动恢复 | 不受影响 |
| 用户撤销相关执行授权 | 停止 | 受影响的授权同样失效；按平台权限规则停止 |
| 用户点击停止 Run | 停止 | 停止 |
| 用户点击全局停止 | 停止 | 停止 |
| Runtime 崩溃重启 | 不自动重做动作 | 从账本恢复；不能证明安全时进入 unknown |

页面连接与外部 Agent 的认证控制连接要区分：关闭 UI 或订阅暂时中断不等于 Agent 失去控制连接。外部 Agent 非预期失联可有短暂检测与重连窗口，但进入失联待确认状态即暂停新输入。

## 四、一套 Runtime

两类 Run 不产生两套执行引擎：Platform Run Service → Admission Control → Native Executor → Execution Ledger。区别只在所有者、授权范围和生命周期。GUI Explorer 不单独建动作账本；AgentHub 不单独实现 GUI Executor；业务 Agent 不内置专用 Runtime；停止、审批、资源锁、幂等、unknown 共用同一机制。

## 五、新增跨模块回归测试（发布门禁）

| 编号 | 测试 | 预期 |
|---|---|---|
| ADR-01 | 外部 Agent 建立连接并启动 Delegated Run | 正常执行 |
| ADR-02 | 关闭 AgentHub 页面 | Run 不受影响 |
| ADR-03 | 外部 Agent 控制连接失效 | 新输入立即被阻断；Run 进入停止流程 |
| ADR-04 | 外部 Agent 重新连接 | 旧 Run 不自动恢复 |
| ADR-05 | 外部 Agent 请求 `platform_durable` | 拒绝未经授权的所有权提升 |
| ADR-06 | GUI Explorer 启动 Durable Run 后关闭页面 | 继续执行 |
| ADR-07 | GUI Explorer 运行期间 UI 重载 | 原 Run ID、历史及进度保持一致 |
| ADR-08 | 对 Durable Run 点击停止 | 返回停止受理；取得静止证据后才显示结束 |
| ADR-09 | 全局停止同时作用于两类 Run | 全部关闭新输入，逐项返回停止结果 |
| ADR-10 | Durable Run 运行期间 Runtime 崩溃 | 不盲目重做已发动作；按证据恢复或进入 unknown |

并入 AgentHub v1 的 79 项矩阵。

## 六、最终决策

1. AgentHub 采用独立 App 配对授权架构；平台不托管外部 Agent 的进程、业务任务和生命周期；总计划 v2.1 的 Plugin Hosting 废弃。
2. Design v2.0 是唯一的主窗口设计；AgentHub 八页整合为 Agents、Runs、Inbox、Settings 下的视图。
3. 所有平台执行统一使用 Runtime 的 Run、Session、Resource、Approval 和 Ledger。
4. Run 区分 `external_client / connection_scoped` 与 `platform / platform_durable`。
5. 外部 Agent 控制连接失效后立即阻止新输入并开始停止其 connection-scoped Run；断连不终止外部 App，重连不自动恢复旧 Run。
6. GUI Explorer 的 Durable Run 不因页面关闭、订阅断开或窗口重载而取消。
7. 外部 Agent 不得通过普通 Run 创建参数获取 Durable 所有权。
8. 停止、取消、授权撤销、unknown 和崩溃恢复使用统一 Runtime 的权威状态及证据。
9. ADR-01～10 为集成版本验收门禁。

**如旧文档与本决策冲突，以 Architecture Decision v2.2 为准。**
