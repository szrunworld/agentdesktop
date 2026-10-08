# 实施进度

状态词：DONE（有测试证据）、PARTIAL（部分完成，缺口写明）、NOT_STARTED。产品用例状态以 tests/cases.csv 的 ID 记录；只有实际执行断言的测试才算 PASS，契约层测试不代表对应用例的服务端或真机部分已通过。

| 任务 | 状态 | 说明 |
| --- | --- | --- |
| T00 基线与迁移清单 | NOT_STARTED（本分支） | 单仓迁移由 `codex/merge-desktop-core-20261008` 那条线负责；本分支不动引擎依赖与旧两仓规则 |
| T01 原生执行边界 G0 | NOT_STARTED | 同上；真实 GUI 输入入口保持关闭 |
| T02 合同、版本化解码、32 操作、CLI rpc | PARTIAL | AgentDesktopContracts：严格 JSON、Schema 子集校验器（加载合同文件做权威校验）、信封与分帧、错误码、操作目录、路由器（结果按合同自检）。AgentDesktopCLI：`rpc --request-file`、`runtime capabilities`、`--dry-run`（脱敏、不连接）、本地 Schema 校验、§13.2 退出码 0/2/3/4、真实 Unix socket 客户端。尚缺：接入 ControlServer 的旧/新双解码、C# DTO |
| T03 SQLite 配置存储 | PARTIAL | `AgentDesktopAI/Config`：ConfigStore actor（WAL、migrations v1、§10.3 全部表）、三类资源不可变修订、expectedRevision CAS、tombstone 与引用保护、默认指针独立 CAS、游标绑定过滤条件、fallback≤1 且无自引用/循环、能力证据按层按修订保存；幂等记录按 caller+command+key 存 HMAC 摘要，保留 24 h，崩溃后 pending 标为 failed。21 个配置命令作为 RpcHandler。migrations v2（分支 ai-wiring）：inference_attempts（purpose 互斥 CHECK）、model_catalog、ai_operations；`resolveGuiProfile` 按钉住的修订解析出 AiResolvedModel。尚缺：gui_runs/events/receipts 表（T07）、活跃 run 引用检查只有注入钩子 |
| T04 凭据与端点 | PARTIAL | CredentialStore 协议、KeychainCredentialStore（com.agentdesktop.ai，不同步）、InMemoryCredentialStore；创建/轮换按 pending→写机密→激活→outbox，撤销后永不解析，outbox 失败重试，恢复清理孤立机密；端点规则与 chat/completions 拼接。尚缺：真实 Keychain 只写了默认跳过的测试；DPAPI（Windows）；StoreCredentialResolver 只解析 active identity；CredentialRevocationAdmission 由 outbox 撤销事件和持久状态共同判定，在途调用结果作废。尚缺：transport 连接时的 loopback 复核 |
| T11 CLI | PARTIAL | §13.1 全部友好命令（表驱动，映射到 32 个操作）、`--params-file`（只收 params，与 flag 重复即本地冲突）、`--credential-stdin`（拒绝 `--api-key`）、mutation 必须 `--idempotency-key`、`--dry-run`、`--wait`（stdout 为最后一次 get，受理写 stderr）、`--follow`（NDJSON）、退出码 0/2/3/4/5/6/130、Ctrl-C 先提交同键取消。尚缺：TTY 无回显输入、打包进产品 bin/agentdesktop（待单仓迁移） |
| T07 Provider、Explorer、验证、gui.runs | PARTIAL | RunLifecycle（§07 状态机）；GuiAiProvider（只依赖 AiService/codec/纯数据，版本化 prompt，当前图必保留的历史裁剪，经 StepInference 用冻结候选与共享预算）；GuiRunDriver（§06.3 有界循环：取消/generation/deadline/步数/attempt 先检查，finish 只触发新观察+验证，needs_user 与 unknown 进 waiting_user 且绝不重发，迟到结果记 discarded，审计写失败即 AUDIT_UNAVAILABLE）；GoalVerifier（element_text_equals/static_text 精确匹配，后端读不到元素时 CAPABILITY_MISMATCH）；GuiRunService（gui.runs.start/get/cancel/events、runtime.capabilities；按 caller 隔离，start 幂等，默认 profile 在 start 时解析后固定，省略 sessionId 仅限 owner）；ConfigBindingResolver（精确修订快照、禁用/过期/撤销/不兼容 fallback 在调用模型前拒绝）；InMemoryGuiRunRepository；SQLite 持久化（`AgentDesktopAI/Runs`，迁移 v3：gui_runs/gui_run_refs/gui_events/gui_inference_steps/gui_inference_receipts/action_receipts/runtime_state）：SQLiteGuiRunRepository 与内存版同一契约、SQLiteGuiAuditPort（输入前先写 pending 行并记预期目标，写失败 AUDIT_UNAVAILABLE 且不输入；回执按 id 去重、已定状态不再改写）、RunRecovery（§07.4：epoch+1，pending/submitted → unknown 并保持隔离，取消已受理则 cancelling，无在途输入的 run 结束，绝不重发；重复重启幂等）、活跃 run 引用保护删除。尚缺：Runtime 侧真实观察/执行端口（T01，真实 GUI 输入保持关闭：无执行后端时 start 返回 CAPABILITY_MISMATCH）、由 Runtime 用 unresolvedActions 返回 DESKTOP_BUSY、人工核对入口 |
| T11 CLI | PARTIAL | 只有 rpc 入口与退出码；友好别名、--wait/--follow、--credential-stdin、退出码 5/6/130 待 T03/T07/T08 |
| T06 UI-TARS codec、坐标、Proposal | PARTIAL | 分支 gui-codec：GUI 领域类型（Contracts/Domain/Gui*.swift）、`CoordinateMapper`（显式协议、crop/resize/letterbox、负原点、不夹紧）、`UITarsCodec`（uitars_v1 严格单动作文法）、`FixtureJsonCodec`（仅测试模式）、`GuiCodecRegistry`、`ProposalFactory`（身份字段只取自 Observation，输出过合同校验）。尚缺：GuiAiProvider（依赖 T05 AiService）、完整 prompt 组装与历史截图裁剪、C# 端 |
| T05 AiService、OpenAIChatTransport、预算与用量 | PARTIAL | AgentDesktopAI/Inference：openai_chat 非流式传输（异步 URLSession、拒绝重定向、2 MiB 响应上限、错误分类不带上游 body）、DefaultAiService（§06.1 七步、单一单调 deadline、取消、账本先预留后请求、过期结果丢弃）、AttemptBudget/StepInference（每步 ≤2、每 run ≤30、429 Retry-After、只重试暂态错误、冻结候选）、UsageSummaryBuilder、内存账本。尚缺：SQLite 账本（T03 接 AiCallLedgerPort）、Keychain CredentialResolver（T04）、ai.models.list/refresh 模型目录、ai.usage.summary 的 RPC 处理器与调用者范围过滤；分支 ai-wiring 接上持久层：SQLiteAiCallLedger（同库预留→终态、按 attemptId 去重、记账失败阻断该预算范围、重启后 reserved→interrupted 并阻断直到核对）、ai.models.list/refresh（GET <base>/models，同一传输、失败保留旧缓存并标 stale、列表不改能力状态）、ai.usage.summary 处理器（按调用者范围、from/to/connectionId）、ai.operations.get/cancel、AiApplicationHandlers 汇总 |
| T08 四层能力测试 | PARTIAL | 分支 ai-wiring，`AgentDesktopGUI/CapabilityTests`：ai.tests.start → operation，network（无凭据 GET base）→ auth_model → image_input（双色图）→ gui_contract（单按钮图，codec 解出点击且落在按钮内）；前置层失败后续 skipped；每 operation ≤3 次模型调用、无隐藏重试、单一 120 s deadline；证据按模型修订写入（gui_contract 带 adapter/prompt/parser 版本）；失败保留已完成层；取消不进下一层；服务不持有任何观察/输入端口。尚缺：W04 页面（T09）、真实模型上的测试素材效果 |
| 组装（§03.1 composition） | PARTIAL | AgentDesktopService：一个配置库、一个共享模型服务（能力测试与 GUI 运行共用）、运行服务，为调用方产出全部 32 个处理器；RpcSocketServer：0700 目录、0600 socket、对端 uid 校验、一连接一请求、空探测连接不回写、早退客户端不致宿主 SIGPIPE。真实执行后端未注入时 gui.runs.start 为 CAPABILITY_MISMATCH。尚缺：接入引擎 ControlServer 的双解码（T01/T02 由单仓迁移线完成）、SQLite 运行仓库（并行分支 gui-run-store） |
| T13 Windows 对等 | PARTIAL | `windows/`（net10.0，global.json 锁 10.0.401）：①C# 合同层——严格 JSON、Schema 子集校验器、信封与 1 MiB 分帧、32 操作、路由器自检，87 项测试与跨平台信封夹具；②AgentDesktop.AI 配置与凭据（T03/T04 对等）——SQLite ConfigStore、DPAPI CurrentUser + 私有 ACL 目录（Windows CI 实测）、创建/轮换 outbox 与恢复、端点规则、21 个配置命令，44 项测试与 32 步跨平台配置脚本（Swift 同跑）；③AgentDesktop.GUI（T06 对等）——GUI 领域类型、仿射与截图变换、CoordinateMapper（不 clamp）、严格 UITarsCodec/FixtureJsonCodec、ProposalFactory，18 项测试，与 Swift 共用 `Tests/AgentDesktopGUITests/Fixtures/codec-golden.json`（258 条）。不构成 G6：Windows 原生运行时、NamedPipe、C# 模型服务、GuiAiProvider/Explorer 未做 |
| T09 设置页 W01–W04 | PARTIAL | `AgentDesktopAIUI`（只依赖 Contracts）：ContractClient（进程内 / Unix socket，requestId 关联与结果合同校验）；W01 连接列表（两种空状态、刷新失败保留旧列表与数据时间、停用/删除 CAS）、W02 添加/编辑（本地端点规则且错误不引用 URL、密钥只在提交瞬间读出并清空、metadata 保存不动凭据、冲突保留草稿并按「只保留自己改过的字段」合并、轮换单独提交）、W03 GUI 配置与模型配置子面板（上限只能调低、生产不列 fixture 适配器、默认指针独立 d 版本 CAS）、W04 四层测试（逐层状态、未执行≠失败、取消先显示取消中、实际桌面输入 0、费用提示）。尚缺：未挂进 App 主窗口；原生 UI 自动化与录屏；900px/读屏的人工验收 |
| T10 诊断页 W05–W08 | PARTIAL | W05 启动（仅验证不建 run、双击与重试复用同一键、fixture 配置不可选、完成条件固定为 element_text_equals）、W06 运行详情（阶段、尝试与已确认动作分列、验证证据、固定版本摘要、events 按 afterSequence 去重且游标过期重读完整状态、停止受理≠已停止）、W07 需要处理（unknown 与取消中两个分支、只读 get/events、无重试/强制成功/resume、动作前旧证据标注）、W08 用量（尝试与动作分列、未知不显示为 0、明确 0 单独标注、金额标估算与「总额未知」）。AIGUIRootView 侧栏切换八页。尚缺：同上；服务端 ai.usage.summary 的 confirmedActions/unknownActionOutcomes 目前恒为 0（未读动作回执，AI 模块缺口） |
| T12、T14 | NOT_STARTED | |

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

