# ACP 验收门禁 G0～G5

状态：2026-10-08 第二轮，工作线 D。全部条目当前为 NOT_RUN。

## 一、规则

- **只认执行过的证据**：断言、`swift test` 的退出码、带记录的真机运行。编译成功不算。测试命令看退出码，不经管道截断。
- **四种状态**：PASSED、FAILED、BLOCKED（缺环境或缺外部依赖）、NOT_RUN。缺依赖记 BLOCKED，不记 PASSED。
- **三层证据**（Q 的 [tests/README](tests/README.md) 第一节）：L1 一致性（假编辑器、假 Runtime）、L2 真 Runtime（测试副本）、L3 真编辑器。A2、A4、A6 合入前，L1 通过不算端到端验收（Kevin 裁决附加约束 6）。
- **真机只在测试副本**：`/tmp/adt-*`，用自己的 socket 与文件凭据，不碰产品 endpoint 与登录钥匙串。
- **同一提交**：一个门禁的全部条目在同一个提交上跑。
- **用例编号**：T01～T28 来自 [方案原文](00-input-plan-v1.0.md) 第九节；ACP-29～31 来自 Kevin 裁决附加约束 7；细化后的 ACP-Txx-nn 等用例在 [tests/cases.csv](tests/cases.csv)，本文「Q 用例」列取自 tests/README 第六节。RT、CT、SEC、HB、ADR、GX 来自 [docs/plan/08](../plan/08-e2e-acceptance-plan.md) 与 [ADR v2.2](../architecture/ADR-v2.2-hub-ui-run-lifetime.md) 第五节。
- **发布含义**（K3）：G0～G3 并行开发，不阻塞其他工作线；G3 完成后评估是否进首版候选；正式发布须 G4、G5 与 Runtime 集成验收全部通过。G4 同时是出站启用的条件。

## 二、G0：Runtime、CLI、Hub 契约与 MCP 安全边界核对完成

| 编号 | 检查项 | 用例 | Q 用例 | 需要的证据 | 外部依赖 | 状态 |
| --- | --- | --- | --- | --- | --- | --- |
| G0-01 | 宿主只有一个 Runtime 监听 | RT-01 | ACP-T18-01 | 测试副本启动后 `lsof -U -p <pid>` 只列一个 socket；没有 `ai.sock`、旧引擎 socket；按协议判定（A2 后端点名为 `control.sock`，见 04 C-19） | A2 | NOT_RUN |
| G0-02 | MCP 与旧入口不能绕过 Runtime | T18 | ACP-T18-02～04 | #29 的 `agentdesktop mcp` 发一次 `act`，账本有该 requestId；自编译的引擎 CLI 与 `ai.sock` 不能驱动窗口；包内只有一个 CLI | A2、#29 | NOT_RUN |
| G0-03 | 所有 ai.* 经 runtime/1 | RT-02 | 无 | AI/GUI 测试经 runtime/1 重跑，`swift test` 退出码 0 | A2 | NOT_RUN |
| G0-04 | 同一请求只执行一次 | CT-05、CT-06、CT-07 | 无 | 契约套件 summary.json；`RuntimeDesktopTests.swift:37` 通过 | 无 | NOT_RUN |
| G0-05 | 线客户端不能要 Durable 所有权 | ADR-05、GX-21 | 无 | `RuntimeRunModelTests.swift:76` 通过；GX-21 在 A6 后通过 | A6（GX-21） | NOT_RUN |
| G0-06 | 连接异常不产生未受控输入 | ADR-03、RT-07 | 无 | `adr03_controlConnectionLossBlocksNewInputAndStopsTheRun` 通过 | 无 | NOT_RUN |
| G0-07 | unknown 不自动重放 | HB-07、RT-07 | 无 | 重启后已派发动作为 unknown（`RuntimeActTests.swift:198`）；重发计数 0 | 无 | NOT_RUN |
| G0-08 | 存储与 socket 权限 | SEC-01～SEC-05 | 无 | 新建测试副本后数据库与 socket 0600、目录 0700；另一用户读取失败；产品与副本并存 | A3（#69） | NOT_RUN |
| G0-09 | ACP 模块不建第二套执行与存储 | 代码审查 | ACP-T09-03、ACP-T18-05 | `Package.swift:36-37`：`AgentDesktopACP` 只依赖 Client、Protocol、Contracts；`grep -rl "import AgentDesktopRuntime\|SecondScreen" Sources/AgentDesktopACP` 无结果（34ae2c5 上已核对） | 无 | NOT_RUN |
| G0-10 | 旧 2ndscreen 不是运行时依赖 | A0 验收 T30 | 无 | 干净 checkout 无网络 `swift package resolve` 无 fetch；无 `Package.resolved` | 无 | NOT_RUN |
| G0-11 | 差距分析经 f1 确认 | 文档 | 无 | 04 的差距与 07、08 的 R1～R9、E-1～E-10 有 f1 的确认或更正 | f1 | NOT_RUN |
| G0-12 | 协议版本决策与互通 | A0-06 | ACP-T04-01～03 | 02 选定 v1；官方 TS SDK 客户端互通记录（02 7.1，已执行）；Zed 1.23.2 真机 `initialize` 帧（02 7.2，未取得） | 无 | NOT_RUN |
| G0-13 | 事件目录与映射对齐 | A0-08 | 无 | F1-01 冻结的类型在 08 中都有投影与夹具；E-1～E-10 有答复 | F1-01 | NOT_RUN |

