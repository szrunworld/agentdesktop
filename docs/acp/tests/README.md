# ACP 测试与验收（工作线 Q）

状态：2026-10-08。全部 156 个用例为 **NOT_RUN**：本轮只有假编辑器的自检与一致性测试真正执行过，它们验证的是测试工具和冻结接口，不是 AgentDesktop 的 ACP 行为。

## 一、分层（Kevin 裁决附加约束 6）

| 层 | 是什么 | 能证明什么 | 不能证明什么 |
| --- | --- | --- | --- |
| L1 一致性 | 假编辑器（`scripts/acp/fake-editor`）对 dev 入口跑场景；各线的 Swift 单元测试用假 Runtime；本线的冻结接口一致性测试 | 协议行为、拒绝路径、断连处理、审批不可用即拒绝 | 任何端到端结论 |
| L2 真 Runtime | 测试副本（`/tmp/adt-*`）上的真实 RuntimeClient，假编辑器或 shell 驱动 | Run 生命周期、去重、unknown、权限、隐私的真实表现 | 编辑器兼容 |
| L3 真编辑器 | Zed 1.23.2（P1）、JetBrains（P2），在 L2 之上 | 编辑器兼容与人眼可见的结果 | — |

规则：

- f1 的 A2、A4 与 40 的 A6 合入前，任何 L1 通过都**不算**端到端验收；对应 L2/L3 用例记 BLOCKED。
- 状态只有 PASSED、FAILED、BLOCKED、NOT_RUN（与 [06-gates](../06-gates.md) 一致）。改状态必须同时在 `evidence` 列写证据路径（假编辑器的 `summary.json` 与 transcript、录屏、`run.list` 输出等）和提交 SHA。
- 真机只用 `/tmp/adt-*` 测试副本，不碰产品 endpoint 与登录钥匙串（[e2e-runbook](e2e-runbook.md) §二）。
- `swift build`、`swift test` 只看退出码，不经管道。

## 二、文件

| 路径 | 内容 |
| --- | --- |
| `docs/acp/tests/cases.csv` | 156 个可执行用例 |
| `docs/acp/tests/e2e-runbook.md` | 真机端到端手册：测试副本、Zed 配置、计算器中立样本、证据、通过标准 |
| `docs/acp/tests/evidence/fake-editor-selftest-2026-10-08/` | 假编辑器自检的原始记录 |
| `scripts/acp/fake-editor/` | 假编辑器（TypeScript，官方 `@agentclientprotocol/sdk` 1.7.0 锁定版本，`package-lock.json` 已提交，`node_modules/`、`dist/` 不提交） |
| `scripts/acp/selftest.sh` | 假编辑器自检 |
| `scripts/acp/run-real.sh` | 对 dev 入口或 `agentdesktop acp` 跑场景（只接受 `/tmp/adt-*` 端点） |
| `Tests/AgentDesktopACPTests/Conformance/` | 冻结接口一致性测试（只用 Model 与 Ports） |

## 三、用例目录 cases.csv

列：`id, group, variant, title, preconditions, steps, expected, owner_lane, external_dependency, gate, layer, automation, status, evidence`。

- `variant`：success / refusal / timeout / fault（故障注入）。
- `owner_lane`：实现该行为的线（T、S、R、E、O、Q、D）或外部负责人（f1、40）。
- `external_dependency`：A2、A4、A6、F1-01、PR4（审批契约）、#51、#29、U7、P3、Zed、JetBrains、CLI `acp`、02 版本决策；「无（mock）；A6（真实）」表示 L1 可以先跑，真实结论要等 A6。
- `gate`：可以有多个，用分号分隔，与 06-gates 的行对应（见第六节）。
- `automation`：假编辑器场景文件、Swift 测试文件、其他线的单元测试或 runbook 的手工步骤。

### 3.1 相对原文的调整

| 原文 | 现在 | 依据 |
| --- | --- | --- |
| T13「Durable Run 断连，按授权继续」 | 「主窗口发起的 Durable Run，ACP 在授权范围内只读观察」；另加 ACP 不能把自己的 Run 变成 Durable 的拒绝用例 | K1 裁决：ACP 发起的 Run 一律 connection_scoped |
| T18「MCP 绕过尝试」 | 「A2 之后旧入口（自编译的引擎 CLI、`ai.sock`）不能驱动窗口」，只有一个监听端点，按进程判定，不按文件名 | README §二.1（#47 已停旧 control.sock；A2 后 Runtime 端点改名 control.sock，见 04 C-19） |
| P2 场景 A「从编辑器启动 Durable Run」 | ACP-P2A-01 改为主窗口发起、Zed 只读观察；ACP-P2A-02 为拒绝用例 | K1 |
| — | 新增 ACP-29（执行中关闭 Zed）、ACP-30（重连后查询先前 Run，不自动恢复）、ACP-31（观察他人 Durable Run 必须明确授权） | Kevin 裁决附加约束 7 |
| P1 通过标准 8 条 | ACP-P1-01～08，各自指向组成它的 T 用例 | 原文 §8 |
| T27 JetBrains | 保留，标为 P2，不阻塞 P1 | K2 |