## GUI 运行层测试覆盖（swift test --filter AgentDesktopGUITests，执行器与观察为模拟中立表单的替身）
| MAC-001（单元化） | 模型依次 click 姓名框 → type Ada → click 应用 → finish；页面结果晚一拍显示时由 finish 之后更新的观察验证通过；执行器恰好 3 个动作、提交次数 1、模型调用/步数/事件序号/回执与 Schema 一致；事件不含键入正文 | 真机、真实模型、原生输入隔离（G5） |
| GUI-001 | Provider 构造参数（反射 3 层）不含任何端口；多 Action 回复 INVALID_ACTION、无提案无输入、推理回执仍入账 | |
| GUI-003 | finish 但文本不符不能成功（预算耗尽 LIMIT_EXCEEDED，验证 failed）；每次 finish 后都有新观察；后端读不到元素 CAPABILITY_MISMATCH | 模型改写谓词：谓词只来自 binding，模型无任何写入路径 |
| GUI-004 | 提案的 stamp/screenshotId 只取自观察，模型文本里的 desk/snapshot 字样无效；回执与 Schema 一致 | Runtime 输入前复核（T01） |
| GUI-005 | 未授权动作 FORBIDDEN、执行器 0 次、表单未变 | 禁用提交目标（Runtime hold，T01） |
| GUI-006 | 第 21 步不发生（20 次调用、20 步）；每步最多 2 次 attempt；全程 attempt 上限；wall deadline 到点后不再发模型 | |
| GUI-007 | wait 0/5000 可用且消耗一步、之后重新观察；5001/-1 拒绝且无输入；等待中取消撤销计时器、不再观察 | |
| GUI-008 | needs_user → waiting_user；unknown → waiting_user/ACTION_OUTCOME_UNKNOWN；resume 命令 UNSUPPORTED_COMMAND | Runtime 核对流程（T01） |
| CAN-002 | 推理中取消：HTTP 任务取消、run cancelled、generation 2 而 binding 仍为 1、输入 0；迟到答案记 discarded、不入审计、不产生输入（变异检查：去掉丢弃判断后测试失败） | 真实 URLSession 取消回调（T05 已测） |
| CAN-003 | 输入中取消：cancelling 且非终态，执行器回执后才 cancelled，不再调用模型 | |
| CAN-004 | 结束后重复取消 3 次：accepted=false、状态与事件数不变、无新调用 | |
| RET-003（GUI 侧） | 主候选 503 后在同一步内改用 binding 冻结的 fallback（candidateIndex 1），共 2 次 attempt | |
| RET-004 | unknown 后不自动重点击：提交 1 次、执行 1 次、模型 1 次 | |
| RPC-005（服务侧） | 非 owner 省略 sessionId FORBIDDEN；伪造 sessionId FORBIDDEN；合法显式 session 可启动 | 真实 session 授权（T01） |
| RPC-006 | 10 个并发同 key start 只得一个 runId、模型只调用一次 | 断连后重试（传输层） |
| RPC-007 | 同 key 不同内容 IDEMPOTENCY_CONFLICT；其他 caller get/cancel 得 NOT_FOUND | |
| RPC-008 | 事件序号严格递增、after=2 只返回 >2、重复读取一致、after=last 为空、分页 nextAfterSequence/hasMore、过期游标 EVENTS_CURSOR_EXPIRED、未知 ID NOT_FOUND | 持久化保留策略（SQLite 版） |
| TRN-005（GUI 侧） | 6 张历史 + 当前：发送 5 张、当前必在、保留最新历史；字节预算紧时只发当前图 | |
| D07 / CFG-004（运行侧） | 改默认 profile 后已有 run 的 binding 不变、新 run 用新默认；禁用 profile RESOURCE_DISABLED、过期修订 CONFIG_CONFLICT，均不调用模型 | |

