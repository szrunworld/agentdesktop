# X1 Explorer 基础能力

依据：docs/plan/02 §2.4 X1、05 §5.2、08 GX-13…GX-20；GUI Explorer 实施方案 v1.0 §7.4、§8、§8.2。前置 A6（#240、#251）已合入。

X1 分三个 PR，按顺序合入，各自验收：

| PR | 内容 | 用例 | 状态 |
| --- | --- | --- | --- |
| X1-1 | 三值验证与首批谓词 | GX-13…GX-16 | 本 PR |
| X1-2 | 进展与循环检测：重复状态、A-B-A 小环、长期无进展、预算统一计数 | GX-17…GX-20 | 未开始 |
| X1-3 | 有界恢复：检测到停滞后最多一次局部重新观察与重新规划，仍无进展则有界结束并说明原因 | GX-17…GX-20 的恢复分支 | 未开始 |

学习预留字段（05 §5.3）不在 X1 里补，留给 L1 之前的契约增量。

## X1-1 三值验证

### 结果

每个谓词在一次观察上得到三种结果之一：

| 结果 | 含义 | Run |
| --- | --- | --- |
| matched | 完整、一致的证据表明条件成立 | 只有它算成功 |
| contradicted | 完整的证据表明条件不成立 | 继续观察或有界结束 |
| inconclusive | 这次观察无法判定 | 不算成功；继续观察或有界结束 |

`inconclusive` 带原因：

| reason | 何时出现 |
| --- | --- |
| `elements_partial` | 元素树读取被截断（observe `coverage.ax = partial`），而结论依赖“没找到” |
| `elements_unavailable` | 元素树没读到（超时、忙、出错） |
| `ambiguous` | `value_equals_parameter` 的标签对应了不止一个元素 |
| `target_missing` | `value_equals_parameter` 的标签在完整的树里找不到 |
| `value_unreadable` | 唯一的目标元素没有可读的值 |

核心规则：**只有完整读取的元素树才能证明“不存在”**。读取不完整时，“找到了”仍然算数，“没找到”只能是 inconclusive。`not(…)` 不会把“没读到”变成成立。

### 谓词

| kind | 字段 | matched 条件 |
| --- | --- | --- |
| `element_text_equals` | role 固定 `static_text`、text | 有一个静态文字元素的全文等于 text（V1 原样保留） |
| `element_exists` | role，label 和 text 至少一个 | 有一个该 role 的元素，label 和 text 都相等；多个同样算存在 |
| `value_equals_parameter` | role、label、param | 唯一一个该 role 且 label 相等的元素，值等于 `goal.params[param]` |
| `all` / `any` | of：1–8 个谓词 | all：全部 matched；any：至少一个 matched |
| `not` | of：1 个谓词 | 内层 contradicted |

组合规则：

- `all`：任一 contradicted → contradicted；全部 matched → matched；其余 inconclusive。
- `any`：任一 matched → matched；全部 contradicted → contradicted；其余 inconclusive。
- `not`：matched 与 contradicted 互换，inconclusive 保持。
- `verification.all` 里的多个谓词合起来就是一个 `all`。

限制：最多嵌套 4 层；`verification.all` 里所有谓词合起来最多 16 个（不是每个成员各 16 个）；每个字符串 1–1024 字符。比较沿用 v2 的归一化（只去掉不可见的双向格式字符，按 Unicode 规范等价比较），不做模糊匹配。

### 参数

- `value_equals_parameter` 在 `unit.run` 准入时，从 `goal.params` 取值，固定进 Run 的绑定。模型改不了它，Run 运行中也不会再读参数。
- 线上形式（事件、绑定的 JSON）只写参数名，不写值。
- 参数取值规则：字符串原样（不能为空）；整数写成十进制；布尔写成 `true` / `false`；带小数的数字没有唯一的屏幕写法，拒绝。
- 缺参数、参数值不可用、树超限 → `schema_invalid`，`details.reason = verification_invalid`，不建 Run。
- 契约里没有的 kind：线上的契约校验先拒绝，返回 `schema_invalid`（F40-06 第 2 行）。
- 契约里有、但这个后端验证不了的叶子谓词 → `capability_mismatch` / `predicate_unsupported`（F40-06 第 14 行不变）。

