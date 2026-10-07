# 实施进度

状态词：DONE（有测试证据）、PARTIAL（部分完成，缺口写明）、NOT_STARTED。产品用例状态以 tests/cases.csv 的 ID 记录；只有实际执行断言的测试才算 PASS，契约层测试不代表对应用例的服务端或真机部分已通过。

| 任务 | 状态 | 说明 |
| --- | --- | --- |
| T00 基线与迁移清单 | NOT_STARTED（本分支） | 单仓迁移由 `codex/merge-desktop-core-20261008` 那条线负责；本分支不动引擎依赖与旧两仓规则 |
| T01 原生执行边界 G0 | NOT_STARTED | 同上；真实 GUI 输入入口保持关闭 |
| T02 合同、版本化解码、32 操作、CLI rpc | PARTIAL | AgentDesktopContracts：严格 JSON、Schema 子集校验器（加载合同文件做权威校验）、信封与分帧、错误码、操作目录、路由器（结果按合同自检）。AgentDesktopCLI：`rpc --request-file`、`runtime capabilities`、`--dry-run`（脱敏、不连接）、本地 Schema 校验、§13.2 退出码 0/2/3/4、真实 Unix socket 客户端。尚缺：接入 ControlServer 的旧/新双解码、C# DTO |
| T03 SQLite 配置存储 | PARTIAL | `AgentDesktopAI/Config`：ConfigStore actor（WAL、migrations v1、§10.3 全部表）、三类资源不可变修订、expectedRevision CAS、tombstone 与引用保护、默认指针独立 CAS、游标绑定过滤条件、fallback≤1 且无自引用/循环、能力证据按层按修订保存；幂等记录按 caller+command+key 存 HMAC 摘要，保留 24 h，崩溃后 pending 标为 failed。21 个配置命令作为 RpcHandler。migrations v2（分支 ai-wiring）：inference_attempts（purpose 互斥 CHECK）、model_catalog、ai_operations；`resolveGuiProfile` 按钉住的修订解析出 AiResolvedModel。尚缺：gui_runs/events/receipts 表（T07）、活跃 run 引用检查只有注入钩子 |
| T04 凭据与端点 | PARTIAL | CredentialStore 协议、KeychainCredentialStore（com.agentdesktop.ai，不同步）、InMemoryCredentialStore；创建/轮换按 pending→写机密→激活→outbox，撤销后永不解析，outbox 失败重试，恢复清理孤立机密；端点规则与 chat/completions 拼接。尚缺：真实 Keychain 只写了默认跳过的测试；DPAPI（Windows）；StoreCredentialResolver 只解析 active identity；CredentialRevocationAdmission 由 outbox 撤销事件和持久状态共同判定，在途调用结果作废。尚缺：transport 连接时的 loopback 复核 |
| T11 CLI | PARTIAL | 只有 rpc 入口与退出码；友好别名、--wait/--follow、--credential-stdin、退出码 5/6/130 待 T03/T07/T08 |
| T07 Explorer | PARTIAL | RunLifecycle：§07.1 状态边、generation CAS、§07.2 取消协议、未知结果隔离与不可恢复、终态不变；Explorer 循环、GoalVerifier、Runtime 组装待 T01/T05/T06 |
| T06 UI-TARS codec、坐标、Proposal | PARTIAL | 分支 gui-codec：GUI 领域类型（Contracts/Domain/Gui*.swift）、`CoordinateMapper`（显式协议、crop/resize/letterbox、负原点、不夹紧）、`UITarsCodec`（uitars_v1 严格单动作文法）、`FixtureJsonCodec`（仅测试模式）、`GuiCodecRegistry`、`ProposalFactory`（身份字段只取自 Observation，输出过合同校验）。尚缺：GuiAiProvider（依赖 T05 AiService）、完整 prompt 组装与历史截图裁剪、C# 端 |
| T05 AiService、OpenAIChatTransport、预算与用量 | PARTIAL | AgentDesktopAI/Inference：openai_chat 非流式传输（异步 URLSession、拒绝重定向、2 MiB 响应上限、错误分类不带上游 body）、DefaultAiService（§06.1 七步、单一单调 deadline、取消、账本先预留后请求、过期结果丢弃）、AttemptBudget/StepInference（每步 ≤2、每 run ≤30、429 Retry-After、只重试暂态错误、冻结候选）、UsageSummaryBuilder、内存账本。尚缺：SQLite 账本（T03 接 AiCallLedgerPort）、Keychain CredentialResolver（T04）、ai.models.list/refresh 模型目录、ai.usage.summary 的 RPC 处理器与调用者范围过滤；分支 ai-wiring 接上持久层：SQLiteAiCallLedger（同库预留→终态、按 attemptId 去重、记账失败阻断该预算范围、重启后 reserved→interrupted 并阻断直到核对）、ai.models.list/refresh（GET <base>/models，同一传输、失败保留旧缓存并标 stale、列表不改能力状态）、ai.usage.summary 处理器（按调用者范围、from/to/connectionId）、ai.operations.get/cancel、AiApplicationHandlers 汇总 |
| T08 四层能力测试 | PARTIAL | 分支 ai-wiring，`AgentDesktopGUI/CapabilityTests`：ai.tests.start → operation，network（无凭据 GET base）→ auth_model → image_input（双色图）→ gui_contract（单按钮图，codec 解出点击且落在按钮内）；前置层失败后续 skipped；每 operation ≤3 次模型调用、无隐藏重试、单一 120 s deadline；证据按模型修订写入（gui_contract 带 adapter/prompt/parser 版本）；失败保留已完成层；取消不进下一层；服务不持有任何观察/输入端口。尚缺：W04 页面（T09）、真实模型上的测试素材效果 |
| T09–T10、T12–T14 | NOT_STARTED | |