### 3.2 每组用例数

| 组 | 用例 | 成功 | 拒绝 | 超时 | 故障注入 | 编号 |
| --- | --- | --- | --- | --- | --- | --- |
| T01 合法请求 | 5 | 3 | 0 | 1 | 1 | ACP-T01-01～05 |
| T02 错误消息与过大帧 | 7 | 1 | 3 | 0 | 3 | ACP-T02-01～07 |
| T03 stdio 异常关闭 | 6 | 0 | 0 | 0 | 6 | ACP-T03-01～06 |
| T04 版本不兼容 | 5 | 1 | 3 | 0 | 1 | ACP-T04-01～05 |
| T05 能力宣告 | 5 | 1 | 4 | 0 | 0 | ACP-T05-01～05 |
| T06 会话创建查询恢复 | 8 | 4 | 1 | 1 | 2 | ACP-T06-01～08 |
| T07 无权恢复他人会话 | 5 | 0 | 5 | 0 | 0 | ACP-T07-01～05 |
| T08 多会话并发 | 4 | 2 | 0 | 1 | 1 | ACP-T08-01～04 |
| T09 ACP 创建 Run | 4 | 2 | 1 | 1 | 0 | ACP-T09-01～04 |
| T10 重复提交 | 6 | 2 | 1 | 1 | 2 | ACP-T10-01～06 |
| T11 unknown 结果 | 5 | 2 | 1 | 1 | 1 | ACP-T11-01～05 |
| T12 取消 | 6 | 4 | 0 | 1 | 1 | ACP-T12-01～06 |
| T13 Durable Run 只读观察（K1 改写） | 4 | 2 | 2 | 0 | 0 | ACP-T13-01～04 |
| T14 Scoped Run 断连 | 4 | 0 | 0 | 0 | 4 | ACP-T14-01～04 |
| T15 无权限任务 | 4 | 0 | 4 | 0 | 0 | ACP-T15-01～04 |
| T16 审批 | 7 | 1 | 5 | 1 | 0 | ACP-T16-01～07 |
| T17 审批期间目标变化 | 3 | 0 | 0 | 0 | 3 | ACP-T17-01～03 |
| T18 旧入口不能驱动窗口（A2 后） | 5 | 2 | 3 | 0 | 0 | ACP-T18-01～05 |
| T19 截图不外发 | 3 | 1 | 2 | 0 | 0 | ACP-T19-01～03 |
| T20 页面文字不外发 | 2 | 1 | 1 | 0 | 0 | ACP-T20-01～02 |
| T21 事件元数据脱敏 | 5 | 0 | 5 | 0 | 0 | ACP-T21-01～05 |
| T22 未授权工具 | 2 | 0 | 2 | 0 | 0 | ACP-T22-01～02 |
| T23 文件终端网络越权 | 4 | 0 | 4 | 0 | 0 | ACP-T23-01～04 |
| T24 外部 agent 取消 | 2 | 1 | 0 | 1 | 0 | ACP-T24-01～02 |
| T25 外部 agent 虚假成功 | 2 | 0 | 2 | 0 | 0 | ACP-T25-01～02 |
| T26 Zed E2E | 6 | 4 | 1 | 0 | 1 | ACP-T26-01～06 |
| T27 JetBrains E2E（P2，不阻塞 P1） | 2 | 1 | 1 | 0 | 0 | ACP-T27-01～02 |
| T28 macOS Runtime 回归 | 3 | 3 | 0 | 0 | 0 | ACP-T28-01～03 |
| P1 通过标准（原文 §8） | 8 | 7 | 1 | 0 | 0 | ACP-P1-01～08 |
| 场景 A（K1 改写） | 2 | 1 | 1 | 0 | 0 | ACP-P2A-01～02 |
| 场景 B 委托 Run 断连 | 3 | 0 | 0 | 0 | 3 | ACP-P2B-01～03 |
| 场景 C 审批期间目标变化 | 2 | 0 | 1 | 0 | 1 | ACP-P2C-01～02 |
| 场景 D 审批通道不可用 | 3 | 0 | 3 | 0 | 0 | ACP-P2D-01～03 |
| P2-09 长运行 | 2 | 1 | 0 | 1 | 0 | ACP-P209-01～02 |
| P4 分发 | 2 | 2 | 0 | 0 | 0 | ACP-P4-01～02 |
| ACP-29 执行中关闭 Zed | 3 | 0 | 0 | 0 | 3 | ACP-29-01～03 |
| ACP-30 重连后查询先前 Run | 3 | 2 | 0 | 0 | 1 | ACP-30-01～03 |
| ACP-31 观察他人 Durable Run | 4 | 1 | 3 | 0 | 0 | ACP-31-01～04 |
| **合计** | **156** | 52 | 60 | 10 | 34 | |