## 纵向切片（swift test --filter AgentDesktopServiceTests）

模型为脚本化 HTTP 上游，桌面为中立表单替身；不证明原生输入隔离（G0/T01）。

| 用例 | 覆盖的部分 | 未覆盖 |
| --- | --- | --- |
| E01–E12（规格 §02） | 经组装服务：建连接、刷新并列出模型、模型配置、GUI 配置（normalized_1000，含真实缩放变换）、四层能力测试成功且桌面输入 0、设默认、启动运行、3 次模型调用 3 个输入、较新观察上验证通过、表单为期望文本、用量覆盖两类调用、事件序列单调、同 key 重启返回同 run 且无新输入 | 真实模型、真实桌面 |
| 32 操作 | 组装后每个合同命令都有处理器 | |
| GUI-003（服务层） | 验证文本不符时走完全部步骤也不能成功 | |
| SEC-001（服务层） | 全部读接口响应与数据库文件中 canary=0；上游只在 chat 请求的 Authorization 中出现 | 日志与导出 |
| MAC-007（服务层） | 无执行后端时 AI 侧完整可用、能力页 nativeIsolationEvidence=NOT_RUN、gui.runs.start CAPABILITY_MISMATCH、输入 0 | 无模型时的直接 API（引擎） |
| CLI-001（真实 socket） | CLI 经 0600 socket 调组装服务；第二个服务器不能接管活跃端点；3 个发完即走的客户端后宿主仍存活并正常应答 | |
| CLI-001 | 经真实 socket：create（stdin 取 key）→ get → list，stdout 恰一行 JSON，ID 与 revision 与 API 一致，过期 revision exit 4 | |
| CLI-002 | `--api-key` 拒绝 exit 2、缺 `--credential-stdin` 拒绝、stdout/stderr canary=0 | 进程 argv 采集（无明文 key 入口，结构上不可能） |
| CLI-003 | `gui run --wait` 到 succeeded、受理在 stderr、不带 --wait 立即返回 runId、同键同 runId 且无新输入、`events --follow` 序列单调、after=last 为空 | 进程树无 TS（本包不含任何 Node 代码） |
| CLI-004 | `--dry-run`（含 --wait）不连接、不调模型、不执行、不建对象、key 脱敏；非法动作 exit 2 | |
## 运行持久化测试覆盖（swift test --filter "RunsStoreTests|RunsSQLiteTests"）
| RPC-006 | 重开数据库后同 key 同语义仍返回原 runId，不同语义 IDEMPOTENCY_CONFLICT，另一调用方同 key 互不可见；SQLite 与内存版同一脚本输出逐条相同 | |
| RPC-008 | 重开后事件序号继续单调；裁剪后旧 cursor 仍过期（oldestRetained 持久）；未知 run NOT_FOUND；重开后 gui.runs.events 序号连续且每条通过 RunEvent Schema | |
| EXE-003 / RET-004（持久化部分） | 真实数据库文件：写 pending 后进程「消失」、重开、恢复 → 回执 unknown（带预留时记下的目标、无证据、inputPath=unrecorded）、run waiting_user / ACTION_OUTCOME_UNKNOWN、generation+1、epoch+1、桌面列入 unresolvedActions、执行器调用仍为 1；恢复后的 gui.runs.get 通过合同；二次重启幂等；核对后解除隔离、记录仍为 unknown | Runtime 拒绝新输入（DESKTOP_BUSY）与人工核对界面 |
| §07.4 其余分支 | 取消已受理 + 在途输入 → cancelling；无在途输入：执行中/等人 → failed（写明 runtime 重启），cancelling → cancelled，终态不动 | 证据文件缺失的 missing 标注（尚无证据文件存储） |
| USG-001（回执） | 推理回执按 attemptId 去重（重复记录不增行）；动作回执已定状态不被改写 | |
| AUDIT_UNAVAILABLE | pending 行写失败 → reserveAction 抛 AUDIT_UNAVAILABLE、无行；整条 run 失败且执行器 0 次（变异检查：去掉该判断后两项测试失败） | |
| CFG-005（活跃 run） | 活跃 run 绑定的 GUI profile 删除 RESOURCE_IN_USE，run 取消终结后可删；引用来自 binding 的主候选与 fallback | |
| 错误响应合规（两端） | 拒绝请求：解析失败 `details.reasonCode`、Schema 违例 `details.fieldErrors[{path,code}]`、未知版本不带 details；所有错误出门前投影到合同允许的 details 键（内部 httpStatus 等丢弃，`field` 转 fieldErrors，消息截到 512），仍不合规则去掉 details；Swift 与 C# 读同一份跨平台夹具（28 条信封 + 6 条分帧）得出相同结论 | |

