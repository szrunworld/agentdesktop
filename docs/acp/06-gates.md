# ACP 验收门禁 G0～G5

状态：2026-10-08 第三轮，工作线 D。基线：AgentDesktop `main`（README 第八节，唯一集成基线）；本文核对的分支是 `acp-skeleton`@8f57c1d（已合入 main@134b451，即 #2；尚未合入 main 上更新的 fa2222f #102）。用例状态取自 Q 的 [tests/cases.csv](tests/cases.csv)（168 个：PASSED 40、FAILED 0、BLOCKED 12、NOT_RUN 116）。

## 〇、摘要

| 门禁 | 行数 | PASSED | NOT_RUN | BLOCKED | 最大的单一阻塞 |
| --- | --- | --- | --- | --- | --- |
| G0 | 13 | 5 | 3 | 5 | #29 未合入（T18-04）加真实 GUI 动作（T18-02），G0-02 因此不能通过 |
| G1 | 11 | 0 | 4 | 7 | 40 的 A6 `unit.run`：没有它，ACP 不能创建任何 Run |
| G2 | 11 | 0 | 0 | 11 | A4 身份与 PR4 审批（G2-02、06、07、08、11），A6 其次 |
| G3 | 14 | 0 | 1 | 13 | A6（真实事件与真实断连）；审批类等 PR4 |
| G4 | 12 | 0 | 0 | 12 | P3 实现（MCP 网关数据闸门、OS 层隔离）；真实模型凭据（O1） |
| G5 | 5 | 0 | 1 | 4 | Zed 手工首帧（Z1）与 G1 |
| 合计 | 66 | 5 | 9 | 52 | |

读法：

- **PASSED**：行内写明的证据全部具备，且证据路径与提交可查。
- **NOT_RUN**：现在就能跑，但还没跑；「缺什么」一栏写明。
- **BLOCKED（X）**：至少一项必需证据要等 X。X 只取以下几类：f1 契约增量（principal、`Run.lastEventSequence`、事件目录对齐）、A4、A6 `unit.run`、PR4 inbox、#29、Zed 手工 Z1、真实 GUI 动作、P3、环境。
- **L1 通过不算端到端**（附加约束 6）。一行即使所有 L1 用例都通过，只要还需要 L2 或 L3 证据，就不是 PASSED。

## 一、规则

- **只认执行过的证据**：断言、`swift test` 的退出码、带记录的真机运行。编译成功不算。测试命令看退出码，不经管道截断。
- **严格线程池回归**（README 第八节）：CI 恢复严格池一步之前，ACP 每次合入前须在本机执行 `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test --filter AgentDesktopACPTests` 与全包 `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test`，并在 PR 正文记录退出码（G3-12）。
- **三层证据**（Q 的 [tests/README](tests/README.md) 第一节）：L1 一致性、L2 真 Runtime（测试副本）、L3 真编辑器。
- **真机只在测试副本**：`/tmp/adt-*`，自己的 socket 与文件凭据，不碰产品 endpoint、登录钥匙串与其他会话的 WindowServer 环境。
- **同一提交**：门禁整体通过时，全部条目要在同一个提交上复跑。本文的 PASSED 是逐行结论，各自注明提交。
- **用例编号**：T01～T28 来自 [方案原文](00-input-plan-v1.0.md) 第九节；ACP-29～31 来自附加约束 7；ACP-RULE-P1/P2 来自第二次裁决 P1、P2；RT、CT、SEC、HB、ADR、GX 来自 [docs/plan/08](../plan/08-e2e-acceptance-plan.md) 与 ADR v2.2 第五节。「Q 用例」列取自 tests/README 第六节，括号里是「已通过 / 总数」。
- **发布含义**（K3 与第二次裁决）：ACP v1 暂不宣布完成、暂不批准发布。G3 完成后评估是否进首版候选；正式发布须 G4、G5 与 Runtime 集成验收全部通过。

## 二、G0：Runtime、CLI、Hub 契约与 MCP 安全边界核对完成

