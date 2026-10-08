# ACP 验收门禁 G0～G5

状态：2026-10-08，工作线 D。全部条目当前为 NOT_RUN。

## 一、规则

- **只认执行过的证据**：断言、`swift test` 的退出码、带记录的真机运行。编译成功不算。测试命令看退出码，不经管道截断。
- **四种状态**：PASSED、FAILED、BLOCKED（缺环境或缺外部依赖）、NOT_RUN。缺依赖记 BLOCKED，不记 PASSED。
- **真机只在测试副本**：`/tmp/adt-*`，用自己的 socket 与文件凭据，不碰产品 endpoint 与登录钥匙串。
- **同一提交**：一个门禁的全部条目在同一个提交上跑。
- **用例编号**：T01～T28 来自 [方案原文](00-input-plan-v1.0.md) 第九节，由工作线 Q 细化在 `docs/acp/tests/`；RT、CT、SEC、HB、ADR、GX、E2E 来自 [docs/plan/08](../plan/08-e2e-acceptance-plan.md) 与 [ADR v2.2](../architecture/ADR-v2.2-hub-ui-run-lifetime.md) 第五节。
- **发布含义**：G0～G3 是入站发布的必要条件；G4 是出站启用的额外条件；G5 是公开分发条件。

## 二、G0：Runtime、CLI、Hub 契约与 MCP 安全边界核对完成

| 编号 | 检查项 | 用例 | 需要的证据 | 外部依赖 | 状态 |
| --- | --- | --- | --- | --- | --- |
| G0-01 | 宿主只有一个 Runtime 监听 | RT-01 | 测试副本启动后 `lsof -U -p <pid>` 只列一个 socket；目录里没有 `ai.sock`、旧引擎 socket；按协议判定（A2 后端点名为 `control.sock`，见 04 C-19） | A2 | NOT_RUN |
| G0-02 | MCP 写操作不能绕过 Runtime | T18 | #29 的 `agentdesktop mcp` 发一次 `act`：Runtime 请求账本有该 requestId 的记录；旧 `agentdesktop-cli` 不在包内（`bundle-app.sh` 输出与 `verify-command-surface.py` 退出码 0） | A2、#29 | NOT_RUN |
| G0-03 | 所有 ai.* 经 runtime/1 | RT-02 | AI/GUI 测试经 runtime/1 重跑，`swift test` 退出码 0 | A2 | NOT_RUN |
| G0-04 | 同一请求只执行一次 | CT-05、CT-06、CT-07 | 契约套件 summary.json；现有 `RuntimeDesktopTests.swift:37` `theSameRequestIdRunsOnceAndOtherContentIsAConflict` 通过 | 无 | NOT_RUN |
| G0-05 | 线客户端不能要 Durable 所有权 | ADR-05、GX-21 | `RuntimeRunModelTests.swift:76` `adr05_aClientCannotAskForPlatformOwnership` 通过；GX-21 在 A6 后通过 | A6（GX-21 部分） | NOT_RUN |
| G0-06 | 连接异常不产生未受控输入 | ADR-03、RT-07 | `adr03_controlConnectionLossBlocksNewInputAndStopsTheRun` 通过；RT-07 的 unknown 不重发 | 无 | NOT_RUN |
| G0-07 | unknown 不自动重放 | HB-07、RT-07 | 重启后已派发动作为 unknown（`RuntimeActTests.swift:198`）；自动重发计数 0 | 无 | NOT_RUN |
| G0-08 | 存储与 socket 权限 | SEC-01～SEC-05 | 新建测试副本后各数据库与 socket 0600、目录 0700；另一用户读取失败；产品与副本并存 | A3 | NOT_RUN |
| G0-09 | ACP 模块不建第二套执行与存储 | 代码审查 | `Package.swift` 中 `AgentDesktopACP` 只依赖 Client、Protocol、Contracts；`grep -r "AgentDesktopRuntime\|SecondScreen" Sources/AgentDesktopACP` 无结果 | 无 | NOT_RUN |
| G0-10 | 旧 2ndscreen 不是运行时依赖 | A0 验收 T30 | 干净 checkout 无网络 `swift package resolve` 无 fetch；无 `Package.resolved` | 无 | NOT_RUN |
| G0-11 | 差距分析经 f1 确认 | 文档 | 04 的每条差距有 f1 的确认或更正（PR 评论链接） | f1 | NOT_RUN |
| G0-12 | 协议版本决策 | A0-06 | 02 写明所选版本，并有与官方 SDK 参考客户端互通的测试记录 | 无 | NOT_RUN |
| G0-13 | 事件目录与映射对齐 | A0-08 | F1-01 冻结的类型在 08 中都有投影与夹具 | F1-01 | NOT_RUN |

## 三、G1：ACP 入站端到端执行成功