### 3.3 每个门禁的用例数

一个用例可以属于多个门禁，所以下表合计大于 156。

| 门禁 | 用例 | L1 | L2 | L3 |
| --- | --- | --- | --- | --- |
| G0 | 6 | 2 | 4 | 0 |
| G1 | 50 | 31 | 6 | 13 |
| G2 | 51 | 35 | 11 | 5 |
| G3 | 46 | 23 | 12 | 11 |
| G4 | 10 | 0 | 10 | 0 |
| G5 | 9 | 2 | 0 | 7 |

## 四、假编辑器

### 4.1 用法

```sh
cd scripts/acp/fake-editor && npm ci && npx tsc -p .
node dist/fake-editor.js --profile profiles/<p>.json \
     --scenario scenarios/<s>.json [--scenario ...] --out <dir> \
     [--agent "<command> <args>"] [--env KEY=VALUE]...
```

退出码：全部 PASS 或 BLOCKED 为 0；有 FAIL 为 1；用法或场景文件错误为 2。每个场景在 `<dir>/<id>/` 下留 `transcript.jsonl`（两个方向的每一帧、stderr、退出码、断开时刻）与 `result.json`；`<dir>/summary.json` 汇总。stdout 上出现任何非 ACP 帧都判 FAIL。

**profile**（`profiles/`）决定启动什么、带哪些环境变量、具备哪些特性（`features`）以及场景里 `${VAR}` 的取值。场景声明的 `requires` 不在 `features` 里时记 BLOCKED，不会伪装成通过。

| profile | 目标 | 用途 |
| --- | --- | --- |
| `echo.json` | `src/echo-agent.ts`（本线写的最小回声 agent） | 自检；可以注入已知缺陷（`QTEST_ECHO_MUTANT`） |
| `sdk-example.json` | 官方 SDK 1.7.0 自带的示例 agent | 自检：与第三方实现互通 |
| `agentdesktop-dev.json` | `.build/debug/agentdesktop-acp-dev`（S 线的 dev 入口） | L1 真目标；端点 `/tmp/adt-acp/side.runtime.sock` |
| `agentdesktop-acp.json` | 测试副本包里的 `agentdesktop acp` | 发布形态；要等 CLI `acp` 子命令 |

两个 AgentDesktop profile 的 `features` 目前为空，提示词变量是占位：随着 A6（任务入口与中立样本任务）、PR4（审批）、A4（第二身份）合入逐项打开。

**场景操作**：`connect`（可选 `identity`）、`initialize`、`newSession`、`prompt`（`permission` = allow / deny / cancelled / none / hang；`cancelAfterMs`；`disconnectAfterMs`）、`promptParallel`、`listSessions`、`resume`（load 或 resume）、`closeSession`、`cancel`、`disconnect`（关 stdin 或 kill）、`expectExit`（非崩溃信号）、`expectAlive`、`raw`（任意字节，含超限帧）、`probeCapabilities`（宣告的能力必须可用、未宣告的必须被拒）、`mark` / `wait` / `assert`（标记之后没有新工具调用；标记时未完成的工具调用之后不能变成 completed）。

`permission=none` 模拟没有审批界面的编辑器：对 `session/request_permission` 回 `-32601`。`hang` 永不回答，用来做「等待审批时断开」。

### 4.2 场景与用例

| 场景文件 | 覆盖用例 | requires |
| --- | --- | --- |
| t01-valid-requests | ACP-T01-01～03 | — |
| t02-malformed-frames | ACP-T02-01、02、03、05 | — |
| t02b-oversize-frame | ACP-T02-04 | — |
| t03-stdio-close | ACP-T03-01、02 | task.slow |
| t04-version | ACP-T04-01、02 | — |
| t05-capabilities | ACP-T05-01、02 | — |
| t06-session-lifecycle | ACP-T06-01～04（07 由重连即新进程覆盖） | session.load、session.list、session.close |
| t07-foreign-session | ACP-T07-01～03 | session.load、session.list、identity.second |
| t08-concurrent-sessions | ACP-T08-01 | echo.marker |
| t12-cancel | ACP-T12-01～03 | task.slow |
| t14-scoped-disconnect | ACP-T14-01、02 | task.slow、session.load |
| t16-approval | ACP-T16-01～04 | approval |
| scene-b-scoped-disconnect | ACP-P2B-01、02 | approval、session.load |
| scene-d-approval-unavailable | ACP-P2D-01、02 | approval |