| 编号 | 检查项 | 用例 | Q 用例 | 证据与路径 | 状态 | 缺什么 |
| --- | --- | --- | --- | --- | --- | --- |
| G0-01 | 宿主只有一个 Runtime 监听 | RT-01 | ACP-T18-01（1/1） | 测试副本 `/tmp/adt-acp-q6`，`acp-skeleton`@f70a9f6（含 A2 #84、#94）：`lsof -U -p <宿主 pid>` 会话前后都只有 `side.runtime.sock`，`lsof -i` 无网络监听；`side.sock`、`side.ai.sock`、`control.sock` 连接均 ENOENT；该 socket 握手并列出 64 个 runtime/1 方法（按握手判定，f1 已接受 C-19）。路径：`docs/acp/tests/evidence/l2-side-readonly-post-a2-2026-10-08/side/lsof-unix.txt`、`lsof-unix-after.txt`、`lsof-inet.txt`、`connect-probe.txt`、`caps.json`。另有 f1 的 `docs/acceptance/foundation-final-2026-10-08.md`（f0f3827，「只监听一个 socket」） | **PASSED** | 无。整门禁通过时在门禁提交上复跑一次 |
| G0-02 | MCP 与旧入口不能绕过 Runtime | T18 | ACP-T18-02、03、04（1/3） | T18-03 已通过：`ai.sock` 不存在，`ai.*` 都在 runtime/1 上（同上目录 `connect-probe.txt`、`caps.json`） | **BLOCKED（#29；真实 GUI 动作）** | T18-04：`agentdesktop mcp` 发一次 `act` 并在账本查到 requestId，等 #29（仍为草案，并入 #111 待审）。T18-02：按用例要求从 `engine/` 编译旧 CLI（`engine/Package.swift:8` 仍声明 `agentdesktop-cli`）对测试副本发点击，属于真实 GUI 动作，本轮未做；现有证据只说明没有可连的旧 socket |
| G0-03 | 所有 ai.* 经 runtime/1 | RT-02 | ACP-T18-03（1/1） | `docs/acceptance/single-endpoint-pr2b-1-2026-10-08.md`（`swift test` 455 项，退出码 0，SingleEndpointTests）；`single-endpoint-pr2b-2-2026-10-08.md`（466 项，退出码 0，ai/1 信封删除）；`foundation-final-2026-10-08.md`（二进制中 `agentdesktop.ai/1` 为 0 处） | **PASSED** | 无。`gui.runs.*` 仍是过渡方法，A6 删除（见 04 GAP-03） |
| G0-04 | 同一请求只执行一次 | CT-05、CT-06、CT-07 | 无 | `RuntimeDesktopTests.swift:36` `theSameRequestIdRunsOnceAndOtherContentIsAConflict` 在 foundation-final 的全量 `swift test`（f0f3827，470 项，退出码 0）里通过 | NOT_RUN | 行内要求的契约套件 summary.json 不存在：仓库没有 `scripts/verify`（docs/plan/08 8.2）；CT-07（10 个并发相同 requestId 的 run.start）没有找到对应测试 |
| G0-05 | 线客户端不能要 Durable 所有权 | ADR-05、GX-21 | 无 | `RuntimeRunModelTests.swift:75` `adr05_aClientCannotAskForPlatformOwnership` 在 foundation-final 的 `swift test` 里通过 | **BLOCKED（A6）** | GX-21（`unit.run` 在不同主体下的所有权）要等 A6 |
| G0-06 | 连接异常不产生未受控输入 | ADR-03、RT-07 | 无 | `RuntimeRunModelTests.swift:35` `adr03_controlConnectionLossBlocksNewInputAndStopsTheRun` 在 foundation-final（f0f3827）与 Q 的 ACP-T28-01（f70a9f6，全量 `swift test` 与严格池各一次，退出码 0）里都通过 | **PASSED** | 无 |
| G0-07 | unknown 不自动重放 | HB-07、RT-07 | 无 | `RuntimeActTests.swift:197` `afterARestartUndispatchedActsFailAndDispatchedOnesAreUnknown`，同上两次全量运行 | **PASSED** | 无 |
| G0-08 | 存储与 socket 权限 | SEC-01～SEC-05 | 无 | SEC-01：#69 与 `docs/acceptance/sec-01-2026-10-08.md`；SEC-03 部分：测试副本用文件凭据 | **BLOCKED（环境）** | SEC-02 未验证；SEC-04 需要第二个本机用户账号（本机没有）；SEC-05 需要同时运行产品实例（按规则不碰产品） |
| G0-09 | ACP 模块不建第二套执行与存储 | 代码审查 | ACP-T09-03、ACP-T18-05（1/2） | T18-05（f70a9f6）：`grep -rn "AgentDesktopRuntime\|SecondScreen" Sources/AgentDesktopACP` 只有一处注释；`AgentDesktopACP` 只依赖 Client 与 Protocol（Contracts 已并入 Protocol，#94） | NOT_RUN | ACP-T09-03（L1，无外部依赖）：一次 ACP 会话前后 `run.list` 对比，没有 ACP 自己的运行记录。可在测试副本上只读执行 |
| G0-10 | 旧 2ndscreen 不是运行时依赖 | A0 验收 T30 | 无 | `foundation-final-2026-10-08.md`：干净检出 `swift package resolve` 退出码 0，`.build/checkouts` 为空，无 Package.resolved，无网络下载 | **PASSED** | 无 |
| G0-11 | 差距与契约需求经 f1 确认 | 文档 | 无 | f1 对 07 的 R1～R11 与 C-19、对 08 的 E-1～E-10 已有书面结论（07、08 第〇节） | NOT_RUN | 04 本身没有 f1 的确认；#102 的落地形状与 f1 在 08 第〇节的结论有两处不同（见 04 GAP-08 备注），需要 f1 说明以哪个为准 |
| G0-12 | 协议版本决策与互通 | A0-06 | ACP-T04-01、02、03（2/3） | 02 选定 v1；官方 TS SDK 1.7.0 客户端互通（02 7.1）；T04-01、02 在 dev 入口通过（`docs/acp/tests/evidence/l1-dev-demo-2026-10-08/`） | **BLOCKED（Zed 手工 Z1）** | Zed 1.23.2 真实 `initialize` 请求与响应（e2e-runbook §三.1，`scripts/acp/zed-capture/`）；Z1 规定取得真实帧前不得标记通过。T04-03 测的是「第二个版本」，02 决定只支持 v1，该用例不适用 |
| G0-13 | 事件目录与映射对齐 | A0-08 | 无 | 事件目录已由 #102 冻结在 main（fa2222f，`runtime.schema.json#/$defs/PlatformRunEvent`，10 种事件，`action.refused`） | **BLOCKED（f1 契约增量）** | `acp-skeleton` 尚未合入 fa2222f；E 按目录对齐与夹具；目录里的分级字段（E-10）与 principal、`Run.lastEventSequence` 两项增量尚未在 main 上（`grep` 两者在 main 的 schema 中均为 0 处） |

