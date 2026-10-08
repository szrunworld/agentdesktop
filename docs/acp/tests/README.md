# ACP 测试与验收（工作线 Q）

状态：2026-10-08 第七轮（分支 acp-q-independent，已合入 main cbe7772，含 #102、#114、#117）。170 个用例：PASSED 55、FAILED 0、BLOCKED 12、NOT_RUN 103（协调者按「未运行不得标通过」拆分两条：ACP-T18-04 → 04a 只读 PASSED、04b 写入 NOT_RUN；ACP-T28-02 → 02a 自动化 PASSED、02b 真机 NOT_RUN）。PASSED 只在 L1（假编辑器对 dev 入口、真 ACP 栈配脚本化 Runtime、代码检查）与 L2 只读（测试副本，无 unit.run、不建 Desktop）上；任何需要 A4/A6、真实 GUI 动作或真实 Zed 的用例都没有标 PASSED，**没有一条算端到端验收**。结果见 4.4～4.8 节。

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
| `docs/acp/tests/cases.csv` | 170 个可执行用例 |
| `docs/acp/tests/e2e-runbook.md` | 真机端到端手册：测试副本、Zed 配置、计算器中立样本、证据、通过标准 |
| `docs/acp/tests/evidence/fake-editor-selftest-2026-10-08/` | 假编辑器自检的原始记录 |
| `scripts/acp/fake-editor/` | 假编辑器（TypeScript，官方 `@agentclientprotocol/sdk` 1.7.0 锁定版本，`package-lock.json` 已提交，`node_modules/`、`dist/` 不提交） |
| `scripts/acp/selftest.sh` | 假编辑器自检 |
| `scripts/acp/zed-capture/` | Zed 首帧采集（Z1）：`setup.sh` 用独立 `--user-data-dir` 打开 Zed 并接上逐字节记录的包装 `capture-agent.mjs`；`collect.sh` 脱敏汇总（`--to-evidence` 仅协调者用）；`selftest.sh` 不启动 Zed，验证包装逐字节无损 |
| `scripts/acp/run-real.sh` | 对 dev 入口或 `agentdesktop acp` 跑场景（只接受 `/tmp/adt-*` 端点） |
| `scripts/acp/stale-socket.sh` | 在 `/tmp/adt-*` 下造一个无人监听的 socket 文件（ACP-T03-04） |
| `scripts/acp/scan-transcripts.py` | 扫描 transcript：agent 有没有调用 `fs/*`、`terminal/*`（ACP-T05-03） |
| `scripts/acp/mcp-readonly-probe.py` | `agentdesktop mcp` 对测试副本的只读探针（ACP-T18-04a） |
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
| T01 合法请求 | 6 | 3 | 0 | 1 | 2 | ACP-T01-01～06 |
| T02 错误消息与过大帧 | 7 | 1 | 3 | 0 | 3 | ACP-T02-01～07 |
| T03 stdio 异常关闭 | 6 | 0 | 0 | 0 | 6 | ACP-T03-01～06 |
| T04 版本不兼容 | 5 | 1 | 3 | 0 | 1 | ACP-T04-01～05 |
| T05 能力宣告 | 5 | 1 | 4 | 0 | 0 | ACP-T05-01～05 |
| T06 会话创建查询恢复 | 9 | 5 | 1 | 1 | 2 | ACP-T06-01～09 |
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
| L2 只读冒烟（真 Runtime，A6 之前） | 5 | 4 | 1 | 0 | 0 | ACP-L2-01～05 |
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
| 裁决 P1/P2（Kevin 第二次裁决，L1） | 5 | 0 | 3 | 0 | 2 | ACP-RULE-P1-01、02，ACP-RULE-P2-01～03 |
| **合计** | **168** | 57 | 64 | 10 | 37 | |

### 3.3 每个门禁的用例数

一个用例可以属于多个门禁，所以下表合计大于 170。门禁的 PASSED 数只是 L1/L2 子项，门禁本身仍未通过。

| 门禁 | 用例 | L1 | L2 | L3 | PASSED | FAILED | BLOCKED |
| --- | --- | --- | --- | --- | --- | --- | --- |
| G0 | 6 | 2 | 4 | 0 | 5 | 0 | 0 |
| G1 | 56 | 32 | 11 | 13 | 33 | 0 | 0 |
| G2 | 52 | 36 | 11 | 5 | 10 | 0 | 10 |
| G3 | 51 | 28 | 12 | 11 | 11 | 0 | 2 |
| G4 | 10 | 0 | 10 | 0 | 0 | 0 | 0 |
| G5 | 9 | 2 | 0 | 7 | 1 | 0 | 0 |

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
| `agentdesktop-dev.json` | `.build/debug/agentdesktop-acp-dev`，经 `AGENTDESKTOP_ENDPOINT` 连测试副本 | L2；端点 `/tmp/adt-acp/side.runtime.sock`；features：runtime.real、session.load/list/close |
| `agentdesktop-dev-demo.json` | dev 入口加 `--demo --state-dir <run>/state`（S 线的脚本化端口，约 1.6 s 一个演示 Run，无 Runtime、无 GUI 输入、无审批） | L1；features：session.load/list/close、task.slow |
| `agentdesktop-acp.json` | 测试副本包里的 `agentdesktop acp` | 发布形态；要等 CLI `acp` 子命令 |
| `agentdesktop-dev-unreachable.json` | dev 入口指向 `/tmp/adt-q-unreachable/stale.runtime.sock`（文件在、无人监听，先跑 `stale-socket.sh`） | L1；ACP-T03-04 |
| `agentdesktop-dev-missing.json` | dev 入口指向不存在的端点路径 | L1；ACP-T03-04（启动即拒绝） |