## 契约层测试覆盖（swift test --filter AgentDesktopContractsTests）

| 用例 | 覆盖的部分 | 未覆盖 |
| --- | --- | --- |
| RPC-001 | 信封、requestId 关联、单行、ok/result 与 ok/error 互斥 | 真实 socket 上的 application service |
| RPC-002 | 新旧版本分流、未知版本、op 替代 command | 旧 ControlRequest 解码器接入 |
| RPC-003 | 畸形 JSON、重复键、无效 UUID、未知命令、多余字段、缺 verification、模型脚本、缺幂等键；拒绝后合法请求成功；处理器调用 0 次 | provider/executor 计数（需 Runtime） |
| RPC-004 | 1 MiB 帧边界（恰好与 +1）、内联截图字段拒绝 | 读取过程中的提前终止已由 FrameReader 实现，未在真实 socket 上压测 |
| SEC-005 | 端点规则（Schema 部分） | 实际连接地址是否为 loopback 的运行时检查 |
| CFG-007 | GUI 限额上限（Schema 部分） | 服务端 LIMIT_EXCEEDED 路径 |
| COO-001..008 | 全部纯数学断言（误差 ≤1e-6）；COO-007 固定 seed 100 点、非对角矩阵、奇异矩阵 | 无（纯数学用例） |
| GUI-001 | codec 侧：恶意字段（execute/shell/screenshot/approval/raw event）一律 INVALID_ACTION；codec 只持有 provenance；Proposal 键集合等于合同键集合 | executor/capture 计数（T07 Runtime） |
| GUI-002 | 12 组 golden、28 组拒绝（未知/多动作/drag/重复参数/越界等）、type 文本脱敏 | 普通日志/events 落盘后的脱敏扫描（T07/T10） |
| GUI-004 | codec 侧：stamp/screenshotId 只取自 Observation，模型文本不能改写；非本次观察的截图 STALE_OBSERVATION；按所选截图自身的变换映射 | Runtime 输入前的 generation/target/lease 复核（T07） |
| TRN-001 | 精确的 path/headers/body（model 原样、stream:false、max_tokens、仅 temperature/seed、image_url 等于夹具 base64）；响应 text/model/usage/requestId 全保留 | 真实上游 |
| TRN-002 | 路径拼接唯一（含 /api/v3/）；非 openai_chat 协议 UNSUPPORTED_PROTOCOL 且网络 0 | |
| TRN-003 | 401/403/404/429/5xx/400 分类与 retryable；错误与账本不含上游 body 和 key | |
| TRN-004 | 非 JSON、截断、缺 choices、content 非字符串、重复键、缺 message 均 UPSTREAM_PROTOCOL_ERROR，随后合法响应成功 | proposal/executor 计数（无 GUI 层） |
| TRN-005 | 5 张图恰好 8 MiB base64 可发且实际 payload 等于上限；+4 字节与 6 张图 LIMIT_EXCEEDED 且网络 0 | 历史裁剪与保留当前图（GUI Provider，T06/T07） |
| TRN-006 | requestOptions 只接受 temperature/seed，thinking/厂商扩展/覆盖 model、stream、凭据 VALIDATION_ERROR；max_tokens 取 profile 与 1024 的较小值；超限 LIMIT_EXCEEDED | 生产 UI-TARS profile 的请求（T06） |
| TRN-007 | 响应体读完前不返回结果；SSE 与截断动作 UPSTREAM_PROTOCOL_ERROR | executor 计数（无 GUI 层） |
| RET-001 | FakeClock：t<2000 ms 第二次请求 0，t=2000 ms 为 1；剩余 1500 ms 不重试 | |
| RET-002 | 503 最多 2 次，401/400/坏响应 1 次，从不第 3 次 | INVALID_ACTION/CAPABILITY_MISMATCH（GUI 层） |
| RET-003 | 暂态失败换到冻结的 fallback（端点、模型、凭据均为快照）；每步总 attempt=2 | 绑定前的越权/能力检查（T07） |
| RET-004 | 仅证明模型服务没有任何输入端口 | 动作不重放（Runtime，T01/T07） |
| USG-001 | 失败、成功、取消 3 行且 id 唯一，重复 finish 不重复计数；账本预留失败网络 0，记账失败后阻止下一次调用 | 持久化（T03）、调用者/session 归属 |
| USG-002 | 100/10、只 input、无 usage 三种：小计 300/10、缺用量 2、无金额 unknown；实际与请求模型分别记录 | UI/CLI 渲染 |
| USG-003 | requireReportedUsage 时下一次推理 USAGE_UNAVAILABLE 且网络 0；false 对照组继续 | |
| USG-004 | connectionId/时间过滤、estimated 标签、未知不转 0、结果通过 ai_usage_summary_result 校验 | gui.runs.get、诊断导出、改价后旧 run |
| SEC-002 | 撤销/缺失凭据 CREDENTIAL_REVOKED/REQUIRED，网络与账本均 0 | Keychain 与重启（T04） |
| SEC-006 | 真实 URLSession + 回环服务器：302/307 不跟随，B 收到 0 个请求，A 的 Authorization 精确；错误不回显 body（变异测试确认：放开重定向时测试失败） | CLI stdin 与 argv（T11） |
| 规格示例 | 规格 HTML 中 35 个请求、32 个成功响应、1 个错误响应全部通过校验 | |
| CLI-001/002（部分） | rpc 完整信封入口、dry-run 不连接且脱敏、本地校验失败 exit 2 且不发送、运行时不可达 exit 3、业务拒绝 exit 4、响应不属于本请求或越出合同 exit 3、单行 stdout | 友好别名、--wait、stdin 凭据 |
| CAN-001/003/004、RET-004、GUI-008、EXE-003（状态机部分） | 取消先使 generation 失效且不改初始值；迟到建议不能变成输入；在途输入取消后等执行器结论；unknown 保持隔离、不能恢复、重复取消无副作用、终态不变 | 真实 HTTP 取消、执行器、计时器、冲突域锁 |