### 歧义与 dispatch=0

08 文件 GX-15 写的是“歧义控件 dispatch=0”。X1-1 里歧义只出现在验证这一侧：验证器从不在两个同名元素里挑一个，结果是 `inconclusive / ambiguous`，Run 不会因此成功。

现在的动作是 UI-TARS 给出的坐标，目标一致性由 Runtime 的 G0 检查保证，不存在“按名称选控件”这一步。按语义定位、遇到歧义就不派发，属于 L1 的 LocatorResolver。GX-15 的端到端用例因此验证的是：模型说完成、目标有歧义时，不成功、不派发任何输入。

### 改动

- `GuiVerification` 从单一结构改为谓词树（`GuiRunTypes.swift`）。
- `GoalVerification` 增加 `inconclusive` 和 `reason`。
- `ObservedElement` 分开带 `label` 与 `value`。
- `ObservationBundle.elementCoverage` 由 Runtime 的 observe `coverage.ax` 传来（`RuntimeGuiPorts.coverage`）。
- Explorer 循环只把 matched 当成功；`unit.verification` 事件可以带 `inconclusive` 和 `reason`。
- 运行详情页把 inconclusive 显示为“无法判定”。
- 契约（只增不改）：
  - `service.schema.json` 的 `GuiVerification` 改为 oneOf 五种形状；
  - `GoalVerification.status` 增加 `inconclusive`，并新增可选字段 `reason`；
  - `runtime.capabilities.gui.verificationPredicates` 可列 3 种；
  - `runtime.schema.json` 里 `unit.verification` 的 status 增加 `inconclusive`，并新增可选字段 `reason`。

### 测试

| 用例 | 测试 |
| --- | --- |
| GX-13 完整观察 | `X1PredicateTests.gx13_completeObservationDecides` |
| GX-14 不完整观察 | `gx14_incompleteObservationNeverProvesAbsence`（partial、unavailable）、`gx14_partialReadNeverSatisfiesNot`（Run 级） |
| GX-15 歧义控件 | `gx15_ambiguousOrMissingTargetIsInconclusive`、`gx15_ambiguousTargetNeverSucceedsAndDispatchesNothing`（Run 级，事件按契约校验） |
| GX-16 动态文字 | `gx16_lateTextSucceedsOnlyWhenSeen` |
| 准入与契约 | `X1AdmissionTests`（线上形式不含参数值、各种越界、嵌套里的不支持谓词、缺参数、契约形状正反例） |
| Runtime 传递 | `RuntimeGuiPortsTests.observeCoverageBecomesElementCoverage`、`observeHandsTheModelTheBoundWindowWithExactTransforms` |

只有单元测试和 Mock 的 Run 级测试，不算真机验收。真机部分（MAC-001 重跑里加入不完整 AX 读取的场景）等物理 Desktop 的真机验收通过、#168 关闭之后再做。

## X1-2、X1-3 的设计要点（预告，以各自 PR 为准）

- **状态指纹**：只用于停滞检测，不证明成功。
  - 来源：元素树的 role 与 label，以及字段的值。
  - 忽略：观察编号、时间、看起来像时钟的文字。
  - 读取不完整时不算指纹，那一步不计入停滞。
- **同状态同动作**：同一状态下，同一个动作意图连续两次没有带来变化，就不再执行第三次，转入一次恢复。
  - 动作意图 = 动作类型 + 目标区域 + 文本。
- **A-B-A**：状态回到两步前，且没有验证进展，转入一次恢复。
- **长期无进展**：连续 3 个动作状态都没变，转入一次恢复。
- **恢复**：每个 Run 最多 1 次（默认值，配置只能收紧）。恢复就是重新观察，并告诉模型上一步无效；第二次触发就有界结束。
  - 结束方式：`outcome: failed`，`closingReason` 为 `no_progress` 或 `loop_detected`。
  - 事件：`unit.recovery` 带新的 kind（契约增量）。
- **预算**：等待、恢复、重新观察都计入同一个步数与时间预算，换模型或换配置不会清零（GX-20）。
- **unknown**：结果未知的动作不进入“再试一次”。遇到 unknown，Run 照旧进入 waiting_user 或结束，不重放。