AgentDesktop profile 的 `features` 随依赖合入逐项打开：A6（任务入口与中立样本任务 → task.slow、提示词）、PR4（approval）、A4（identity.second）。T14 的期望文本取自 08-event-mapping：真实模式 owner_lost 显示「编辑器连接已断开」；demo 端口重启后 Run 丢失，显示「待核实」。

**场景操作**（第七轮新增：请求的 `expect.maxMs` 计时、`raw` 的 `expect.ok`、`notEchoes`、`errorMessageMatches`，`rawPartial` 写半帧，`listSessions` 的 `saveCountAs` / `countEquals`，`assert` 的 `noResponseFor`、`noAgentRequests`；特性 `protocol.strict` 表示被测方按 ACP 规范拒绝 initialize 前的请求与重复 initialize，回声 agent 与 SDK 示例不具备，记 BLOCKED）：`setConfig`（session/set_config_option）、`assert` 的 `noFrameContains`（agent 写出的任何帧都不得含某串）与 `unknownTerminal`（结果不明的工具调用从不 completed，最后为 failed + rawOutput terminated/unknown）、`rawBatch`（多帧连续写出、不等回复，只用于流水线场景）、`connect`（可选 `identity`）、`initialize`、`newSession`、`prompt`（`permission` = allow / deny / cancelled / none / hang；`cancelAfterMs`；`disconnectAfterMs`）、`promptParallel`、`listSessions`、`resume`（load 或 resume）、`closeSession`、`cancel`、`disconnect`（关 stdin 或 kill）、`expectExit`（非崩溃信号）、`expectAlive`、`raw`（任意字节，含超限帧）、`probeCapabilities`（宣告的能力必须可用、未宣告的必须被拒）、`mark` / `wait` / `assert`（标记之后没有新工具调用；标记时未完成的工具调用之后不能变成 completed）。

`permission=none` 模拟没有审批界面的编辑器：对 `session/request_permission` 回 `-32601`。`hang` 永不回答，用来做「等待审批时断开」。

### 4.2 场景与用例

| 场景文件 | 覆盖用例 | requires |
| --- | --- | --- |
| t01-valid-requests | ACP-T01-01～03 | — |
| t01b-pipelining | ACP-T01-06（专门测流水线；其余场景都等上一条回复） | — |
| t02-malformed-frames | ACP-T02-01、02、03、05 | — |
| t02b-oversize-frame | ACP-T02-04 | — |
| t02c-oversize-then-continue | ACP-T02-04（拒绝后连接仍可用） | frame.survivesOversize |
| t01c-timing | ACP-T01-04 | — |
| t01d-unknown-fields | ACP-T01-05 | protocol.strict |
| t02d-half-frame-eof | ACP-T02-06 | protocol.strict、session.list |
| t02e-error-no-echo | ACP-T02-07 | — |
| t03d-endpoint-unreachable | ACP-T03-04（端点无人监听） | runtime.unreachable |
| t03e-endpoint-missing | ACP-T03-04（端点不存在） | runtime.missing |
| t04b-init-order | ACP-T04-04、05 | protocol.strict、session.list |
| t03-stdio-close | ACP-T03-01、02 | task.slow |
| t04-version | ACP-T04-01、02 | — |
| t05-capabilities | ACP-T05-01、02 | — |
| t06-session-lifecycle | ACP-T06-01～04（07 由重连即新进程覆盖） | session.load、session.list、session.close |
| t06b-load-ordering | ACP-T06-09 | session.load |
| t07-foreign-session | ACP-T07-01～03 | session.load、session.list、identity.second |
| t08-concurrent-sessions | ACP-T08-01 | echo.marker |
| t12-cancel | ACP-T12-01～03 | task.slow |
| t14-scoped-disconnect | ACP-T14-01、02 | task.slow、session.load |
| t16-approval | ACP-T16-01～04 | approval |
| scene-b-scoped-disconnect | ACP-P2B-01、02 | approval、session.load |
| scene-d-approval-unavailable | ACP-P2D-01、02 | approval |
| l2-readonly | ACP-L2-01～05 | runtime.real |
| p1-window-title | ACP-RULE-P1-01、02 | runtime.events.windowTitle、session.load |
| p2-unknown-terminal | ACP-RULE-P2-01～03 | runtime.events.unknown、session.load |

### 4.3 自检结果（2026-10-08，已执行）

命令：`scripts/acp/selftest.sh /tmp/adt-q2-selftest`（第二轮重跑，含新增的 t01b、t06b、l2-readonly），**退出码 0**。node v22.23.2，`@agentclientprotocol/sdk` 1.7.0（ACP v1）。原始记录在 [evidence/fake-editor-selftest-2026-10-08](evidence/fake-editor-selftest-2026-10-08/)（`selftest.log`、各 `summary.json`、transcript）。