| 编号 | 检查项 | 用例 | 需要的证据 | 外部依赖 | 状态 |
| --- | --- | --- | --- | --- | --- |
| G1-01 | 合法请求正常处理 | T01 | T 的单元测试与 Q 的一致性测试，`swift test` 退出码 0 | 无 | NOT_RUN |
| G1-02 | 错误消息与过大帧安全拒绝 | T02 | 同上；超限帧返回 JSON-RPC 错误，进程不退出 | 无 | NOT_RUN |
| G1-03 | stdio 异常关闭不崩溃、不误执行 | T03 | 假编辑器中途关 stdin：进程退出码记录；Runtime 侧 `owner_lost`，dispatch 0 | A6（真实部分） | NOT_RUN |
| G1-04 | 版本不兼容明确拒绝 | T04 | 请求未支持版本时的错误回复与退出 | 无 | NOT_RUN |
| G1-05 | 不宣告未实现的能力 | T05 | `initialize` 回复与 `ACPAgentCapabilities` 实现逐项对照 | 无 | NOT_RUN |
| G1-06 | ACP 创建 Run，RunStore 只有一条 | T09 | `run.list` 前后对比，仅新增一条，`origin=agent_hub`、`lifetime=connection_scoped` | A6 | NOT_RUN |
| G1-07 | 能发现至少一个任务 | P1-05 | `available_commands` 更新内容；来源只有 Runtime | A6 或任务目录契约 | NOT_RUN |
| G1-08 | 动作卡片与结果 | P1-07 | Zed 录屏与 ACP 消息日志（已脱敏）；三级结果分开显示 | A6、Zed | NOT_RUN |
| G1-09 | 无权限任务不可执行 | T15 | 未授权身份提交被拒，dispatch 0 | A4 | NOT_RUN |
| G1-10 | 关闭编辑器后按 Run 类型处理 | T14、ADR-03 | 关闭 Zed 后 Run `ended`，`closingReason=owner_lost` | A6 | NOT_RUN |
| G1-11 | Zed 真机端到端 | T26、E2E 计算器 | 连续录屏、runId、请求与动作关联、结果 JSON；测试副本打开真实 GUI 输入 | Zed（K2）、A6、CLI `acp` | NOT_RUN |

## 四、G2：Session、审批、取消、恢复可靠

| 编号 | 检查项 | 用例 | 需要的证据 | 外部依赖 | 状态 |
| --- | --- | --- | --- | --- | --- |
| G2-01 | 创建、列表、恢复关联正确 | T06 | S 的测试；恢复后 `runIds` 与 Runtime `run.list` 一致 | 无（mock）；A4（真实身份） | NOT_RUN |
| G2-02 | 无权恢复他人会话 | T07 | 身份 B 恢复身份 A 的会话被拒 | A4 | NOT_RUN |
| G2-03 | 多会话并发不串流 | T08 | 两会话同时运行，更新只到各自会话 | A6（真实部分） | NOT_RUN |
| G2-04 | 重复提交不重复执行 | T10、CT-05 | 同一 prompt 重试得到同一 runId；Runtime 账本只一条 | A6 | NOT_RUN |
| G2-05 | 取消停止新输入并收尾 | T12、ADR-08 | 回执先 `stopping`，静止后 `ended`；之后 dispatch 0 | A6 | NOT_RUN |
| G2-06 | 审批拒绝则动作不发生 | T16 | `reject_once` 后动作 dispatch 0，审计有记录 | PR4 审批契约 | NOT_RUN |
| G2-07 | 审批通道不可用按拒绝 | 场景 D | 编辑器不支持权限交互时，动作保持未执行，返回可解释的拒绝 | PR4 | NOT_RUN |
| G2-08 | Ask / Auto 不扩权 | P2-05 | 无权限动作在两种模式下都被拒 | A4、PR4 | NOT_RUN |
| G2-09 | 丢回复只查询 | T10、T11 | 注入回复丢失：R 只调用 `request.show`，Runtime 账本无第二条 | 无（mock）；A6（真实） | NOT_RUN |

## 五、G3：长运行、unknown、断连和窗口一致性回归