## 三、G1：ACP 入站端到端执行成功

| 编号 | 检查项 | 用例 | Q 用例 | 证据与路径 | 状态 | 缺什么 |
| --- | --- | --- | --- | --- | --- | --- |
| G1-01 | 合法请求正常处理 | T01 | ACP-T01-01～06、ACP-L2-01～05（9/11） | L1：`docs/acp/tests/evidence/l1-dev-demo-2026-10-08/`、`l1-dev-demo-r3-2026-10-08/`；L2 只读：`l2-side-readonly-2026-10-08/`、`l2-side-readonly-post-a2-2026-10-08/` | NOT_RUN | ACP-T01-04、05（L1，无外部依赖）未跑 |
| G1-02 | 错误与过大帧安全拒绝 | T02 | ACP-T02-01～07（5/7） | 同上 L1 目录 | NOT_RUN | ACP-T02-06、07 未跑。按协调者决定（README 第六节）：超长帧回错误、丢弃、从下一个换行继续读，进程不退出，连接不断开 |
| G1-03 | stdio 异常关闭不崩溃、不误执行 | T03 | ACP-T03-01～05（2/5） | T03-01、02 仅 L1（`--demo` 脚本化端口） | **BLOCKED（A6）** | T03-05 要在真实 Run 上证明 dispatch 0；T03-03、04 可先跑 |
| G1-04 | 版本不兼容明确拒绝 | T04 | ACP-T04-01～05（2/5） | L1 目录同上 | NOT_RUN | T04-04、05 未跑；T04-03 不适用（只支持 v1） |
| G1-05 | 不宣告未实现的能力 | T05 | ACP-T05-01～05（2/5） | L1 目录同上 | NOT_RUN | T05-03、04、05 未跑 |
| G1-06 | ACP 创建 Run，RunStore 只有一条 | T09 | ACP-T09-01～04（0/4） | 无 | **BLOCKED（A6 `unit.run`）** | 没有 `unit.run`，ACP 不能创建 Run |
| G1-07 | 能发现至少一个任务 | P1-05 | ACP-T26-02、ACP-T15-01、ACP-P1-02（0/3） | f1 不接受任务目录（07 R6）：任务只来自「方法宣告」 | **BLOCKED（A6 `unit.run`）** | Runtime 宣告 `unit.run` 之前，R 的任务列表为空 |
| G1-08 | 动作卡片与结果 | P1-07 | ACP-T26-03、ACP-T11-01、ACP-P1-04（0/3） | 无 | **BLOCKED（A6；Zed 手工 Z1；f1 契约增量）** | 真实动作事件、Zed 录屏；T11-01 等事件目录对齐 |
| G1-09 | 无权限任务不可执行 | T15 | ACP-T15-01～03（0/3） | 无 | **BLOCKED（A4；A6）** | 第二身份与授权；T15-03 可先在 L1 跑 |
| G1-10 | 关闭编辑器后按 Run 类型处理 | T14、ADR-03、ACP-29 | ACP-T14-01～03、ACP-29-01、02、ACP-P1-07（2/6） | T14-01、02 仅 L1 | **BLOCKED（A6；Zed 手工 Z1）** | 执行中直接关闭 Zed 的真实记录：Run `ended`、`owner_lost`、无新 GUI 输入、未确认结果为 unknown |
| G1-11 | Zed 真机端到端 | T26 | ACP-T26-01～03、ACP-P1-01～08（0/11） | 无 | **BLOCKED（A6；Zed 手工 Z1；真实 GUI 动作）** | 最小真实链路 Zed → ACP → Runtime → GUI → 事件 → Zed（05 第三节）。CLI 子命令要等 G1（f1 R9），在此之前用 dev 入口 |