| 步骤 | 结果 |
| --- | --- |
| 回声 agent，17 个场景 | 16 PASS，1 BLOCKED（l2-readonly 需要真 Runtime），退出码 0 |
| 官方 SDK 示例 agent，14 个场景 | 9 PASS（T01、T01b、T02、T02b、T03、T04、T12、T16、场景 D），5 BLOCKED（T06、T07、T08、T14、场景 B：示例 agent 没有 session/load、列表与第二身份），退出码 0 |
| 官方 SDK 示例 agent，T05 | FAIL，符合预期：示例 agent 未宣告 `promptCapabilities.image`，却照常执行只含图片的 prompt。这说明能力探测对第三方实现有效 |
| 回声 agent 注入 11 种缺陷 | 11 种全部被对应场景判 FAIL：泄露窗口标题（P1）、结果不明显示为 completed（P2）、审批不可用当作允许（场景 D）、提供 allow_always（T16）、忽略取消（T12）、不检查会话归属（T07）、串流（T08）、宣告了图片却拒收（T05）、重连后自动继续（T14）、stdout 夹杂日志（T01）、用户输入当作 agent 文本回放（T06b） |

自检证明的是**测试工具会抓到这些缺陷**，不改变 cases.csv 的状态。

### 4.4 第二轮：对 dev 入口实测（2026-10-08，acp-skeleton 509d8ef）

被测：`swift build --product agentdesktop-acp-dev`（退出码 0）后直接运行 `.build/debug/agentdesktop-acp-dev`，不经 `swift run`。除专门的流水线场景外，所有请求都等上一条回复后再发。

**L1：`--demo`**（`profiles/agentdesktop-dev-demo.json`，17 个场景，退出码 1，证据 [evidence/l1-dev-demo-2026-10-08](evidence/l1-dev-demo-2026-10-08/)）

| 场景 | 结果 | 说明 |
| --- | --- | --- |
| t01-valid-requests | PASS | |
| t01b-pipelining | FAIL | 已知问题：initialize 回复前到达的 session/new 得到 -32600「connection not initialized」，T 线正在修 |
| t02-malformed-frames | PASS | -32700 / -32601 / -32602，之后连接可用 |
| t02b-oversize-frame | FAIL | 17 MiB 帧：先回 -32600（id null，「frame exceeds 16777216 bytes」），然后退出（退出码 0）。这是 02 第四节的设计，但与 06 G1-02「进程不退出」冲突，需要协调者裁定改哪一边 |
| t03-stdio-close | PASS | initialize 前、一轮进行中关 stdin，都干净退出 |
| t04-version | PASS | 请求 99、0 都回 1 |
| t05-capabilities | PASS | 宣告 load/list/resume/close 均可调用；图片 prompt 被拒 |
| t06-session-lifecycle | PASS | 新进程（同一 state 目录）load 成功；close 后不再列出 |
| t06b-load-ordering | FAIL | load 的回复先到，之后才有 available_commands、身份说明、Run 状态；对话文本（prompt 与回复）本身不回放。ACP v1 要求先回放后回复，交 S、T 线 |
| t07-foreign-session | BLOCKED | 无第二身份（A4） |
| t08-concurrent-sessions | BLOCKED | 无回显标记任务 |
| t12-cancel | PASS | 演示 Run 取消后 stopReason cancelled，1.5 s 内无新工具更新 |
| t14-scoped-disconnect | PASS | 断开后重连 load：demo 端口随进程丢失 Run，显示「任务 demo-run-1：状态待核实（不会自动重试）」；之后无新工具调用 |
| t16-approval、场景 B、场景 D | BLOCKED | 无审批（PR4） |
| l2-readonly | BLOCKED | 需要真 Runtime |

**L2：真 Runtime 只读**（`profiles/agentdesktop-dev.json`，退出码 1，证据 [evidence/l2-side-readonly-2026-10-08](evidence/l2-side-readonly-2026-10-08/)）

测试副本：`scripts/bundle-app.sh`（退出码 0）→ 复制到 `/tmp/adt-acp` → `open -n --env AGENTDESKTOP_SOCKET=/tmp/adt-acp/side.sock`，Runtime 端点 `/tmp/adt-acp/side.runtime.sock`，宿主 pid 68174。`runtime capabilities` 列出 33 个方法，没有 `unit.run`。dev 入口把 ACP 状态写在 `/tmp/adt-acp/acp`（目录 0700）。没有创建 Desktop，没有 GUI 输入；测试副本用文件凭据，不碰钥匙串。结束后 SIGTERM 停止测试副本，删除 `/tmp/adt-acp`。

| 场景 | 结果 | 说明 |
| --- | --- | --- |
| l2-readonly | PASS | initialize、session/new、session/list 正常；身份说明「本机所有者占位（local:501）」；自由文本得到「当前没有接受自由文本的任务，未创建任何任务」（任务目录为空，提交根本没发出，所以看到的不是 capability_missing）；/runs、/status、/cancel 正常结束；空闲取消后干净退出。之后 `run list` 与 `desktop list` 都为空 |
| t01、t02、t04、t05、t06 | PASS | 同 L1 |
| t01b、t02b、t06b | FAIL | 同 L1 的三个问题，真实模式下表现相同 |
| 其余 | BLOCKED | 缺 task.slow（A6）、审批（PR4）、第二身份（A4） |

