# 实施进度

状态词：DONE（有测试证据）、PARTIAL（部分完成，缺口写明）、NOT_STARTED。产品用例状态以 tests/cases.csv 的 ID 记录；只有实际执行断言的测试才算 PASS，契约层测试不代表对应用例的服务端或真机部分已通过。

| 任务 | 状态 | 说明 |
| --- | --- | --- |
| T00 基线与迁移清单 | NOT_STARTED（本分支） | 单仓迁移由 `codex/merge-desktop-core-20261008` 那条线负责；本分支不动引擎依赖与旧两仓规则 |
| T01 原生执行边界 G0 | NOT_STARTED | 同上；真实 GUI 输入入口保持关闭 |
| T02 合同、版本化解码、32 操作、CLI rpc | PARTIAL | AgentDesktopContracts：严格 JSON、Schema 子集校验器（加载合同文件做权威校验）、信封与分帧、错误码、操作目录、路由器（结果按合同自检）。尚缺：接入 ControlServer 的旧/新双解码、CLI rpc、C# DTO |
| T03 SQLite 配置存储 | PARTIAL | `AgentDesktopAI/Config`：ConfigStore actor（WAL、migrations v1、§10.3 全部表）、三类资源不可变修订、expectedRevision CAS、tombstone 与引用保护、默认指针独立 CAS、游标绑定过滤条件、fallback≤1 且无自引用/循环、能力证据按层按修订保存；幂等记录按 caller+command+key 存 HMAC 摘要，保留 24 h，崩溃后 pending 标为 failed。21 个配置命令作为 RpcHandler。尚缺：gui_runs/events/attempts/receipts 表（T05/T07）、活跃 run 引用检查只有注入钩子 |
| T04 凭据与端点 | PARTIAL | CredentialStore 协议、KeychainCredentialStore（com.agentdesktop.ai，不同步）、InMemoryCredentialStore；创建/轮换按 pending→写机密→激活→outbox，撤销后永不解析，outbox 失败重试，恢复清理孤立机密；端点规则与 chat/completions 拼接。尚缺：真实 Keychain 只写了默认跳过的测试；DPAPI（Windows）；transport 连接时的 loopback 复核归 T05 |
| T05–T14 | NOT_STARTED | |

## 契约层测试覆盖（swift test --filter AgentDesktopContractsTests）

| 用例 | 覆盖的部分 | 未覆盖 |
| --- | --- | --- |
| RPC-001 | 信封、requestId 关联、单行、ok/result 与 ok/error 互斥 | 真实 socket 上的 application service |
| RPC-002 | 新旧版本分流、未知版本、op 替代 command | 旧 ControlRequest 解码器接入 |
| RPC-003 | 畸形 JSON、重复键、无效 UUID、未知命令、多余字段、缺 verification、模型脚本、缺幂等键；拒绝后合法请求成功；处理器调用 0 次 | provider/executor 计数（需 Runtime） |
| RPC-004 | 1 MiB 帧边界（恰好与 +1）、内联截图字段拒绝 | 读取过程中的提前终止已由 FrameReader 实现，未在真实 socket 上压测 |
| SEC-005 | 端点规则（Schema 部分） | 实际连接地址是否为 loopback 的运行时检查 |
| CFG-007 | GUI 限额上限（Schema 部分） | 服务端 LIMIT_EXCEEDED 路径 |
| 规格示例 | 规格 HTML 中 35 个请求、32 个成功响应、1 个错误响应全部通过校验 | |

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