## 四、G2：Session、审批、取消、恢复可靠

| 编号 | 检查项 | 用例 | Q 用例 | 证据与路径 | 状态 | 缺什么 |
| --- | --- | --- | --- | --- | --- | --- |
| G2-01 | 创建、列表、恢复关联正确 | T06 | ACP-T06-01～09（6/9） | L1 目录同上 | **BLOCKED（A4；A6）** | T06-05 要真实身份与真实 Run；T06-06、08 可先跑 |
| G2-02 | 无权恢复他人会话 | T07 | ACP-T07-01～05、ACP-31-02（0/6；3 个 BLOCKED） | 无 | **BLOCKED（A4）** | 第二身份 |
| G2-03 | 多会话并发不串流 | T08 | ACP-T08-01～04（0/4；1 个 BLOCKED） | 无 | **BLOCKED（A6）** | dev 入口没有带回显标记的任务；真实部分要 A6 |
| G2-04 | 重复提交不重复执行 | T10、CT-05 | ACP-T10-01、02、04、05、06（0/5） | 无 | **BLOCKED（A6）** | 真实提交；T10-02、04、06 可先在 L1 跑 |
| G2-05 | 取消停止新输入并收尾 | T12、ADR-08 | ACP-T12-01～06（3/6） | T12-01～03 仅 L1 | **BLOCKED（A6）** | T12-04 真实取消；T12-05、06 可先跑 |
| G2-06 | 审批拒绝则动作不发生 | T16 | ACP-T16-01～05、07、ACP-T26-04（0/7；4 个 BLOCKED） | 无 | **BLOCKED（PR4 inbox）** | Runtime 没有审批来源，dev 入口从不发 `request_permission` |
| G2-07 | 审批通道不可用按拒绝 | 场景 D | ACP-P2D-01～03、ACP-T05-04（0/4；2 个 BLOCKED） | S 的单元测试覆盖「不可用即拒绝」（L1） | **BLOCKED（PR4 inbox）** | 同上 |
| G2-08 | Ask / Auto 不扩权 | P2-05 | ACP-T15-04（0/1） | 无 | **BLOCKED（A4；PR4 inbox）** | 授权与审批都要真实 |
| G2-09 | 丢回复只查询 | T10、T11 | ACP-T10-03、ACP-T09-04（0/2） | 无 | **BLOCKED（A6）** | 真实账本；L1 部分可先跑。重发规则改按 f1 的 R7：仅当提交晚于 `oldestAcceptedAt` 且 `instanceId` 一致时可重发一次 |
| G2-10 | 重连后查询先前 Run，不自动恢复 | ACP-30、ADR-04 | ACP-30-01～03（0/3） | 无 | **BLOCKED（A6；A4；Zed 手工 Z1）** | 真实 Run 与重开 Zed |
| G2-11 | 观察他人 Durable Run 必须明确授权 | ACP-31 | ACP-31-01～04（0/4） | 无 | **BLOCKED（A4；f1 契约增量 R5；A6；U7）** | A4 前本机连接都是 owner，无法证明越权被拒 |