另外：测试副本当时仍同时监听 `side.runtime.sock` 与 `side.ai.sock`（`side/listeners.txt`），所以 A2 之前 ACP-T18-01 保持 BLOCKED；A2 之后的结果见 4.7 节。


### 4.5 第三轮：#83、#85、#86 合入后复跑（2026-10-08，acp-skeleton 136eb61）

dev 入口重新构建（`swift build --product agentdesktop-acp-dev` 退出码 0）。

**L1 `--demo`**：18 个场景，退出码 0，证据 [evidence/l1-dev-demo-r3-2026-10-08](evidence/l1-dev-demo-r3-2026-10-08/)

| 场景 | 第二轮 | 第三轮 | 说明 |
| --- | --- | --- | --- |
| t01-valid-requests | PASS | PASS | |
| t01b-pipelining | FAIL | **PASS** | initialize 与 session/new 连续写出，两个都成功（#83） |
| t02-malformed-frames | PASS | PASS | |
| t02b-oversize-frame | FAIL | **PASS** | 17 MiB 帧得到 -32600，带请求 id「raw-big」，提示「skipped to the next line」（#86） |
| t02c-oversize-then-continue（新） | — | **PASS** | 超限帧之后在同一连接上 session/new 与 prompt 都正常；进程不退出 |
| t03-stdio-close | PASS | PASS | |
| t04-version | PASS | PASS | |
| t05-capabilities | PASS | PASS | |
| t06-session-lifecycle | PASS | PASS | |
| t06b-load-ordering | FAIL | **PASS** | load 回复前到 4 条更新、回复后 0 条；用户输入以 `user_message_chunk` 回放（demo 投影器把文字显示为「[已隐藏]」）；没有作为 agent 文本回放（#85、136eb61） |
| t12-cancel | PASS | PASS | |
| t14-scoped-disconnect | PASS | PASS | |
| t07、t08、t16、场景 B、场景 D、l2-readonly | BLOCKED | BLOCKED | 缺第二身份、回显任务、审批、真 Runtime |

**L2 只读**（宿主与 Runtime 源码自 509d8ef 未变，所以复用该提交构建的测试副本包；dev 入口用本轮构建）：退出码 0，证据 [evidence/l2-side-readonly-r3-2026-10-08](evidence/l2-side-readonly-r3-2026-10-08/)。l2-readonly、t01、t01b、t02、t02b、t02c、t04、t05、t06、t06b 都是 PASS，其余为 BLOCKED。真实模式下回放的用户输入是原命令 `/help`，类型为 `user_message_chunk`；跑完后 Run 列表和 Desktop 列表都为空。测试副本已用 SIGTERM 停止，`/tmp/adt-acp` 已删除。

本轮的新断言：

- t06b 断言回复前的回放里有 `user_message_chunk`，且用户输入不会原样作为 agent 文本出现。第一次判定用的是「agent 文本包含该命令」，结果误报：`/help` 的回答本身就列出了 `/help`。现在改成整句相等才算。
- 自检新增一个注入缺陷 `replay-user-as-agent`（把用户输入当作 agent 文本回放），已被 t06b 抓到。

观察（不算失败，交 S 线）：真实模式下 load 的回放里，「身份说明」出现了两次，一次来自历史，一次是加载时重新生成的。

### 4.6 第五轮：裁决 P1 / P2（2026-10-08，acp-skeleton f150e0b，含 #90、#91）

**dev 入口 `--demo` 全量复跑**：重新构建（退出码 0）后共 20 个场景，退出码 0，证据在 [evidence/l1-dev-demo-r5-2026-10-08](evidence/l1-dev-demo-r5-2026-10-08/)。

- PASS（12）：t01、t01b、t02、t02b、t02c、t03、t04、t05、t06、t06b、t12、t14。
- BLOCKED（8）：t07、t08、t16、场景 B、场景 D、l2-readonly，以及新增的 p1-window-title、p2-unknown-terminal。

两个新场景之所以 BLOCKED，是因为 demo 端口只发 `demo.progress`，配的也是演示投影器，既没有窗口标题，也没有结果不明的动作，测不到 P1、P2。dev 入口的 demo 属于 S 线的文件，本线不改。

**P1、P2 改在完整的 ACP 栈上测**：`Tests/AgentDesktopACPTests/Conformance/QTestStackRulingTests.swift`。

- 接线与 `agentdesktop-acp-dev` 完全相同：真实管道上的 `ACPStdioFileTransport`、`ACPStdioConnection`、`ACPAgentServer`、`ACPProjector`、`ACPWireV1`，以及写在磁盘上的 `ACPFileSessionStore`。
- 只有 Runtime 换成脚本化端口 `QTestScriptedPort`。断言针对编辑器收到的字节，以及服务器写下的文件。
- 设置 `QTEST_STACK_EVIDENCE=<dir>` 时保存原始输出，证据在 [evidence/l1-stack-rulings-2026-10-08](evidence/l1-stack-rulings-2026-10-08/)。

