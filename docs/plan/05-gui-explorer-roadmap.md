# 5 GUI Explorer 路线

依据：K 第二节；ADR 第二、四节；GuiAiProvider × Explorer 整合设计 v2.0；GUI Explorer 实施方案 v1.0。

## 5.1 两个阶段

| 阶段 | 内容 | 时间 |
| --- | --- | --- |
| 基础运行能力（P00–P04） | 模型服务管理与切换、统一 GUI 执行循环、截图与动作与观察与验证、Run 生命周期、取消与超时与错误恢复、模型调用与实际动作的统一记账、与 Runtime 的统一契约 | 现在：A2、A3、A6、X1、U6、U7 |
| 学习能力（P05–P06） | 操作流程记录、成功经验积累、Workflow 提取与复用、运行前检索经验、自动验证结果、失败经验分析、基于历史提升成功率 | 独立阶段 L1–L4，基础稳定后开始 |

## 5.2 基础运行能力的具体要求

- 一个循环：GuiRunDriver 保留，观察 → 先验证是否已完成 → 模型建议 → Runtime 执行 → 新观察 → 三值验证。ProcedureRunner、RecoveryPlanner 只返回策略，不建第二个循环。
- 模式：`auto`、`explore`；`replay_only` 的接口与 inferenceBinding 可空在 A6 落地，实际可回放的流程等 L 阶段。
- 默认限额：20 个逻辑步、120 秒、单步最多 2 次模型尝试、全 Run 最多 30 次、单次输出 1024 tokens、5 张图、图像总量 8 MiB、单次 wait 最多 5 秒；配置只能收紧。
- 运行归属：UI 发起为 Durable Run（`origin=gui_explorer`），关闭页面不取消；外部 Agent 经 `unit.run` 发起为 Delegated Run。
- 模型只返回 Proposal；所有输入经 Runtime 同一执行入口；模型 finish 只触发复核。
- 三值验证：matched / contradicted / inconclusive；首批谓词 `staticTextEquals`、`elementExists`、`valueEqualsParameter`、`all/any/not`；观察不完整时 not(found) 为 inconclusive。
- 停止：先关准入，再等在途动作静止；迟到模型建议丢弃，dispatch=0。

## 5.3 现在就要留好的学习数据接口

学习层暂缓不等于删字段。契约与 A6 的存储必须包含下列字段，但**现在不实现 L1–L4 的数据库与学习系统**：先把事实记录准确，再提取可信经验。

| 位置 | 字段 | 学习层用途 |
| --- | --- | --- |
| Observation | `captureSequence`、`geometryRevision`、`coverage`、元素的 role/label/automationId 与容器路径 | 可信转移、语义定位 |
| ActionReceipt | `dispatchSequence`、`proposalId`、`inferenceAttemptId`、实际目标证据、`confirmationObservationId` | 一步一条可信转移 |
| Run | `unit.goalHash`、`guiProfileRevision`、`episodeEligible`、`excludedReason` | 判断能否成为学习样本 |
| 存储 | Run 事件只追加，带 sourceEventId 去重 | Episode 组装 |
| 隐私 | 输入文本与参数分开存，参数值不写进步骤 | 参数化流程 |

## 5.4 学习阶段 PR（L1–L4）

| PR | 内容 | 验收 |
| --- | --- | --- |
| L1 | StateNormalizer、LocatorResolver（唯一定位与歧义处理）、EpisodeAssembler（从可信记录组装，unknown 与缺栅栏的轨迹排除） | 伪造、缺失、unknown、错作用域的样本不能成为正例 |
| L2 | ProcedureCompiler、Validator、ProcedureRepository（不可变 revision、CAS stateVersion、SQLite outbox） | 参数化；同一结构两个 writer 只有一个成功 |
| L3 | ProcedureRunner 接入循环、`replay_only` 实际回放、验证 cohort 与 PromotionPolicy（3 次独立 reset、至少 2 种布局） | 无 key、断网时回放成功，推理调用 0；共享 resetId 只算 1 个样本 |
| L4 | RecoveryPlanner、失败经验、`gui.knowledge.*` 与 `gui.procedures.*` 等方法、一级 GUI Explorer 页面（G03–G06、G08）、示范（G07） | 布局变化有界修复并生成新版本；撤销即时生效 |

中性验收任务：DraftLab（打开草稿、填写名称、提交计数保持 0），不依赖任何业务应用。

## 5.5 不做

不训练模型权重（L3 之后另立项目）；不为学习遍历真实账号；不跨 client、跨账号共享经验（默认关闭）。