## 三、G1：ACP 入站端到端执行成功

| 编号 | 检查项 | 用例 | Q 用例 | 需要的证据 | 外部依赖 | 状态 |
| --- | --- | --- | --- | --- | --- | --- |
| G1-01 | 合法请求正常处理 | T01 | ACP-T01-01～05 | T 的单元测试与 Q 的一致性测试，`swift test` 退出码 0；假编辑器对 dev 入口 | dev 入口接线（GAP-28） | NOT_RUN |
| G1-02 | 错误消息与过大帧安全拒绝 | T02 | ACP-T02-01～07 | 超限帧返回 JSON-RPC 错误，进程不退出 | 同上 | NOT_RUN |
| G1-03 | stdio 异常关闭不崩溃、不误执行 | T03 | ACP-T03-01～05 | 关 stdin：退出码记录；Runtime 侧 `owner_lost`，dispatch 0 | A6（真实部分） | NOT_RUN |
| G1-04 | 版本不兼容明确拒绝 | T04 | ACP-T04-01～05 | 发 0 时 -32600 `protocol_version_unsupported`；发 2 时回 1 | 无 | NOT_RUN |
| G1-05 | 不宣告未实现的能力 | T05 | ACP-T05-01～05 | `probeCapabilities`：宣告的能力可用，未宣告的被拒 | 无 | NOT_RUN |
| G1-06 | ACP 创建 Run，RunStore 只有一条 | T09 | ACP-T09-01～04 | `run.list` 前后只新增一条，`origin=agent_hub`、`lifetime=connection_scoped` | A6 | NOT_RUN |
| G1-07 | 能发现至少一个任务 | P1-05 | ACP-T26-02、ACP-T15-01、ACP-P1-02 | `available_commands` 内容只来自 Runtime；无 `unit.run` 时任务列表为空且有说明 | A6 或任务目录（07 R6） | NOT_RUN |
| G1-08 | 动作卡片与结果 | P1-07 | ACP-T26-03、ACP-T11-01、ACP-P1-04 | Zed 录屏与脱敏的消息日志；三级结果分开显示 | A6、Zed | NOT_RUN |
| G1-09 | 无权限任务不可执行 | T15 | ACP-T15-01～03 | 未授权身份提交被拒，dispatch 0 | A4 | NOT_RUN |
| G1-10 | 关闭编辑器后按 Run 类型处理 | T14、ADR-03、ACP-29 | ACP-T14-01～03、ACP-29-01、ACP-29-02、ACP-P1-07 | 执行中直接关闭 Zed：Run `ended`，`closingReason=owner_lost`；之后无新 GUI 输入；未确认结果保持 unknown，不记失败 | A6、Zed | NOT_RUN |
| G1-11 | Zed 真机端到端 | T26 | ACP-T26-01～03、ACP-P1-01～08 | 连续录屏、runId、请求与动作关联、结果 JSON；测试副本打开真实 GUI 输入 | A6、CLI `acp`（或 dev 入口） | NOT_RUN |