| 测试 | 用例 | 结果 |
| --- | --- | --- |
| widenedPolicyStillHidesTheBoundWindowTitle | ACP-RULE-P1-01、02 | PASS：截图设为 all、页面文字设为 on 后，人名、标题片段、应用名都不出现在实时帧、重连回放帧或会话存储的任何文件里；页面元素标签「下载简历」照常显示 |
| unknownActionEndsTerminalAndIsNeverRetried | ACP-RULE-P2-01、03 | PASS：运行期间该动作为 in_progress「结果待核实」；run.ended 时变为 `failed` + `rawOutput {execution: terminated, outcome: unknown}`，标题「输入文字 — 结果未知 · 需要核实」，始终没有出现 completed；只提交 1 次 |
| disconnectMidRunThenLoadShowsTerminalUnknownWithoutRetry | ACP-RULE-P2-02、03 | PASS：动作发出后断开（connectionLost 被调用），Runtime 以 owner_lost、unknown 结束 Run；重连 load 后回放以同样的终态结束，原因为「编辑器连接已断开」；没有重新提交 |

变异检查（[mutations.txt](evidence/l1-stack-rulings-2026-10-08/mutations.txt)，每次改完立即用 git checkout 还原）：

- 把 `ACPWireV1.terminalUnknownStatus` 改成 `.completed`：P2 两个测试都失败，被抓到。
- 让投影器的元素行改读 `windowTitle`：P1 测试失败，被抓到。
- 把窗口标题键错分类成 `pageText`：测试仍然通过。原因是这个分类器不在该字段的输出路径上，只是兜底防线。

同一套断言也写成了假编辑器场景（`p1-window-title`、`p2-unknown-terminal`，新增操作 `setConfig`，以及 `assert` 的 `noFrameContains`、`unknownTerminal`）。它们对回声 agent 都 PASS；回声 agent 新增的两个注入缺陷 `leak-title`、`unknown-as-completed` 都被抓到。等真 Runtime（A6）或带这类事件的 demo 出现后，同样的场景可以直接对 dev 入口跑。

观察（交 S 线，不算失败）：P2 实时过程最后一条轮询状态文字仍是旧措辞「结果待核实（不会自动重试）」，没有统一成裁决 P2 的「结果未知 · 需要核实」（见 p2-unknown-live.ndjson 末尾）。

### 4.7 第六轮：A2 之后的 L2 只读复跑与单一端点核对（2026-10-08，acp-skeleton f70a9f6，含 #84、#94）

宿主包（`scripts/bundle-app.sh`）和 dev 入口都由 f70a9f6 构建，退出码都是 0。测试副本放在 `/tmp/adt-acp-q6`，用 `open -n --env AGENTDESKTOP_SOCKET=…/side.sock` 启动。

- 按协调者的要求，**没有创建 Desktop 或虚拟屏，没有启动任何应用，没有 GUI 输入**。每条 CLI 查询都设了 10 秒超时，全程没有超时或卡住。
- 测试副本使用文件凭据（`side.runtime/test-credentials`），没有写钥匙串。
- 结束时 SIGTERM 停止测试副本，进程已退出，目录已删除。
- 证据在 [evidence/l2-side-readonly-post-a2-2026-10-08](evidence/l2-side-readonly-post-a2-2026-10-08/)。

**L2 只读复跑**（20 个场景，退出码 0）：

- PASS：l2-readonly、t01、t01b、t02、t02b、t02c、t04、t05、t06、t06b。
- BLOCKED：其余场景，原因不变，缺 task.slow（A6）、审批、第二身份、P1/P2 事件。
- 跑完后 `desktop list` 与 `run list` 都为空。

**单一端点（G0-01 / ACP-T18）**：

| 观察 | 结果 |
| --- | --- |
| `lsof -U -a -p <宿主 pid>`，会话前与会话后各一次 | 两次都只有一个 unix socket：`side.runtime.sock` |
| `lsof -i -a -p <宿主 pid>` | 没有网络监听 |
| 测试副本目录 | 只有 `side.runtime.sock`、它的锁文件和记录目录；没有 `side.ai.sock`，没有引擎 `side.sock` |
| 连接 `side.sock`、`side.ai.sock`、`control.sock` | 都是 ENOENT；只有 `side.runtime.sock` 能连上 |
| `runtime capabilities` | 64 个方法，`ai.*` 都在 runtime/1 上；仍然没有 `unit.run` |

用例状态变化：

- ACP-T18-01：BLOCKED → **PASSED**（L2）。
- ACP-T18-03：NOT_RUN → **PASSED**（L2）。
- ACP-T18-05：NOT_RUN → **PASSED**（代码检查：ACP 源码只引用 Client 与 Protocol，唯一命中的是一行注释）。
- ACP-T18-02 仍是 **NOT_RUN**：已观察到没有任何旧入口可连，但按用例要求编译旧引擎 CLI 并发点击属于真实 GUI 动作，本轮不做。
- ACP-T18-04（MCP 写操作进入账本）要等 #29，仍是 NOT_RUN。

**门禁变化**：