### 4.3 自检结果（2026-10-08，已执行）

命令：`scripts/acp/selftest.sh /tmp/adt-acp-selftest-q`，**退出码 0**。node v22.23.2，`@agentclientprotocol/sdk` 1.7.0（ACP v1）。原始记录在 [evidence/fake-editor-selftest-2026-10-08](evidence/fake-editor-selftest-2026-10-08/)（`selftest.log`、各 `summary.json`、transcript）。

| 步骤 | 结果 |
| --- | --- |
| 回声 agent，14 个场景 | 14 PASS，退出码 0 |
| 官方 SDK 示例 agent，13 个场景 | 8 PASS（T01、T02、T02b、T03、T04、T12、T16、场景 D），5 BLOCKED（T06、T07、T08、T14、场景 B：示例 agent 没有 session/load、列表与第二身份），退出码 0 |
| 官方 SDK 示例 agent，T05 | FAIL，符合预期：示例 agent 未宣告 `promptCapabilities.image`，却照常执行只含图片的 prompt。这说明能力探测对第三方实现有效 |
| 回声 agent 注入 8 种缺陷 | 8 种全部被对应场景判 FAIL：审批不可用当作允许（场景 D）、提供 allow_always（T16）、忽略取消（T12）、不检查会话归属（T07）、串流（T08）、宣告了图片却拒收（T05）、重连后自动继续（T14）、stdout 夹杂日志（T01） |

自检证明的是**测试工具会抓到这些缺陷**，不是 AgentDesktop 通过了这些用例；所以 cases.csv 的状态仍是 NOT_RUN。dev 入口目前只打印「server not implemented yet」并以 2 退出，S 线合入后用 `scripts/acp/run-real.sh agentdesktop-dev <out>` 跑。

## 五、冻结接口一致性测试

`Tests/AgentDesktopACPTests/Conformance/QTestFrozenModelConformanceTests.swift`：8 个 suite、20 个测试，只依赖 `Model/ACPModel.swift` 与 `Ports.swift`，在 `acp-skeleton` 上单独可编译。

| suite | 钉住的不变量 |
| --- | --- |
| 审批 | 选项只有 allow_once / reject_once，`allow_always`、`reject_always` 不可构造；默认请求就是这两项；只有 `.selected(.allowOnce)` 算允许，cancelled 与 unavailable 都不算；提问 unavailable 不算回答 |
| 动作结果三级 | unknown 存在且不同于其他任一级；accepted ≠ executed ≠ verified；contradicted ≠ verified；拒绝保留错误码；工具调用默认无级别、无详情 |
| 隐私默认 | 截图 off、页面文字 false；披露级别只有 off / submit / all |
| 能力 | `ACPAgentCapabilities()` 全部为 false；`ACPClientCapabilities()` 全部为 false；版本只有 v1、v2 |
| 拼写 | 工具类型、状态、stopReason、计划状态与 ACP schema（SDK 1.7.0）一致；不存在 edit / delete / move / switch_mode 类型 |
| 提交回执 | unconfirmed 的下一步是查询，没有任何回执导向重发；duplicate ≠ accepted |
| 连接事件 | 连接丢失是独立事件；入站请求 8 种 |
| 请求 id | 字符串 "7" 与数字 7 不相等、不去重 |

枚举都用不带 `default` 的 switch：任何线往冻结枚举里加 case，这个文件就编译不过，提示先找协调者并更新用例。

执行（2026-10-08，本分支合入 acp-skeleton 1d5ec34 之后）：`swift build` 退出码 0；`swift test --filter AgentDesktopACPTests` 退出码 0，23 个测试（骨架 3 + 本线 20）通过，其中 1 个**已知问题**。全量 `swift test` 的结果写在 PR 正文。

**接口请求（转协调者）**：`ACPRequestId` 的 `==` 用 `JSONValue` 的数值比较（`1` 与 `1.0` 相等），`hash` 却用 `String(describing:)`，两者哈希不同，违反 Hashable 约定；作为字典键时同一请求可能找不到回复对象。测试 `equalNumericIdsHashEqually` 用 `withKnownIssue` 记录，修好后去掉包装即可。建议哈希改为按类型加规范化数值（或直接规定 id 只接受字符串与整数）。