| 编号 | 检查项 | 用例 | 需要的证据 | 外部依赖 | 状态 |
| --- | --- | --- | --- | --- | --- |
| G3-01 | unknown 不自动重试 | T11、ADR-10、RT-07 | unknown 动作的重发计数 0；显示「待核实」 | 无（act 级）；A6（unit 级） | NOT_RUN |
| G3-02 | Durable Run 断连 | T13 | 按 K1 改写：主窗口发起的 Durable Run，ACP 只读观察，关闭编辑器后 Run 继续，runId 不变 | K1、A6、U7 | NOT_RUN |
| G3-03 | Scoped Run 断连按 ADR 停止 | T14、ADR-03、ADR-04 | 断连后新输入被拒；重连不恢复旧 Run | A6 | NOT_RUN |
| G3-04 | 审批期间目标变化 | T17、RT-24 | 批准后 Runtime 复核失败返回 `stale_observation`，`notSent`；不对错误窗口执行 | #51 进入基线、PR4 | NOT_RUN |
| G3-05 | 截图默认不外发 | T19 | 全部 ACP 出站消息与日志扫描无图像数据 | 无（mock）；A6（真实） | NOT_RUN |
| G3-06 | 页面文字默认不外发 | T20 | 扫描无页面正文 | 同上 | NOT_RUN |
| G3-07 | 事件元数据脱敏 | T21 | 带个人信息的标题、错误、参数夹具经投影后不含原文；日志同样 | 无 | NOT_RUN |
| G3-08 | macOS Runtime 回归 | T28、RT-23A、RT-23B | `swift test` 与 08 文件 runtime 套件在同一提交退出码 0 | AX 隔离 PR | NOT_RUN |
| G3-09 | 长运行 | P2-09 | 运行 30 分钟以上：编辑器显示或恢复后能看到最新状态；无错误生命周期 | A6、Zed | NOT_RUN |
| G3-10 | 等待审批时客户端退出 | HB-10 | 挂起审批失效；迟到回答零输入 | PR4 | NOT_RUN |
| G3-11 | 半开连接 | HB-11 | 心跳超时暂停新输入 | A4（心跳） | NOT_RUN |

## 六、G4：出站隔离与数据外发安全

| 编号 | 检查项 | 用例 | 需要的证据 | 外部依赖 | 状态 |
| --- | --- | --- | --- | --- | --- |
| G4-01 | 未授权工具被拒 | T22 | 外部 agent 调用未授权工具的记录与拒绝 | P3 实现 | NOT_RUN |
| G4-02 | 文件、终端、网络越权被阻止 | T23 | 09 的逐项实测表，每项有命令与输出 | O 的评估、P3 实现 | NOT_RUN |
| G4-03 | 取消后不再产生受限动作 | T24 | 取消后 Runtime 侧动作计数不变 | P3 实现 | NOT_RUN |
| G4-04 | 虚假成功不标记已验证 | T25 | 外部 agent 返回 success，Runtime 验证为 contradicted 或 unknown | P3 实现、A6 验证 | NOT_RUN |
| G4-05 | 敏感数据不发往外部模型 | P3 验收 6 | 出站内容抓取与分级检查 | P3 实现 | NOT_RUN |
| G4-06 | 未经许可不启动其他 MCP Server | P3 验收 5 | 进程树与配置检查 | P3 实现 | NOT_RUN |

## 七、G5：分发与真实编辑器兼容

| 编号 | 检查项 | 用例 | 需要的证据 | 外部依赖 | 状态 |
| --- | --- | --- | --- | --- | --- |
| G5-01 | Zed 兼容 | T26 | 新装机上按标准配置启动 ACP，完成一次任务 | Zed、G1 | NOT_RUN |
| G5-02 | JetBrains 兼容 | T27 | 同上，在一个 JetBrains IDE | JetBrains（K2） | NOT_RUN |
| G5-03 | 安装、卸载、重装 | P4 | 三次操作的记录；不需要历史 2ndscreen | 打包 | NOT_RUN |
| G5-04 | 版本兼容声明 | P4 | 声明的每个 ACP 版本都有真实客户端互通记录 | 02 | NOT_RUN |
| G5-05 | 权限与隐私说明 | P4 | 文档与实际默认值一致（截图关、页面文字关） | 无 | NOT_RUN |

## 八、T 项与外部依赖

| 用例 | 在 mock 下可以通过 | 真实通过要等 |
| --- | --- | --- |
| T01、T02、T04、T05 | 是 | 无 |
| T03 | 是（进程层面） | A6（证明不误执行） |
| T06 | 是 | A4（真实身份） |
| T07 | 否 | A4 |
| T08 | 是 | A6 |
| T09 | 否 | A6 |
| T10 | 是 | A6 |
| T11 | 是 | A6（unit 级 unknown） |
| T12 | 是 | A6 |
| T13 | 否 | K1；按现行 ADR 改写后还需 A6 与 U7 |
| T14 | 是 | A6 |
| T15 | 否 | A4、任务目录或 A6 |
| T16 | 否（只能验证「不可用即拒绝」） | PR4 审批契约 |
| T17 | 否 | PR4、#51 进入基线 |
| T18 | 否 | A2、#29 |
| T19、T20、T21 | 是 | A6（真实事件载荷） |
| T22～T25 | 否 | P3 实现，Kevin 批准 |
| T26 | 否 | Zed（K2）、CLI `acp`、A6 |
| T27 | 否 | JetBrains（K2）、CLI `acp`、A6 |
| T28 | 部分（现有 `swift test`） | AX 隔离 PR（RT-23A/B） |

Windows：Runtime 与 ACP 在 Windows 的测试列入 Windows 平台门禁，不由本表的 macOS 结果代替。Windows 目前没有 Runtime 与 named pipe 端点（04 GAP-11），全部记 BLOCKED。