- G0-01（单一监听）的 ACP 证据已齐：T18-01、T18-03 通过。是否在 06 中标 PASSED，由 D、协调者对照 G0-01 的原文（「目录里没有 ai.sock、旧引擎 socket」）判定。
- G0-02 仍缺 T18-02 与 T18-04。
- G0-09 的代码检查部分由 T18-05 提供。
- 其余门禁没有变化，仍然没有任何端到端结论。

### 4.8 第七轮：main 基线上的剩余 L1、MCP 只读、事件目录与回归（2026-10-08，acp-q-independent，已合入 main cbe7772）

范围按 Kevin 批准：不需要 A4、A6、PR4、Zed 或真实 GUI 动作的用例。全程**没有创建 Desktop 或虚拟屏，没有启动任何应用，没有 GUI 输入，没有真实业务账号，没有写钥匙串，没有连产品端点**。L1（脚本化或无 Runtime）、L2 只读（真实测试副本）、NOT_RUN 三者分开记。

**构建与测试**（退出码直接检查，不经管道；[evidence/tests-r7-2026-10-08/summary.txt](evidence/tests-r7-2026-10-08/summary.txt)）：

| 命令 | 退出码 | 结果 |
| --- | --- | --- |
| `swift build` | 0 | |
| `swift test` | 0 | 729 个测试通过 |
| `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test` | 0 | 729 个测试通过 |
| `swift test --filter RuntimeAXIsolationTests`（RT-23A/B），普通与严格协作池各一次 | 0、0 | 6 个测试通过 |

**假编辑器新增 7 个场景**（4.2 表）。另修了假编辑器一个缺陷：以前所有场景共用第一个场景的 `RUN_DIR`（profile 的 agent 参数只替换一次），现在每个场景有自己的状态目录。

- L1 dev 入口 `--demo`，全部 27 个场景：退出码 0，PASS 17、BLOCKED 10、FAIL 0。新场景 t01c、t01d、t02d、t02e、t04b 都 PASS；[evidence/l1-dev-demo-r7-2026-10-08](evidence/l1-dev-demo-r7-2026-10-08/)。
- L1 端点不可达（不连任何 Runtime）：t03d（socket 文件在、无人监听）与 t03e（路径不存在）都 PASS，退出码 0；[evidence/l1-dev-endpoint-unreachable-r7-2026-10-08](evidence/l1-dev-endpoint-unreachable-r7-2026-10-08/)。端点无人监听时 initialize 照常，session/new 在时限内得到 -32000「Runtime 未返回已认证的调用方身份」，进程不崩溃；路径不存在时 dev 入口以退出码 2 启动即拒绝。
- L2 真 Runtime 只读（测试副本，见下）：`run-real.sh agentdesktop-dev` 退出码 0，PASS 15、BLOCKED 12、FAIL 0；新场景 t01c、t01d、t02d、t02e、t04b 都 PASS，l2-readonly 及第六轮的 PASS 场景回归仍 PASS；[evidence/l2-side-r7-2026-10-08/fake-editor](evidence/l2-side-r7-2026-10-08/fake-editor/)。
- ACP-T05-03：`scan-transcripts.py` 扫本轮 L1 的 29 份与 L2 的 27 份 transcript，agent 只发过 `session/update`，没有 `fs/*`、`terminal/*`（`t05-03-scan.json`）。

**测试副本**：`scripts/bundle-app.sh` 退出码 0（构建自 eaea64a；之后合入的 main 只改了 ACP 源码，宿主与 CLI 的源码与被测 HEAD 相同；版本号里的 `-dirty` 是构建期间改动的测试与脚本文件）。复制到 `/tmp/adt-acp`，`open -n --env AGENTDESKTOP_SOCKET=/tmp/adt-acp/side.sock` 启动；每条查询 10 秒超时，无一超时。结束时 SIGTERM，进程退出，目录已删除（`side/cleanup.txt`）。

| 观察 | 结果 | 证据（evidence/l2-side-r7-2026-10-08/） |
| --- | --- | --- |
| 单一端点（ACP-T18-01 回归） | 会话前后 `lsof -U` 都只有 `side.runtime.sock`；`lsof -i` 为空 | `side/lsof-*.txt` |
| 旧入口（ACP-T18-03 回归） | `side.sock`、`side.ai.sock`、`control.sock` 均 ENOENT；runtime capabilities 64 个方法，没有 `unit.run` | `side/connect-probe.txt`、`side/caps.json` |
| 跑完后 | `desktop list`、`run list` 为空；Runtime 状态 desktops/sessions/runs 都是 0；`<side>/acp` 下只有 `sessions/` | `side/*-after.*`、`side/acp-state-files.txt` |

**MCP（#29）只读探针，ACP-T18-04a**：`scripts/acp/mcp-readonly-probe.py`，12 项检查全部 PASS，退出码 0（`mcp/`）。