## 四、G2：Session、审批、取消、恢复可靠

| 编号 | 检查项 | 用例 | Q 用例 | 需要的证据 | 外部依赖 | 状态 |
| --- | --- | --- | --- | --- | --- | --- |
| G2-01 | 创建、列表、恢复关联正确 | T06 | ACP-T06-01～08 | 恢复后 `runIds` 与 Runtime `run.list` 一致；`session/load` 重放、`session/resume` 不重放 | 无（mock）；A4（真实身份） | NOT_RUN |
| G2-02 | 无权恢复他人会话 | T07 | ACP-T07-01～05、ACP-31-02 | 身份 B 恢复身份 A 的会话被拒 | A4 | NOT_RUN |
| G2-03 | 多会话并发不串流 | T08 | ACP-T08-01～04 | 两会话同时运行，更新只到各自会话 | A6（真实部分） | NOT_RUN |
| G2-04 | 重复提交不重复执行 | T10、CT-05 | ACP-T10-01、02、04、05、06 | 同一 prompt 重试得到同一 runId；账本只一条 | A6 | NOT_RUN |
| G2-05 | 取消停止新输入并收尾 | T12、ADR-08 | ACP-T12-01～06 | 先 `stopping`，静止后 `ended`；之后 dispatch 0 | A6 | NOT_RUN |
| G2-06 | 审批拒绝则动作不发生 | T16 | ACP-T16-01～05、ACP-T16-07、ACP-T26-04 | `reject_once` 后 dispatch 0，审计有记录 | PR4 | NOT_RUN |
| G2-07 | 审批通道不可用按拒绝 | 场景 D | ACP-P2D-01～03、ACP-T05-04 | 编辑器无权限交互时动作未执行，返回可解释的拒绝 | PR4（真实部分） | NOT_RUN |
| G2-08 | Ask / Auto 不扩权 | P2-05 | ACP-T15-04 | 无权限动作在两种模式下都被拒 | A4、PR4 | NOT_RUN |
| G2-09 | 丢回复只查询 | T10、T11 | ACP-T10-03、ACP-T09-04 | 注入回复丢失：R 只调用 `request.show` / `run.show`，账本无第二条 | 无（mock）；A6（真实） | NOT_RUN |
| G2-10 | 重连后查询先前 Run，不自动恢复 | ACP-30、ADR-04 | ACP-30-01～03 | 重开 Zed 恢复会话：读到先前 Run 的状态与结果，runId 不变；已终止的 Run 不重新执行，Runtime 无新 Run、无新动作 | A6 | NOT_RUN |
| G2-11 | 观察他人发起的 Durable Run 必须明确授权 | ACP-31 | ACP-31-01～04 | 有授权时只读观察主窗口的 Durable Run；无授权时凭会话 ID 或 Run ID 读取都返回 `not_found`；观察不取消、不控制该 Run | A4、R5、A6（主窗口 Durable） | NOT_RUN |

决定：ACP-29 放进 G1-10 与 G3-03（断连行为在 P1 就要成立，长运行回归时再验一次）；ACP-30、ACP-31 新增为 G2-10、G2-11，采纳 Q 的建议。

## 五、G3：长运行、unknown、断连和窗口一致性回归

