# 原生 Runtime 尚待接管的执行语义

日期：2026-10-08。状态：**待实现与目标系统验收**。

AgentDesktop 现为唯一维护仓库。本轮保留现有视觉、规划、学习和回放算法，删除当前编译源中的旧 `Bridge.swift` 与专属 `BridgeTests.swift`，不再发布旧探索 Bridge 接口。删除旧入口不代表下列语义已经由原生 Runtime 接管，也不构成 `GuiAiProvider` / `GuiExplorer` 实现完成的证据。

## 来源与读取方法

原导入完整保存在本仓提交 `49218be42ed0af1cdaeee424d684103551d79a31`。后续开发可以直接从 AgentDesktop 的 Git 历史读取实现和测试，无须继续维护源仓或恢复旧运行入口：

```bash
git show 49218be42ed0af1cdaeee424d684103551d79a31:engine/Sources/TarsAgent/Bridge.swift
git show 49218be42ed0af1cdaeee424d684103551d79a31:engine/Tests/TarsAgentTests/BridgeTests.swift
```

这些历史实现是复用和回归依据，具体规则仍须服从当前 Runtime / BOSS 契约。例如历史 Bridge 中的招聘平台控件识别应交给业务策略，不应固化为所有应用的公共规则。

## 从旧 Bridge 提取的有效语义

下表各项当前均未完成原生接管。实现时采用新的类型与接口，不要求兼容历史 JSONL 字段或子命令。

| 能力 | 历史实现与依据 | 原生落点 | 应验证的结果 |
|---|---|---|---|
| 请求与目标绑定 | `ExplorationRequest.parse`；任务、单元尝试、screen、PID、window、预算与允许效果 | Runtime API 请求校验和执行上下文 | 无效或缺少目标的请求在任何动作前拒绝；一次尝试关联一个明确 Desktop 与窗口 |
| 观察记录 | `RecordingScreen`、`observed`、`BridgeWindow`，记录快照 ID 和窗口几何 | Runtime 观察服务 | 新观察能追溯到 Desktop、PID、window、坐标空间和截图尺寸；动作能引用对应观察 |
| 动作前最后检查 | `perform` 在调用实际输入前检查效果、窗口、点位、停止与 deadline | Runtime 受管执行器 | 模型等待期间目标移动、窗口退出、超时或停止后，不向原目标继续投递 |
| 真实动作回执 | `action_started`、`action_finished`、`executed`，包装实际 `inner.perform` | Runtime 动作账本 | 每次投递只记一次；准备动作事件不记作完成；回执携带动作 ID、前置观察、路由、开始结束时间 |
| 未知投递结果 | `perform` 捕获投递异常并标记 `unknown` | Runtime 动作结果 | 断连不能被转换为确定失败并自动重发；恢复先观察和核实实际效果 |
| 模型用量与预算 | `BudgetedModel`、`complete`、`recordUsage`，轮数、deadline 和 token 预算 | Provider 用量报告与 Explorer 预算控制 | 模型请求即使因取消而未取得响应也计一次；未知 token 不能冒充零用量；有 token 上限时无法证明剩余额度须停止继续调用 |
| 协作停止 | `cancel`、`shouldStop`、`acting`，无在途动作可结束，有在途动作先取得其终态 | Runtime 停止协议和执行器 | 停止一经接受不投递新动作；当前输入结束后再确认停止；不能确认时不转移 Desktop 控制权 |
| 失败分类 | 超时、预算耗尽、取消、禁止效果、模型错误、观察错误分别报告 | Explorer / Runtime 类型化结果 | 观察失败不伪装成用完模型轮数；过期模型的完成回复也不能覆盖 timeout |
| 流程候选生成 | `proposal` 仅从真实成功执行轨迹生成参数化步骤 | Runtime Learning / Procedure | 失败或 unknown 轨迹不自动发布成可回放流程；候选仍需新观察验证并按当前规则晋级 |
| 单一终态 | 历史输出协议保证终态之后不再输出其他运行事件 | Runtime 事件状态机 | 一个单元只有一个终态；停止、错误和正常完成竞争时不会双重完成 |

## 现有原生代码仍存在的接缝

以下问题在并仓审查中确认。本轮只整理源码与运行身份，没有改变这些执行算法。