## 五、G3：长运行、unknown、断连、窗口一致性与回归

| 编号 | 检查项 | 用例 | Q 用例 | 证据与路径 | 状态 | 缺什么 |
| --- | --- | --- | --- | --- | --- | --- |
| G3-01 | unknown 不自动重试 | T11、ADR-10、RT-07 | ACP-T11-01～05、ACP-RULE-P2-01～03（3/8） | RULE-P2 仅 L1（`docs/acp/tests/evidence/l1-stack-rulings-2026-10-08/`） | **BLOCKED（A6；f1 契约增量）** | T11-02、03 真实 unknown；T11-01 等目录对齐；T11-04、05 可先跑 |
| G3-02 | Durable Run 只读观察（K1 改写的 T13） | T13 | ACP-T13-01～04、ACP-P2A-01、02（0/6） | 无 | **BLOCKED（A4；A6；U7）** | 主窗口发起的 Durable Run |
| G3-03 | Scoped Run 断连按 ADR 停止 | T14、ADR-03、ADR-04、ACP-29 | ACP-T14-01～04、ACP-P2B-01～03、ACP-29-01～03（2/10；2 个 BLOCKED） | T14-01、02 仅 L1 | **BLOCKED（A6；PR4 inbox；Zed 手工 Z1）** | 真实断连与执行中关闭 Zed |
| G3-04 | 审批期间目标变化 | T17、RT-24 | ACP-T17-01～03、ACP-P2C-01、02（0/5） | #51 已在 main | **BLOCKED（PR4 inbox）** | 审批来源 |
| G3-05 | 截图默认不外发 | T19 | ACP-T19-01～03（0/3） | 无 | **BLOCKED（A6）** | 真实事件载荷；T19-01、02 的 L1 部分可先跑 |
| G3-06 | 页面文字默认不外发 | T20 | ACP-T20-01、02（0/2） | 无 | **BLOCKED（A6）** | 同上 |
| G3-07 | 事件元数据脱敏，三级分级 | T21 | ACP-T21-01～05、ACP-T02-07、ACP-RULE-P1-01、02（2/8） | RULE-P1 仅 L1 | **BLOCKED（PR4 inbox，仅 T21-03）** | T21-03 审批参数；T21-01、02、04、05 与 T02-07 无外部依赖，可先跑 |
| G3-08 | macOS Runtime 回归 | T28、RT-23A、RT-23B | ACP-T28-01～03（1/3） | T28-01：f70a9f6 全量 `swift test` 与严格池各一次，退出码 0；AX 隔离 #60 已合入（`docs/acceptance/ax-isolation-2026-10-08.md`） | NOT_RUN | T28-02（RT-23A/B 套件）与 T28-03（已有 CLI 验收不回归）的依赖已满足，未在 ACP 分支上跑 |
| G3-09 | 长运行 | P2-09 | ACP-P209-01、02（0/2） | 无 | **BLOCKED（A6；Zed 手工 Z1）** | 30 分钟以上的真实 Run |
| G3-10 | 等待审批时客户端退出 | HB-10 | ACP-T16-06（0/1） | 无 | **BLOCKED（PR4 inbox）** | 审批来源 |
| G3-11 | 半开连接 | HB-11 | ACP-T03-06（0/1） | 无 | **BLOCKED（A4；A6）** | Runtime 心跳 |
| G3-12 | 严格线程池下无同步阻塞 | README 第八节 | ACP-T28-01（严格池部分） | 本机：f70a9f6 上 `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test` 退出码 0（Q 第六轮 PR 正文）；README 第八节记录本机全包 685/685 约 20 秒通过。CI：run 37763484340 严格一步 5 分钟超时，#109 删掉该步 | **BLOCKED（环境：CI runner）** | CI 恢复严格池一步并在 GitHub 上通过。在此之前每次 ACP 合入前本机记录两条命令的退出码；`ACPBridgeExecutor` 的闸门测试不得删除或放宽 |
| G3-13 | 窗口标题与身份信息不进入 ACP 事件流（第二次裁决 P1） | P1 | ACP-RULE-P1-01、02（2/2，仅 L1） | `docs/acp/tests/evidence/l1-stack-rulings-2026-10-08/p1-live.ndjson`、`p1-replay.ndjson`、`swift-test.txt`、`mutations.txt`（投影泄露变异被抓到） | **BLOCKED（A6）** | L1 已通过；真实事件里的窗口标题要等 A6 |
| G3-14 | 结果不明的动作为明确终态（第二次裁决 P2） | P2 | ACP-RULE-P2-01～03（3/3，仅 L1） | 同目录 `p2-unknown-live.ndjson`、`p2-disconnect-live.ndjson`、`p2-disconnect-replay.ndjson`、`swift-test.txt`、`mutations.txt`（completed 变异被抓到） | **BLOCKED（A6）** | L1 已通过：v1 线上为 `failed`，标题「结果未知 · 需要核实」，`rawOutput {execution: terminated, outcome: unknown}`，从不重发；真实 unknown 要等 A6 |