## 配置层测试覆盖（swift test --filter AgentDesktopAITests）

| 用例 | 覆盖的部分 | 未覆盖 |
| --- | --- | --- |
| CFG-001 | 三层独立 ID、初始修订、引用版本、credentialRef 无密钥、重开数据库后等价 | |
| CFG-002 | 三类资源 A 成功 r+1、B CONFIG_CONFLICT 带 currentRevision、持久化为 A | |
| CFG-003 | 默认指针 CAS、旧 d 冲突、profile 编辑不动默认 revision | 已有 run binding 不变（需 T07） |
| CFG-004 | 旧修订快照逐字节不变；禁用后新绑定 RESOURCE_DISABLED | 运行中 R 的请求参数不变（需 T05/T07） |
| CFG-005 | RESOURCE_IN_USE（模型引用、GUI 引用、默认、fallback、活跃 run 钩子）、错误 revision 恒 CONFIG_CONFLICT、tombstone、list 排除、历史可追溯 | |
| CFG-006 | 缺失 NOT_FOUND、过期 CONFIG_CONFLICT、自引用与循环 VALIDATION_ERROR、fallback=2、fixture 适配器 CAPABILITY_MISMATCH | 完整 run binding 持久化（T07） |
| CFG-007 | 各上限超限/0/负数拒绝、可收紧；非 openai_chat 服务层 UNSUPPORTED_PROTOCOL（经 RPC 由 Schema 先答 VALIDATION_ERROR） | |
| CFG-008 | 证据按层独立、按修订绑定、修订后回到 unknown、旧修订证据保留 | 四层测试产生证据（T08） |
| SEC-001 | 全部响应与 SQLite/WAL/SHM 文件字节 canary=0 | 日志、events、usage、导出（后续模块） |
| SEC-002 | 重启后读取、机密缺失/读失败 CREDENTIAL_REQUIRED、无回退路径 | 真实 Keychain 锁定 |
| SEC-004 | 存储部分：旧 identity 撤销即不可解析、监听回调、旧机密删除、修订绑定各自 identity | 在途推理取消（T05） |
| SEC-005 | https/loopback/userinfo/query/fragment/非 http(s)/chat/completions 结尾；本地选项开关；localhost 解析校验 | |
| RPC-006 | 配置类：10 并发同 key 只建 1 个连接、1 份机密 | tests.start / runs.start |
| RPC-007 | 配置类：同 key 不同内容（含仅机密不同）冲突、另一 caller 同 key 互不可见 | |