| 编号 | 检查项 | 用例 | Q 用例 | 需要的证据 | 外部依赖 | 状态 |
| --- | --- | --- | --- | --- | --- | --- |
| G3-01 | unknown 不自动重试 | T11、ADR-10、RT-07 | ACP-T11-01～05 | 重发计数 0；显示「待核实」 | 无（act 级）；A6（unit 级） | NOT_RUN |
| G3-02 | Durable Run 只读观察（K1 改写的 T13） | T13 | ACP-T13-01～04、ACP-P2A-01、ACP-P2A-02 | 主窗口发起的 Durable Run，ACP 只读观察；关闭编辑器后 Run 继续，runId 不变；ACP 请求 Durable 被拒 | A6、U7 | NOT_RUN |
| G3-03 | Scoped Run 断连按 ADR 停止 | T14、ADR-03、ADR-04、ACP-29 | ACP-T14-01～04、ACP-P2B-01～03、ACP-29-01～03 | 断连后新输入被拒；重连不恢复旧 Run；未确认结果为 unknown | A6 | NOT_RUN |
| G3-04 | 审批期间目标变化 | T17、RT-24 | ACP-T17-01～03、ACP-P2C-01、ACP-P2C-02 | 批准后复核失败返回 `stale_observation`、`notSent`；不对错误窗口执行 | PR4（#51 已在基线） | NOT_RUN |
| G3-05 | 截图默认不外发 | T19 | ACP-T19-01～03 | 全部 ACP 出站消息与日志无图像数据；跨应用截图引用不出现 | 无（mock）；A6（真实） | NOT_RUN |
| G3-06 | 页面文字默认不外发 | T20 | ACP-T20-01、02 | 扫描无页面正文 | 同上 | NOT_RUN |
| G3-07 | 事件元数据脱敏，三级分级 | T21 | ACP-T21-01～05、ACP-T02-07 | 敏感级只显示脱敏内容；受保护级只显示状态；窗口标题、输入内容、审批参数不出现（E 的 `crossApp*` 测试） | 无 | NOT_RUN |
| G3-08 | macOS Runtime 回归 | T28、RT-23A、RT-23B | ACP-T28-01～03 | `swift test` 与 runtime 套件同一提交退出码 0 | #60 | NOT_RUN |
| G3-09 | 长运行 | P2-09 | ACP-P209-01、02 | 运行 30 分钟以上：编辑器显示或恢复后能看到最新状态 | A6、Zed | NOT_RUN |
| G3-10 | 等待审批时客户端退出 | HB-10 | ACP-T16-06 | 挂起审批失效；迟到回答零输入 | PR4 | NOT_RUN |
| G3-11 | 半开连接 | HB-11 | ACP-T03-06 | 心跳超时暂停新输入 | A4（心跳） | NOT_RUN |

## 六、G4：出站隔离与数据外发安全

G4-01～06 对应原文 T22～T25 与 P3 验收；G4-07～12 来自工作线 O 的实测（[09-outbound-isolation.md](09-outbound-isolation.md)）。O 的结论：**P3 现在不能通过**。

| 编号 | 检查项 | 用例 | Q 用例 | 需要的证据 | 外部依赖 | 状态 |
| --- | --- | --- | --- | --- | --- | --- |
| G4-01 | 只获得授权的任务工具 | T22、P3 验收 1 | ACP-T22-01 | 模型请求里的工具清单只有网关工具（Claude 用 `tools: []`；Gemini 用 `tools.exclude`；Codex 无开关，见 G4-09） | P3 实现 | NOT_RUN |
| G4-02 | 文件、终端、网络越权被阻止 | T23、P3 验收 2～4 | ACP-T23-01～03 | 在「客户端批准一切」下 E1～E7 全部 EPERM 或网络拒绝（09 2.2 层 c 已在 spike 中观察到，需在产品实现上复测） | P3 实现 | NOT_RUN |
| G4-03 | 取消后不再产生受限动作 | T24、P3 验收 7 | ACP-T24-01、02 | 取消后网关调用 0 次；补测「取消时工具正在执行」与层 c | P3 实现 | NOT_RUN |
| G4-04 | 虚假成功不标记已验证 | T25 | ACP-T25-01、02 | 外部 agent 返回 success，Runtime 验证为 contradicted 或 unknown | P3 实现、A6、E-1 | NOT_RUN |
| G4-05 | 敏感数据不发往外部模型 | P3 验收 6 | ACP-T23-04 | 发往模型的请求体逐字节扫描无 Confidential、PII canary | G4-08 | NOT_RUN |
| G4-06 | 未经许可不启动其他 MCP Server | P3 验收 5 | ACP-T22-02 | 执行体尝试改写自身 MCP 配置的受控实验；配置目录只读 | O3 测试设计（协调者确认） | NOT_RUN |
| G4-07 | OS 层隔离是唯一被依赖的边界 | 09 零.3 | 无 | 每个执行体在 `sandbox-exec`（层 c）+ 环境清理 + 临时配置目录下运行；ACP 的 `fs`/`terminal` 声明与权限拒绝不算隔离（提示词约束也不算，附加约束 4）；sandbox-exec 弃用风险有跟踪项 | P3 实现 | NOT_RUN |
| G4-08 | 数据等级闸门在我们的 MCP 网关里 | 09 第五节、P3-06 | 无 | 网关是执行体唯一数据来源；每个返回字段带等级；Confidential 与 PII 在返回 agent 之前整字段替换为引用；放行与拒绝有审计 | P3 实现 | NOT_RUN |
| G4-09 | 执行体信任分级 | 09 第六节 | 无 | Codex 只作实验性适配器，不进可信执行体名单（无关闭内置工具开关；默认不询问即执行 shell；`web_search` 在服务方）；Claude 为 P3-10 首选；Gemini 待上游补齐 | Kevin（O2） | NOT_RUN |
| G4-10 | 生产网络白名单 | P3 验收 4 | 无 | 本地出站代理只放模型 API 主机；记录非模型出站（09 第五节表） | P3 实现 | NOT_RUN |
| G4-11 | 外部 agent 失败时 Runtime 状态可靠 | P3 验收 8 | 无 | 杀掉执行体进程后 Run 有终态或 unknown，无新输入 | P3 接入 Runtime | NOT_RUN |
| G4-12 | 审计可追踪执行体身份与操作 | P3 验收 9、P3-10 | 无 | Runtime 审计含 `agentInfo`、权限决定、网关调用；真实模型只读任务一次 | P3、Kevin（O1 凭据） | NOT_RUN |

