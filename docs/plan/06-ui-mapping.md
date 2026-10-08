# 6 界面映射

依据：ADR 第二节（一套主窗口、Runs 统一、Inbox 统一）；Design v2.0（`docs/design/v2/screen-map.json`、`ui-checks-54.json`、32 张渲染图）；Hub v1 W01–W08；Explorer G01–G08；裁决 D30–D35。

## 6.1 最终导航（信息架构不随交付批次改变）

```
AgentDesktop 主窗口
├── Desktops        总览 · Desktop 详情[预览 | 连接 | 输出 | 详情 | Explorer] · 并排 · 独立预览窗口
├── Agents          总览 · 接入应用 · Agent 详情与授权
├── Runs            全部运行 · 运行详情 · 动作记录 · 动作回执
├── GUI Explorer    运行历史 ·（P2）已学流程 · 回放与验证 · 应用知识
├── Inbox           平台审批与问题（P1；首发显示空态与说明）
└── Settings        通用 · 权限 · AI 连接 · GUI 配置 · 能力测试 · 核实 · 诊断与用量
菜单栏弹层：运行状态 · 打开主界面 · 打开某个 Desktop 预览 · 停止所有输入 · 设置
```

ADR 树里的 Home 即 Desktops 总览。Design v2.0 侧栏的「Agent 接入」「操作记录」「AI 与 GUI」不再是一级入口，页面本身不变。

- GUI Explorer 有两个入口但只有一套产品：从 Desktop 详情启动，运行进入统一 RunStore；一级 GUI Explorer 查看跨 Desktop 的探索记录与（P2）学会的流程。两者都是视图，不是第二个主窗口或第二套执行系统。
- Inbox 在 U9 之前保留导航位置，显示「尚未启用：平台审批将在后续版本提供」与说明，不用静态假数据营造可审批的效果。

## 6.2 页面对照表

| 位置 | Design v2.0 | Hub v1 | Explorer | 交付 | Runtime 方法 |
| --- | --- | --- | --- | --- | --- |
| Desktops › 总览 | P01、P03 | — | — | U2 | desktop.list、events.subscribe |
| Desktops › 创建 | P04、P05 | — | — | U2 | desktop.create（launch/bind）、app.list、window.list |
| Desktops › 详情 | P06 | — | — | U2 | desktop.show、observe、request.list |
| Desktops › 并排 | P07 | — | — | U2 | 同上 |
| 独立预览窗口 | P08 | — | — | U2 | desktop.show（画面走 ScreenCaptureKit） |
| Desktops › 详情 › 控制 | P12–P18 | — | — | U3 | desktop.stop/takeover/handback/closePlan/destroy、run.reconcile |
| Desktops › 详情 › Explorer | P27–P29 | — | G01、G02、G07 | U7（G07 示范为 P2） | unit.run、run.show/events/cancel |
| Agents › 总览 | — | W01 | — | U4 | hub.clients.list、hub.connections.list |
| Agents › 接入应用 | P09、P10、P11 | W02 | — | U4 | hub.pairing.start/approve/deny；CLI、MCP、ACP 示例 |
| Agents › Agent 详情与授权 | — | W03 | — | U4 | hub.clients.show、hub.grants.* |
| Runs › 全部运行 | — | W04 | — | U5 | run.list |
| Runs › 运行详情 | — | W05 | G02 的证据部分 | U5 | run.show、run.events |
| Runs › 动作记录与回执 | P19、P20 | — | — | U5 | request.list/show/export |
| GUI Explorer | — | — | G03–G06、G08 | U7 只做运行历史；其余 L4 | gui.knowledge.*、gui.procedures.*、gui.validations.* |
| Inbox | — | W06 | — | U9（P1） | inbox.list/show/resolve |
| Settings › 通用 | P21 | — | — | U6 | 本地偏好 |
| Settings › 权限 | P02、P22 | — | — | U6 | runtime.status 的 PermissionState |
| Settings › AI 连接、GUI 配置、能力测试 | P23–P26 | — | G08 部分 | U6 | ai.connections.*、ai.profiles.*、ai.tests.start、ai.operations.* |
| Settings › 核实 | P17 的核实部分 | W07 | — | U9（P1） | run.reconcile、request.list |
| Settings › 诊断与用量 | P30 | W08 | — | U6 做用量，U9 做诊断导出 | ai.usage.summary、runtime.capabilities |
| 菜单栏 | P31 | — | — | U8 | runtime.stopAll、desktop.list |
| 退出与后台 | P32 | — | — | U8 | runtime.stopAll，等静止 |

## 6.3 共用规则（每个页面都要满足）

- 只从正式 Client 的快照与事件取数；不从文件或数据库拼状态；正式服务失败不回退样例数据。
- 停止类状态先显示「停止中」，拿到静止证据才显示「已停止」；executor 证据缺失时说明原因。
- 登记、连接、授权三种状态各自显示，不压成一个颜色。
- 关闭窗口与停止执行分开；关闭预览不关闭 Desktop；关闭主窗口默认转后台。
- 没有「重试未知动作」按钮。
- 视觉 token、布局尺寸、组件命名沿用 Design v2.0（见 02 文件 U1）。

## 6.4 动作结果的三级展示（MAC-001 之后的硬规则）

Runtime 可能返回"投递成功"而目标窗口没有变化（PR #37）。UI 不得把受理或投递展示成成功。只用正式契约字段映射，不另建状态：

| UI 文案 | 条件（runtime/1 字段） |
| --- | --- |
| 已受理 | 请求已入账（request.show 有记录），尚无回执 |
| 未发出（附原因） | `delivery = not_dispatched`，显示错误码与说明，如 `target_moved`、`invalid_target`（RT-24 遮挡场景）、`input_disabled` |
| 已执行，未验证 | `delivery = dispatched` 且 `execution = completed`；`verification = not_requested` 时一律用这个文案 |
| 执行失败 | `execution = failed` |
| 结果未知 | `delivery` 或 `execution` 为 `unknown`；只能核实，不能重试 |
| 已验证成功 / 验证未通过 | 只来自 GUI 单元运行（`unit.run`）的验证事件与 `run.show` 的 unit 结果；或调用方自己报告并标明来源 |

单次 act 的 Run 在投递成功时 `outcome = success`，Runs 列表对 `kind = act` 的 Run 显示"已投递"而不是"成功"。`businessResult` 纳入契约后一律显示"业务结果：未评估"。

## 6.5 验收依据

- 54 项交互检查（`ui-checks-54.json`）按 UC01–UC54 编号，逐项在原生界面重做，归入 U2–U8（见 02 文件）。网页原型的通过不转记。UC53（无未捕获 JS 异常）、UC54（无真实网络请求）改为原生等价项：无未处理异常日志、测试运行不发真实模型请求。
- 每个页面在测试进程里渲染成 1440×1000 图，与 `docs/design/v2/Pxx.webp` 并排放进 PR 的验收记录。
- Hub 页面另按 Hub v1 第 3.3 节跨页面规范与 HB-UI 用例验收（08 文件）。