## AI 接线与能力测试覆盖（分支 ai-wiring：swift test --filter "LedgerWiringTests|CatalogOperationTests|UsageServiceTests|CapabilityTests"）

| 用例 | 覆盖的部分 | 未覆盖 |
| --- | --- | --- |
| TRN-008 | 四层各自 state/evidence；参数化在每一层停下：之前 passed、该层 failed、之后 skipped，模型调用数精确；非法 UI-TARS 回复（无 Action、drag、多动作）INVALID_ACTION；点击落在按钮外 TARGET_MISSED；取消延迟测试后不进下一层、结果 null、账本该次 cancelled；图片是合成素材 | 真实模型 |
| CFG-008 | 四层测试写入证据并绑定模型修订；skipped 不写证据；模型修订更新后四层回到 unknown，旧修订证据保留；模型列表刷新不改任何能力状态 | |
| USG-001 | 持久化：两种 purpose 同库各一行、purpose 互斥 CHECK 生效、重启后仍在、重复 finish 不重复计数；预留失败网络 0；记账失败阻断同一 run，其他 run 不受影响；崩溃后 interrupted 计为未知用量并阻断直到核对 | |
| USG-003/004 | ai.usage.summary 从 SQLite 聚合：只含调用者自己的尝试、from/to 与 connectionId 过滤、缺用量计数、未知不当 0、结果过 Schema；端到端 3 次尝试其中 1 次无用量 | 按 run 查询（gui.runs.get，T07） |
| SEC-002 | 解析侧接 ConfigStore：active 才解析，未知/轮换后旧 identity/机密缺失分别 CREDENTIAL_REQUIRED/REVOKED/REQUIRED，无回退 | 真实 Keychain |
| SEC-004 | 调用挂起时轮换：迟到结果作废（账本 discarded=1）、旧 identity 之后上游调用 0、未带 K2；显式采纳新连接修订后新绑定用 K2 | 主动取消在途 HTTP（由 Explorer 的 Task 取消负责） |
| RPC-006/007 | ai.tests.start：10 并发同 key 只 1 个 operation、模型调用数等于单次；同 key 不同内容 IDEMPOTENCY_CONFLICT；另一调用方同 key 各自独立且互不可见 | gui.runs.start（T07） |
| CAN-004 | operation 取消：受理与终态分开、终态后重复取消 accepted=false 且无新请求/尝试、已取消的重复取消幂等、他人 operation NOT_FOUND；重启后未完成 operation 结束 | |
| UI-004（服务端部分） | 分层结果、pending/cancelled/failed 区分、performedDesktopInput=false、费用来自尝试记录 | 页面 |