## 六、G4：出站隔离与数据外发安全

G4 只在 O 的 spike 上有实测（[09-outbound-isolation.md](09-outbound-isolation.md)，本地脚本化模型，真实模型调用 0 次），产品实现没有开始。第二次裁决：O1 用独立测试凭据；O2 接受 Codex 为 Experimental；O3 允许在隔离环境做「修改自身 MCP 配置」实验，不进产品。

| 编号 | 检查项 | 用例 | Q 用例 | 证据与路径 | 状态 | 缺什么 |
| --- | --- | --- | --- | --- | --- | --- |
| G4-01 | 只获得授权的任务工具 | T22、P3-1 | ACP-T22-01（0/1） | spike：`spikes/acp-outbound/runs/*-toolsoff` | **BLOCKED（P3）** | 产品实现 |
| G4-02 | 文件、终端、网络越权被阻止 | T23、P3-2～4 | ACP-T23-01～03（0/3） | spike：`runs/*-c-allowall` | **BLOCKED（P3）** | 产品实现上复测 |
| G4-03 | 取消后不再产生受限动作 | T24、P3-7 | ACP-T24-01、02（0/2） | spike：`runs/*-b-cancel`（一种时序） | **BLOCKED（P3）** | 「取消时工具正在执行」与层 c |
| G4-04 | 虚假成功不标记已验证 | T25 | ACP-T25-01、02（0/2） | 无 | **BLOCKED（P3；A6）** | 接入 Runtime 验证 |
| G4-05 | 敏感数据不发往外部模型 | P3-6 | ACP-T23-04（0/1） | spike：三家都外发了 PII（09 第五节） | **BLOCKED（P3）** | 依赖 G4-08 |
| G4-06 | 未经许可不启动其他 MCP Server | P3-5 | ACP-T22-02（0/1） | 无 | **BLOCKED（P3）** | O3 已批准的隔离实验 |
| G4-07 | OS 层隔离是唯一被依赖的边界 | 09 零.3 | 无 | spike：层 c 在 allow-all 下挡住三家 | **BLOCKED（P3）** | 产品实现；sandbox-exec 弃用风险跟踪 |
| G4-08 | 数据等级闸门在我们的 MCP 网关里 | 09 第五节、P3-06 | 无 | 无 | **BLOCKED（P3）** | 网关实现 |
| G4-09 | 执行体信任分级 | 09 第六节、O2 | 无 | 第二次裁决 O2：Codex 为 Experimental | **BLOCKED（P3）** | 正式支持等真实模型端到端验收 |
| G4-10 | 生产网络白名单 | P3-4 | 无 | spike：`runs/net-allowlist-demo` | **BLOCKED（P3）** | 本地出站代理 |
| G4-11 | 外部 agent 失败时 Runtime 状态可靠 | P3-8 | 无 | 无 | **BLOCKED（P3；A6）** | 接入 Runtime |
| G4-12 | 审计可追踪执行体身份与操作 | P3-9、P3-10 | 无 | 无 | **BLOCKED（P3；O1 凭据）** | 真实模型只读任务一次 |