## 六、门禁对照（供 06-gates 链接）

06-gates 的每一行对应以下用例。没有 ACP 用例的行（G0-03～08、G0-10、G0-11、G0-13）由 docs/plan/08 与 ADR v2.2 的用例负责。

| 06 行 | 用例 |
| --- | --- |
| G0-01 单一监听 | ACP-T18-01 |
| G0-02 MCP / 旧入口不绕过 | ACP-T18-02、ACP-T18-03、ACP-T18-04 |
| G0-09 不建第二套执行与存储 | ACP-T09-03、ACP-T18-05 |
| G0-12 协议版本互通 | ACP-T04-01、ACP-T04-02、ACP-T04-03（加 4.3 节对官方 SDK 的互通记录） |
| G1-01 | ACP-T01-01～05 |
| G1-02 | ACP-T02-01～07 |
| G1-03 | ACP-T03-01～05 |
| G1-04 | ACP-T04-01～05 |
| G1-05 | ACP-T05-01～05 |
| G1-06 | ACP-T09-01～04 |
| G1-07 发现任务 | ACP-T26-02、ACP-T15-01、ACP-P1-02 |
| G1-08 动作卡片与结果 | ACP-T26-03、ACP-T11-01、ACP-P1-04 |
| G1-09 | ACP-T15-01～03 |
| G1-10 关闭编辑器 | ACP-T14-01～03、ACP-29-01、ACP-29-02、ACP-P1-07 |
| G1-11 Zed 真机 | ACP-T26-01～03、ACP-P1-01～08 |
| G2-01 | ACP-T06-01～08 |
| G2-02 | ACP-T07-01～05、ACP-31-02 |
| G2-03 | ACP-T08-01～04 |
| G2-04 | ACP-T10-01、02、04、05、06 |
| G2-05 | ACP-T12-01～06 |
| G2-06 | ACP-T16-01～05、ACP-T16-07、ACP-T26-04 |
| G2-07 场景 D | ACP-P2D-01～03、ACP-T05-04 |
| G2-08 Ask/Auto | ACP-T15-04 |
| G2-09 丢回复只查询 | ACP-T10-03、ACP-T09-04 |
| （建议 G2-10）重连查询先前 Run | ACP-30-01～03 |
| （建议 G2-11）观察他人 Durable Run 需授权 | ACP-31-01～04 |
| G3-01 | ACP-T11-01～05 |
| G3-02 T13（K1 改写） | ACP-T13-01～04、ACP-P2A-01、ACP-P2A-02 |
| G3-03 | ACP-T14-01～04、ACP-P2B-01～03、ACP-29-01～03 |
| G3-04 | ACP-T17-01～03、ACP-P2C-01、ACP-P2C-02 |
| G3-05 | ACP-T19-01～03 |
| G3-06 | ACP-T20-01、02 |
| G3-07 | ACP-T21-01～05、ACP-T02-07 |
| G3-08 | ACP-T28-01～03 |
| G3-09 长运行 | ACP-P209-01、ACP-P209-02 |
| G3-10 | ACP-T16-06 |
| G3-11 半开连接 | ACP-T03-06 |
| G4-01 | ACP-T22-01 |
| G4-02 | ACP-T23-01～03 |
| G4-03 | ACP-T24-01、02 |
| G4-04 | ACP-T25-01、02 |
| G4-05 | ACP-T23-04 |
| G4-06 | ACP-T22-02 |
| G5-01 | ACP-T26-01～06 |
| G5-02 | ACP-T27-01、02 |
| G5-03 | ACP-P4-01 |
| G5-04 | ACP-T04-03、ACP-T26-01 |
| G5-05 | ACP-P4-02 |

ACP-29、ACP-30、ACP-31 是 Kevin 新增的端到端场景，06-gates 里还没有对应行；上表建议放在 G1-10 / G3-03（ACP-29）和新行 G2-10、G2-11（ACP-30、ACP-31），由工作线 D 决定。

## 七、未完成与依赖

- 所有 L2/L3 用例等 A2、A4、A6（以及 PR4、#51、U7、CLI `acp`）；在此之前记 BLOCKED，不记 PASSED。
- AgentDesktop profile 的 `features` 和提示词变量要在 A6 给出中立样本任务后填写；`SCOPED_ENDED_TEXT`、`REFUSAL_EXPLAINED_RE` 等措辞等工作线 E 的映射定稿。
- JetBrains 未安装（P2，不阻塞 P1）。Zed 1.23.2 已装，配置步骤见 runbook §三，本线没有改动 Zed 的设置。
