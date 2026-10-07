# 实施进度

状态词：DONE（有测试证据）、PARTIAL（部分完成，缺口写明）、NOT_STARTED。产品用例状态以 tests/cases.csv 的 ID 记录；只有实际执行断言的测试才算 PASS，契约层测试不代表对应用例的服务端或真机部分已通过。

| 任务 | 状态 | 说明 |
| --- | --- | --- |
| T00 基线与迁移清单 | NOT_STARTED（本分支） | 单仓迁移由 `codex/merge-desktop-core-20261008` 那条线负责；本分支不动引擎依赖与旧两仓规则 |
| T01 原生执行边界 G0 | NOT_STARTED | 同上；真实 GUI 输入入口保持关闭 |
| T02 合同、版本化解码、32 操作、CLI rpc | PARTIAL | AgentDesktopContracts：严格 JSON、Schema 子集校验器（加载合同文件做权威校验）、信封与分帧、错误码、操作目录、路由器（结果按合同自检）。尚缺：接入 ControlServer 的旧/新双解码、CLI rpc、C# DTO |
| T05 AiService、OpenAIChatTransport、预算与用量 | PARTIAL | AgentDesktopAI/Inference：openai_chat 非流式传输（异步 URLSession、拒绝重定向、2 MiB 响应上限、错误分类不带上游 body）、DefaultAiService（§06.1 七步、单一单调 deadline、取消、账本先预留后请求、过期结果丢弃）、AttemptBudget/StepInference（每步 ≤2、每 run ≤30、429 Retry-After、只重试暂态错误、冻结候选）、UsageSummaryBuilder、内存账本。尚缺：SQLite 账本（T03 接 AiCallLedgerPort）、Keychain CredentialResolver（T04）、ai.models.list/refresh 模型目录、ai.usage.summary 的 RPC 处理器与调用者范围过滤 |
| T03、T04、T06–T14 | NOT_STARTED | |

## 契约层测试覆盖（swift test --filter AgentDesktopContractsTests）

| 用例 | 覆盖的部分 | 未覆盖 |
| --- | --- | --- |
| RPC-001 | 信封、requestId 关联、单行、ok/result 与 ok/error 互斥 | 真实 socket 上的 application service |
| RPC-002 | 新旧版本分流、未知版本、op 替代 command | 旧 ControlRequest 解码器接入 |
| RPC-003 | 畸形 JSON、重复键、无效 UUID、未知命令、多余字段、缺 verification、模型脚本、缺幂等键；拒绝后合法请求成功；处理器调用 0 次 | provider/executor 计数（需 Runtime） |
| RPC-004 | 1 MiB 帧边界（恰好与 +1）、内联截图字段拒绝 | 读取过程中的提前终止已由 FrameReader 实现，未在真实 socket 上压测 |
| SEC-005 | 端点规则（Schema 部分） | 实际连接地址是否为 loopback 的运行时检查 |
| CFG-007 | GUI 限额上限（Schema 部分） | 服务端 LIMIT_EXCEEDED 路径 |
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
