# U9 验收记录：Inbox（Hub W06）、核实（W07）、诊断导出（W08）

分支 `ui-u9-inbox-reconcile`，基于 main `0feb4b1`。Runtime 侧来自 PR4：#269（`inbox.list/show/resolve`、`run.reconcile`）、#277（`diagnostics.export`）。

## 截图（Mock，离屏渲染 1440 × 1000）

| 文件 | 内容 |
| --- | --- |
| `W06-inbox.png` | Inbox 列表：结果未知的动作与等待人工处理的运行，筛选（状态 / 类型 / Desktop） |
| `W06-inbox-unknown-detail.png` | 结果未知动作的详情与核实表单（运行已结束、已确认静止） |
| `W07-reconciled-outcome-still-unknown.png` | 记录「未执行」后：这项已关闭，运行的最终结果仍是「结果未知」 |
| `W06-question-stopping.png` | 停止等待中的运行：已受理，显示「停止中：等待输入静止」，不显示已停止 |
| `W08-diagnostics-preview.png` | 诊断导出预览：分节计数与「导出永远不包含」清单 |

用 `AGENTDESKTOP_UI_SNAPSHOTS=<dir> swift test --filter InboxU9Tests` 重新生成。

## HB-UI 用例

| 编号 | 结果 | 依据 |
| --- | --- | --- |
| HB-UI-05 停止两步 | 通过（Mock） | `stopWaitingRunIsTwoSteps`：受理后为「停止中」、条目写「已请求停止」；确认静止后才是「已停止」；`inbox.resolve` 只发一次 |
| HB-UI-06 核实只追加 | 通过（Mock） | `reconcileOnlyAppends`：两条记录按序保留；`run.show` 的 outcome 仍为 unknown，`request.show` 仍为 unknown；没有 `act` 调用 |
| HB-UI-07 诊断导出无密钥 | 通过（Mock） | `diagnosticsPreviewThenExport`：预览不写产物、不读产物；导出内容不含 `adt1_`；页面列出 Runtime 返回的排除项 |
| HB-UI-08 审批过期与一次消费 | 不适用 | Runtime 目前不产生 `approval` 项（#269「后续事项」），页面没有审批入口 |

其他：未静止的运行不能核实（`notBeforeTheRunIsQuiet`，不发请求）；revision 冲突时重新读取、保留草稿、不自动重发（`conflictReReadsAndDoesNotResubmit`）。

## 未做

- 真实 Runtime（进程内端口）上的手工验收：没有启动应用。
- 900px 窄窗口与读屏的人工检查。