## 七、G5：分发与真实编辑器兼容

| 编号 | 检查项 | 用例 | Q 用例 | 证据与路径 | 状态 | 缺什么 |
| --- | --- | --- | --- | --- | --- | --- |
| G5-01 | Zed 兼容 | T26 | ACP-T26-01～06（0/6） | 无 | **BLOCKED（Zed 手工 Z1；A6）** | 先 Z1 首帧，再 G1 |
| G5-02 | JetBrains 兼容（P2） | T27 | ACP-T27-01、02（0/2） | 无 | **BLOCKED（环境：JetBrains 未安装，K2 延后到 P2）** | |
| G5-03 | 安装、卸载、重装 | P4 | ACP-P4-01（0/1） | 无 | **BLOCKED（G1；CLI `acp`）** | f1 R9：过 G1 且 #53 离开草案后才接进 CLI |
| G5-04 | 版本兼容声明 | P4 | ACP-T04-03、ACP-T26-01（0/2） | 02 只声明 v1；RFC 2.1 写明不连接编辑器给的 MCP 服务器 | **BLOCKED（Zed 手工 Z1）** | T26-01 的真实帧；T04-03 不适用 |
| G5-05 | 权限与隐私说明 | P4 | ACP-P4-02（0/1） | 无 | NOT_RUN | 文档与默认值对照（L1，无外部依赖） |

## 八、按阻塞来源汇总

| 阻塞 | 负责 | 卡住的行 |
| --- | --- | --- |
| A6 `unit.run` | 40 | G0-05、G1-03、06、07、08、09、10、11，G2-01、03、04、05、09、10、11，G3-01、02、03、05、06、09、11、13、14，G4-04、11，G5-01 |
| PR4 inbox | f1 | G2-06、07、08，G3-03、04、07、10 |
| A4 身份与授权 | f1 | G1-09，G2-01、02、08、10、11，G3-02、11 |
| f1 契约增量（principal、`Run.lastEventSequence`、事件目录对齐） | f1 | G0-13，G1-08，G2-11（R5），G3-01 |
| #29 MCP | f1 | G0-02 |
| Zed 手工 Z1 | Kevin（约 2 分钟，e2e-runbook §三.1） | G0-12，G1-08、10、11，G2-10，G3-03、09，G5-01、04 |
| 真实 GUI 动作 | Q（测试副本，经协调者安排） | G0-02（T18-02），G1-11 |
| P3 实现 | Kevin 批准后 | G4 全部 |
| 环境 | Kevin / CI | G0-08（第二用户、产品实例），G3-12（CI runner），G5-02（JetBrains） |

现在就能推进、不需要任何外部依赖的 NOT_RUN 行：G0-09（T09-03）、G1-01、02、04、05 的剩余 L1 用例、G3-08（T28-02、03）、G5-05，以及各 BLOCKED 行里标「可先跑」的 L1 用例。G0-04 与 G0-11 还需要 f1 提供 `scripts/verify` 套件和对 04 的确认。