- 只调只读工具：tools/list（20 个工具）、runtime_status、desktop_list、run_show 与 request_show（都用不存在的 id）。
- 由同一个 Runtime 回答：MCP 的 runtime_status 与 CLI 直连该端点得到同一 instanceId；MCP 进程只有一个 unix socket、没有网络 socket，其对端地址就是宿主在 `side.runtime.sock` 上接受的那条连接（`mcpLsofUnix` 与 `runtimeLsofUnix`）；连接期间 Runtime 的 connections 从 1 变为 2。
- request_show 的 not_found 文字带账本保留期（7 天），说明它查的是 Runtime 账本。
- 把端点换成无人监听的路径后，每个工具都报 `runtime_offline`，没有别的入口。
- 代码检查（`mcp/code-check.txt`）：AgentDesktopMCP 只依赖 Client 与 Protocol，20 个工具各对应一个 runtime/1 方法，没有自建 socket 或引擎引用。
- **没有执行**用例原文的「act 写入账本有该 requestId」：act 会产生 GUI 输入，不在本轮范围。协调者据「未运行不得标通过」把原 ACP-T18-04 拆为 ACP-T18-04a（只读部分，PASSED）与 ACP-T18-04b（act 进账本，NOT_RUN）。

**事件目录一致性（#102 / #114）**：新增 `Conformance/QTestEventCatalogConformanceTests.swift`（9 个测试）。

- 目录直接读自内嵌的 runtime/1 契约 `PlatformRunEvent`，共 11 种类型；ACPEventType 与目录完全相等（#114 已去掉暂定类型）。
- 每种类型各造一个**先通过契约校验**的样本：每个都有具体投影（不落到「未识别」）。
- `FailureReason.message` 与回执 reason 里的人名、手机号不出现在投影里。
- action.unknown 显示「待核实」，不是 completed 也不是 failed；failed、refused 不是 completed；送达加完成只算「已执行」，不算已验证。
- action.refused 显示目录里的原因码（stale_observation）。
- run.ended 的四种 outcome 都能投影，owner_lost 显示「编辑器连接已断开」。
- 目录外的类型只显示一行中性文字，不带内容。

在 #114 合入前，本文件对 action.refused 的两处不一致记为已知问题；合入 main 后全部通过，已去掉已知问题标记。

**能力与隐私默认**：新增 `Conformance/QTestCapabilityConformanceTests.swift`（整套 ACP 栈、真实管道、脚本化 Runtime，L1）。

- ACP-T05-05：initialize 回复逐项等于实现，宣告的方法可用，未宣告的回 -32601。
- ACP-T05-04：编辑器不声明 elicitation 时，问题不发出、不被代答，Run 不前进。
- ACP-P4-02（G5-05）：新会话的截图、页面文字默认关，mode 为 ask，截图档位只有 off/submit/all，与 01、08、README 的说明一致。

**用例状态变化**（40 → 55 PASSED，116 → 103 NOT_RUN；总数 168 → 170，因拆分 ACP-T18-04 与 ACP-T28-02）：

| 用例 | 结果 | 层 |
| --- | --- | --- |
| ACP-T01-04、T01-05、T02-06、T02-07、T04-04、T04-05 | NOT_RUN → **PASSED** | L1 与 L2 只读各一次 |
| ACP-T03-04 | NOT_RUN → **PASSED** | L1（不连 Runtime） |
| ACP-T05-03 | NOT_RUN → **PASSED** | transcript 扫描（L1 + L2） |
| ACP-T05-04、T05-05、ACP-T11-01、ACP-P4-02 | NOT_RUN → **PASSED** | L1 一致性（脚本化 Runtime） |
| ACP-T09-03 | NOT_RUN → **PASSED** | 代码审查 + L2 状态目录观察 |
| ACP-T18-04a | 新拆出：**PASSED**（只读部分） | L2 只读 |
| ACP-T18-04b | 新拆出：NOT_RUN（act 进账本未执行） | — |
| ACP-T28-02a | 新拆出：**PASSED**（RT-23A/B 自动化套件 RuntimeAXIsolationTests） | L1 自动化 |
| ACP-T28-02b | 新拆出：NOT_RUN（真机：Safari 大型网页、多个 Desktop 连续 AX 超时；需建 Desktop，独立审核 B-1） | — |
| ACP-T18-01、T18-03、T28-01 | 仍 PASSED，补第七轮回归证据 | L2 / L1 |
| ACP-T04-03 | 仍 NOT_RUN：02 只选定 v1 | — |
| ACP-T18-02 | 仍 NOT_RUN：编译旧引擎 CLI 并发点击属于 GUI 动作 | — |
| ACP-T28-03 | 仍 NOT_RUN：CLI PR2 真机步骤要建 Desktop、启动计算器 | — |

**门禁（只是 ACP 用例的证据；06 由 D 与协调者判定）**：

- G1-01、G1-02、G1-05：对应用例全部 PASSED（L1/L2）。
- G1-04：只差 ACP-T04-03（版本 v2，取决于 02 的决策）。
- G0-09：ACP-T09-03、ACP-T18-05 都 PASSED。
- G5-05：ACP-P4-02 PASSED。
- G0-02：ACP-T18-03、ACP-T18-04a 已 PASSED，仍缺 ACP-T18-02 与 ACP-T18-04b。
- G3-08：仍缺 ACP-T28-03。
- 其余门禁不变，仍然没有任何端到端结论。

## 五、冻结接口一致性测试