1. **同一 Desktop 的动作顺序。** Swift `AgentRuntime.handle` 对每次输入创建 `Task.detached`。`InputEngine` 的锁仅保护快照字典；完整动作和观察到动作的绑定需要每 Desktop 执行机制。不同 Desktop 应能独立运行，不能以一个全局 GUI 锁替代。
2. **停止与资源销毁。** 当前 `runtime.stop()` 未等待所有在途输入结束。需要先封闭新动作入口，再等待当前执行者的终态，随后销毁资源或移交控制权。
3. **模型请求取消。** Swift 模型请求使用同步等待；裸 `TarsAgent` 主要在循环开头检查取消。C# Agent 与模型接口未贯穿取消令牌。需要覆盖模型请求期间、回复返回后、多动作回复之间和输入期间的停止。
4. **Windows 输入归属。** C# Agent 和 MCP 通过启动当前 CLI 执行动作，UI Automation / Win32 投递仍由 CLI 持有。需要复用现有算法，将执行权接到原生 Runtime，令 CLI / MCP 成为薄调用方。
5. **零模型回放的模型前置配置。** 两端 CLI 在查找流程前就构造并校验模型配置。已有回放算法可以不调用模型，但目前无 API key 仍可能无法进入。后续应先尝试流程，实际探索时才按需取得 Provider。
6. **流程存储并发。** 两端现按 app 读取并整体覆盖流程文件。并行 Desktop 学习同一 app 可能覆盖彼此更新；C# 还使用固定 `.tmp` 文件。需要串行或事务式更新和唯一临时文件。
7. **单元成功条件。** 裸 `TarsAgent` 接受模型 `finished`，并可将连续无动作回复视为完成。新的 `run_unit` 必须由新观察验证后置条件；模型声明、输入回执、GUI 成功与 BOSS / Recruiting 业务成功分别记录。

## 可复用测试与新增验收

历史专属测试已经从当前测试目标移除，下面列出的测试意图应在新 Runtime 接口上重新实现并运行。不要将历史测试的通过状态转记为新实现通过。

| 回归主题 | 历史测试参考 | 新验收要求 |
|---|---|---|
| 一次动作一次回执 | `aFinishedUnitReportsEachActionOnceWithAProposal` | 一次投递有唯一动作 ID 与终态，流程只使用已执行成功步骤 |
| 投递前 deadline | `noInputAfterTheDeadline`、`aFinishAfterTheDeadlineIsATimeout` | 模型晚返回时，点击不投递，完成声明也不覆盖超时 |
| 目标与效果边界 | `anEffectTheUnitDoesNotAllowIsRefused`、`aPointOffTheWindowIsNotSent` | 拒绝的动作投递数为 0；业务策略由当前调用方提供 |
| 预算与错误区别 | `roundsLostToAnUnreadableScreenAreAnErrorNotABudget`、`reportedTokensAreSummedAgainstTheLimit`、`unknownTokensUnderALimitStopAfterOneCall` | 观察错误、模型轮数和 token 不混算；未知量不伪装成可继续执行 |
| 停止与在途动作 | `aCancelMidActionLetsItFinishThenStops`、`aCancelBetweenActionsEndsAtOnce`、`runningPastTheDeadlineTimesOut` | 无新动作越过停止点；确认停止之前不复用控制权 |
| 未知结果与学习 | `aBrokenDeliveryIsUnknownAndNotRetried`、`aFailedActionGivesNoProposal` | unknown 不重发，失败轨迹不晋级流程 |
| 单一结束 | `aModelErrorIsAFailureNotAFinish`、`linesAreSingleAndNothingFollowsTheLast` | 模型错误不报成功，终态唯一 |
| 原生新增组合 | 当前 Swift/C# Learning 测试与真实应用 | 同一 Desktop 有序、不同 Desktop 并发；取消模型请求；无 API key 的有效流程回放；并行学习无覆盖；宿主继续操作 |

## 本轮整理后的身份与验收范围

- Swift CLI product 为 `agentdesktop-cli`，产品包装器由根打包脚本发布为 `agentdesktop`。独立旧宿主不再属于 engine 的 product / target。
- Windows 宿主为 `AgentDesktop.Host.exe`，CLI 为 `agentdesktop.exe`；控制 pipe、单实例 mutex、默认数据目录与测试环境变量使用当前产品名称，没有旧名称别名。
- Swift 模型配置为 `~/.config/agentdesktop/model.env`，流程目录为 `~/.config/agentdesktop/procedures`。Windows 模型配置为 `%USERPROFILE%\.config\agentdesktop\model.env`，流程目录为 `%APPDATA%\agentdesktop\procedures`。
- 模型配置只使用 `AGENT_MODEL_API_KEY`、`AGENT_MODEL_BASE_URL`、`AGENT_MODEL`。默认模型服务和模型名称保持现有行为；配置优先级仍为环境变量优先、当前配置文件补齐未设置值。
- 当前工作环境不提供 Swift、.NET 或 Windows 图形会话。本轮静态检查不能代替 macOS / Windows 编译、已有测试重跑与真机验收。上述原生接管任务未完成前，继续标注为待实现。