## 页面层测试覆盖（swift test --filter AgentDesktopAIUITests）

视图模型经进程内 ContractClient 驱动真实组装服务；模型为脚本化上游，桌面为中立表单替身。不含原生 UI 自动化、真实窗口截图或真实模型。

| 用例 | 覆盖的部分 | 未覆盖 |
| --- | --- | --- |
| UI-001 | 空库与无匹配两种空状态、刷新失败保留旧列表与数据时间（不显示为空库）、停用后 revision 与状态、过期 revision 为 CONFIG_CONFLICT 且不伪更新、视图模型中无密钥 | 五状态截图、键盘导航录屏、CLI 改动后刷新的人工核对 |
| UI-002 | 5 类非法 URL 本地拒绝且不发请求、错误文案不引用 URL、密钥不回填、metadata 保存凭据身份不变、两窗口冲突显示 r1→r2 与变化字段并保留草稿、合并后保存成功、轮换单独提交并清空输入、未保存 Base URL 时拒绝获取模型 | 真实 Keychain |
| UI-003 | 模型配置子面板、GUI 配置、默认指针 CAS（旧 d 冲突）、上限超出不发请求、生产不列 fixture 适配器 | 运行中 run 的绑定展示（见 UI-005） |
| UI-004 | 四层全部通过且桌面输入 0、image 失败则 GUI 未执行、取消先 cancelling 后 cancelled 且未完成层不标通过 | 视觉录屏 |
| UI-005 | 仅验证无 run 无输入、并发双击只发一次、重试复用键得同一 runId、之后改默认不影响已绑定 run、只提交一次表单 | Desktop A/B 双桌面（无原生后端） |
| UI-006 | W06 成功与验证证据、事件去重有序、停止受理显示「停止请求已收到」而非「已停止」、核对后才显示已停止且停止后无新输入；W07 unknown 分支文案、旧证据标注、读证据不重发、无创建新运行入口、停止后为取消中 | 晚到模型响应的页面录屏 |
| USG-004 | 尝试与动作分列、缺用量显示「未知 / 未报告」、明确 0 显示「0 / 明确报告」、费用标估算且不完整时「总额未知」、非账单提示 | 按 run/修订钻取、诊断导出 |
| 其他 | Unix socket 客户端往返与不可达映射；九个视图在 NSHostingView 中 1440×1000 布局一次不崩 | 900px 宽、读屏器 |