`Tests/AgentDesktopACPTests/Conformance/QTestFrozenModelConformanceTests.swift`：9 个 suite、22 个测试，只依赖 `Model/ACPModel.swift` 与 `Ports.swift`，在 `acp-skeleton` 上单独可编译。另有 `QTestStackRulingTests.swift`（2 个 suite、3 个测试）、第七轮的 `QTestEventCatalogConformanceTests.swift`（9 个测试，#102 目录对投影器）与 `QTestCapabilityConformanceTests.swift`（3 个测试，整套栈上的能力宣告、elicitation 缺失、隐私默认值，见 4.8 节）：用整套 ACP 代码、只把 Runtime 换成脚本化端口，验证裁决 P1、P2（见 4.6 节）。它依赖各线的实现，不属于冻结接口一致性。

| suite | 钉住的不变量 |
| --- | --- |
| 审批 | 选项只有 allow_once / reject_once，`allow_always`、`reject_always` 不可构造；默认请求就是这两项；只有 `.selected(.allowOnce)` 算允许，cancelled 与 unavailable 都不算；提问 unavailable 不算回答 |
| 动作结果三级 | unknown 存在且不同于其他任一级；accepted ≠ executed ≠ verified；contradicted ≠ verified；拒绝保留错误码；工具调用默认无级别、无详情 |
| 隐私默认 | 截图 off、页面文字 false；披露级别只有 off / submit / all |
| 能力 | `ACPAgentCapabilities()` 全部为 false；`ACPClientCapabilities()` 全部为 false；版本只有 v1、v2 |
| 拼写 | 工具类型、状态、stopReason、计划状态与 ACP schema（SDK 1.7.0）一致；不存在 edit / delete / move / switch_mode 类型 |
| 提交回执 | unconfirmed 的下一步是查询，没有任何回执导向重发；duplicate ≠ accepted |
| 连接事件 | 连接丢失是独立事件；入站请求 8 种 |
| 身份 | `ACPCaller` 默认 `verified=false`（A4 前只有本机 owner 占位）；快照不自造游标 |
| 请求 id | 字符串 "7" 与数字 7 不相等、不去重 |

枚举都用不带 `default` 的 switch：任何线往冻结枚举里加 case，这个文件就编译不过，提示先找协调者并更新用例。

执行（2026-10-08，本分支合入 acp-skeleton 41fdcfe 之后）：`swift build` 与全量 `swift test` 的退出码与测试数写在 PR 正文；本线 22 个测试全部通过，其中 1 个**已知问题**。

**接口请求（转协调者）**：`ACPRequestId` 的 `==` 用 `JSONValue` 的数值比较（`1` 与 `1.0` 相等），`hash` 却用 `String(describing:)`，两者哈希不同，违反 Hashable 约定；作为字典键时同一请求可能找不到回复对象。测试 `equalNumericIdsHashEqually` 用 `withKnownIssue` 记录，修好后去掉包装即可。建议哈希改为按类型加规范化数值（或直接规定 id 只接受字符串与整数）。

## 六、门禁对照（供 06-gates 链接）

06-gates 的每一行对应以下用例。没有 ACP 用例的行（G0-03～08、G0-10、G0-11、G0-13）由 docs/plan/08 与 ADR v2.2 的用例负责。

| 06 行 | 用例 |
| --- | --- |
| G0-01 单一监听 | ACP-T18-01、ACP-T18-03（A2 后 L2 已 PASSED，见 4.7） |
| G0-02 MCP / 旧入口不绕过 | ACP-T18-02、ACP-T18-03、ACP-T18-04a、ACP-T18-04b |
| G0-09 不建第二套执行与存储 | ACP-T09-03、ACP-T18-05 |
| G0-12 协议版本互通 | ACP-T04-01、ACP-T04-02、ACP-T04-03（加 4.3 节对官方 SDK 的互通记录） |
| G1-01 | ACP-T01-01～06、ACP-L2-01～05 |
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
| G2-01 | ACP-T06-01～09 |
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
| G3-01 | ACP-T11-01～05、ACP-RULE-P2-01～03 |
| G3-02 T13（K1 改写） | ACP-T13-01～04、ACP-P2A-01、ACP-P2A-02 |
| G3-03 | ACP-T14-01～04、ACP-P2B-01～03、ACP-29-01～03 |
| G3-04 | ACP-T17-01～03、ACP-P2C-01、ACP-P2C-02 |
| G3-05 | ACP-T19-01～03 |
| G3-06 | ACP-T20-01、02 |
| G3-07 | ACP-T21-01～05、ACP-T02-07、ACP-RULE-P1-01、02 |
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

- 除 ACP-L2-01～05 的只读冒烟外，所有 L2/L3 用例都要等 A2、A4、A6（以及 PR4、#51、U7、CLI `acp`）；在此之前不记 PASSED。
- AgentDesktop profile 的 task.slow 与 `PROMPT_SLOW`、`PROMPT_ACT` 要在 A6 给出中立样本任务后填写。
- Zed 首帧采集需要 Kevin 手工做一次（runbook §三.1，约 2 分钟），协调者用 `collect.sh --to-evidence` 存证后记入 ACP-T26-01 与 02；在此之前两者都不得据模拟结果填写或标记通过（Z1）。JetBrains 未安装（P2，不阻塞 P1）。本线没有改动 Zed 的设置。