## 七、G5：分发与真实编辑器兼容

| 编号 | 检查项 | 用例 | Q 用例 | 需要的证据 | 外部依赖 | 状态 |
| --- | --- | --- | --- | --- | --- | --- |
| G5-01 | Zed 兼容 | T26 | ACP-T26-01～06 | 新装机按标准配置启动 ACP，完成一次任务 | G1 | NOT_RUN |
| G5-02 | JetBrains 兼容（P2，K2） | T27 | ACP-T27-01、02 | 同上，在一个 JetBrains IDE | JetBrains | NOT_RUN |
| G5-03 | 安装、卸载、重装 | P4 | ACP-P4-01 | 三次操作的记录；不需要历史 2ndscreen | 打包 | NOT_RUN |
| G5-04 | 版本兼容声明 | P4 | ACP-T04-03、ACP-T26-01 | 只声明 v1；每个声明有真实客户端互通记录；声明写明不连接编辑器给的 MCP 服务器（RFC 2.1） | 02、G0-12 | NOT_RUN |
| G5-05 | 权限与隐私说明 | P4 | ACP-P4-02 | 文档与实际默认值一致（截图关、页面文字关、三级分级） | 无 | NOT_RUN |

## 八、T 项与外部依赖

| 用例 | 在 mock 下可以通过 | 真实通过要等 |
| --- | --- | --- |
| T01、T02、T04、T05 | 是 | dev 入口接线（GAP-28） |
| T03 | 是（进程层面） | A6（证明不误执行） |
| T06 | 是 | A4（真实身份） |
| T07 | 否 | A4 |
| T08 | 是 | A6 |
| T09 | 否 | A6 |
| T10 | 是 | A6 |
| T11 | 是 | A6（unit 级 unknown） |
| T12 | 是 | A6 |
| T13（K1 改写） | 否 | A6、U7 |
| T14 | 是 | A6 |
| T15 | 否 | A4、任务目录或 A6 |
| T16 | 否（只能验证「不可用即拒绝」） | PR4 |
| T17 | 否 | PR4 |
| T18 | 否 | A2、#29 |
| T19、T20、T21 | 是 | A6（真实事件载荷）；E-9（截图范围） |
| T22～T25 | 否 | P3 实现，Kevin 批准 |
| T26 | 否 | A6、CLI `acp` 或 dev 入口 |
| T27 | 否 | JetBrains（P2） |
| T28 | 部分（现有 `swift test`） | #60（RT-23A/B） |
| ACP-29 | 是（假编辑器） | A6、Zed |
| ACP-30 | 是 | A6 |
| ACP-31 | 否 | A4、R5、A6 |

Windows：Runtime 与 ACP 在 Windows 的测试列入 Windows 平台门禁，不由本表的 macOS 结果代替。Windows 目前没有 Runtime 与 named pipe 端点（04 GAP-11），全部记 BLOCKED。
