# A4 客户端身份认证：ACP 侧准备包

状态：2026-10-08，基于 `main`@cbe7772 核对。性质：**测试与契约提案，不实现 Runtime 身份**。Kevin 批准 ACP 为 A4 准备测试和契约提案；A4 本身（PR3，Hub Core）由 Runtime 负责人 f1 实现，见 [docs/plan/02](../plan/02-implementation-plan.md) A4 与 [04](../plan/04-agent-hub-integration.md) 4.2～4.4。

本文与 [07 R4](07-runtime-requests.md)（调用方 principal）衔接：R4 是 PR2b 的「本机 owner 身份透出」，本文是 PR3 的「配对客户端身份、凭据与隔离」。

> **层级说明**：本包测试分 Mock 与 Real 两层。Mock 测试今天就能跑，只验证 ACP 自己的行为（不信任编辑器给的身份、如实对待 `verified=false`、认证错误不重发、认证错误脱敏）。**Mock 全部通过不等于 A4 完成**，也不能写成 A4 完成；A4 的验收只认 Real 层在真实 Runtime 测试副本上的通过记录（README 第五节附加约束 6）。

## 一、差距表：现状 vs A4 目标

### 1. 契约（`contracts/runtime/v1`）

| # | 项 | A4 目标 | 现状与证据 | 差距 |
| --- | --- | --- | --- | --- |
| C1 | 握手带调用方 principal | 每个连接的握手结果都带 `principal{clientId, role, connectionId}`（04 §4.2；冻结文档 §2） | `RuntimeIdentity` 无 `principal`，且 `additionalProperties: false`（runtime.schema.json:275–277）；`Principal` 已定义但注明「Reserved for handshake results (PR2b)」（runtime.schema.json:2283–2291）；docs/plan/03-runtime-contract.md:28 把含 principal 的握手记为「已实现」，与代码不符 | 缺字段；03 文档状态需更正 |
| C2 | 握手能携带凭据 | 配对客户端每次握手用凭据认证（04 §4.2 第 6 行） | `runtime_handshake_params` 只有 `apiVersions`、`client{name, version}`，`additionalProperties: false`（runtime.schema.json:167–200） | 无凭据字段，也无法声明「我是 App 而不是 owner」 |
| C3 | 配对 | `hub.pairing.start/status/approve/deny`，短码，一次确认 | methods.json:685–708 全部 `reserved`、`pr: PR3`，没有 params/result schema | 方法与 schema 都缺 |
| C4 | 凭据签发、过期、撤销 | 签发 `app:<id>` 与凭据；期限默认 1 小时（04 §4.2）；`hub.clients.revoke` | `hub.clients.revoke`、`hub.grants.revoke` reserved（methods.json:721、739）；errors.json 只有 `client_revoked`（:180–184）与 `grant_expired`（:194，针对授权不是凭据） | 缺「凭据无效」「凭据过期」两个码；凭据期限与 Grant 期限是否同一件事未定 |
| C5 | 未配对调用的错误 | 未配对只能调 handshake、capabilities、pairing.*，其余 `pairing_required`（04 §4.2） | `pairing_required` 在 errors.json:173 为 `reserved`；没有写明哪些方法对未配对开放 | 缺「未配对可调方法」白名单 |
| C6 | 请求账本按 clientId 分区 | 不同客户端的 requestId 互不影响 | `requestLedger.key = "caller uid + requestId"`（methods.json:12） | 同一用户下所有客户端共用一个 requestId 空间 |
| C7 | 认证错误不回显敏感信息 | 错误里没有凭据、他人 clientId | 契约没有对 auth 错误的 `details` 做约束 | 缺约束 |

### 2. Runtime 代码（`Sources/AgentDesktopRuntime`）

| # | 项 | 现状与证据 | 差距 |
| --- | --- | --- | --- |
| R1 | 连接认证 | 只校验 `getpeereid` 同 uid（IPC/RuntimeServer.swift:190）；每个连接 `ConnectionState(peerUID:)`（:198），`clientId = "local:<uid>"`（RuntimeService.swift:26） | 没有凭据校验；同用户的任何进程都是 owner |
| R2 | 握手 | 只协商版本、记下 `client.name`，返回 Runtime 自己的身份（RuntimeService.swift:218–229） | 不返回 principal，不收凭据 |
| R3 | owner 判定 | `isOwner(c) = c.clientId.hasPrefix("local:")`（RuntimeService+Runs.swift:8），owner 看见并控制所有 Run（:12） | 在 A4 前所有本机连接都是 owner，跨 client 隔离无从体现 |
| R4 | Run 隔离 | `ownRun` 对非 owner 按 `clientId` 过滤并返回 `not_found`（RuntimeService+Runs.swift:12）；`run.list` 非 owner 强制本 clientId（:64）；`events.subscribe` 非 owner 只看本 clientId（RuntimeService+Events.swift:51）；`attach` 比对 clientId（Execution/ExecutionCoordinator.swift:133）；artifact 同理（RuntimeService+Artifacts.swift:12） | **骨架已在**：一旦出现非 `local:` 的 clientId，这些检查就生效。缺的是能产生 `app:<id>` 连接的认证 |
| R5 | 会话与账本隔离 | Session 按 uid 归属（Sessions/SessionManager.swift:36–37）；请求账本按 `peerUID`（RuntimeService.swift:178） | 不按 clientId；两个配对 App 能互用 sessionId、requestId 会相撞 |
| R6 | 撤销切断在途连接 | 唯一的连接级收尾是断开：`connectionClosed → execution.ownerLost`（RuntimeService.swift:169；ExecutionCoordinator.swift:248）；全代码没有 revoke、policyEpoch、心跳（`grep -i "revok\|policyEpoch\|heartbeat"` 只命中两处注释） | 撤销后同一条连接仍可继续发请求；没有按 principal 找出并停止其 Delegated Run 的路径 |
| R7 | 错误码 | `permission_denied` 用于非 owner 的 stopAll / attach（RuntimeService+Runs.swift:121、135；ExecutionCoordinator.swift:137）；`pairing_required`、`client_revoked`、`grant_*` 从未返回 | 码已命名、未使用 |

### 3. Client 与 ACP

| # | 项 | 现状与证据 | 差距 / 发现 |
| --- | --- | --- | --- |
| K1 | `RuntimeClient` 握手 | `SocketRuntimeClient.handshake()` 只发 `apiVersions` 与 `client`（AgentDesktopClient/RuntimeClient.swift:73–76）；`RuntimeIdentity` 模型无 principal（AgentDesktopProtocol/RuntimeModels.swift:56 起） | Client 无法递交凭据，也拿不到 principal（07 R4 第 2 项） |
| K2 | ACP 调用方 | `caller()` 返回 `local:<本进程 uid>` 占位，`verified: false`（ACPBridgeRuntimePort.swift:69–73）；`ACPCaller.verified` 注释写明 A4 前为 false（Ports.swift:53–59） | 行为正确；A4 后改为取 principal（07 R4「A4 之后 R 要改的」） |
| K3 | ACP requestId 派生 | 用 `local:<config.uid>`（ACPBridgeRuntimePort.swift:134），不取编辑器输入 | A4 后改用 `principal.clientId` |
| K4 | ACP 输入过滤 | `forbiddenInputKeys` 拒绝 `origin/lifetime/ownership/clientId/agentId/trusted/principal`（ACPTaskCatalog.swift:21–23）；`connectionId`、`principalId`、`credential` 不在表内，但会被 `unit_run_params` 校验拒绝、不发送（Mock 测试 B2 已证明） | 无漏洞；建议 R 线把这三个键也加进表，错误码更准确（`ownership_escalation_denied` 而非 `schema_invalid`） |
| K5 | ACP 会话隔离 | 列表、加载、关闭都比对 `principalId`，他人会话与不存在不可区分（ACPAgentServer.swift:177–180、193、292–296） | 行为正确；真实性取决于 principal 是否真实（A4） |
| K6 | ACP 调用方缓存 | `cachedCaller` 取到一次后整条编辑器连接复用（ACPAgentServer.swift:42、150–158） | 撤销由 Runtime 在每次请求时强制，所以不构成越权；但撤销后编辑器上的身份说明不会更新。A4 落地后 S 线应在收到 `client_revoked` 时清空缓存并提示 |
| **F-1** | **ACP 提交日志写入原始拒绝消息** | `ACPSubmissionLog` 把 Runtime 错误的 `message` 原样写入 `submissions.json`（ACPBridgeRuntimePort.swift:148–149） | **发现**：若某个认证错误的 message 回显了凭据，凭据会落盘。Mock 测试 `bridgeLogDoesNotStoreCredential` 已复现，按 known issue 记录。修复属 R 线（存 `ACPRedactor.redact` 后的文本或只存 code），不在本包范围 |

## 二、六项行为要求（Kevin 列出的测试要求）

每一项都有一组 Mock 测试（今天运行）和一个 Real 测试（已写好，`.disabled("waiting for A4: …")`）。文件：`Tests/AgentDesktopACPTests/Pending/A4/`。

| # | 行为 | Mock 测试（ACP 侧，今天通过） | Real 测试（未运行） | 对应用例 |
| --- | --- | --- | --- | --- |
| B1 | 未配对客户端不能授权 | 桥：`pairing_required` 是终局拒绝，同一提交重试只查日志、不再发 `unit.run`；桥在 Runtime 给出 principal 前从不报 `verified=true`；服务端：拒绝结束本轮（`refusal`），不绑定 Run，只提交一次；未认证身份如实告知编辑器 | 未配对 App 握手成功，`run.list / desktop.list / unit.run / hub.grants.set / hub.pairing.approve` 均为 `pairing_required` | HB-01；ACP-T15-02 |
| B2 | clientId 不能经请求参数伪造 | 桥：输入里的 10 个身份类键（含嵌套在 goal 里）一律本地拒绝，`unit.run` 发送 0 次；requestId 与 caller 只由 Runtime 侧身份派生；服务端：cwd 与 prompt 里的身份字符串不改变会话 principal | `run.list` 带他人 clientId 只回自己的 Run；`unit.run` 带 clientId 为 `schema_invalid` | ADR-05；ACP-T07-05 |
| B3 | 无效、过期、已撤销凭据被拒 | 桥：握手被拒（5 个码）时不产生 caller、只握手一次不重试，提交被拒且不发 `unit.run`；服务端：没有 caller 时 `session/new` 失败关闭，不存会话、不提交 | 随机凭据 `credential_invalid`；短期凭据过期后 `credential_expired`；撤销后 `client_revoked` | HB-04 |
| B4 | 不能跨客户端访问 Run | 桥：他人 Run 的 show / cancel 都是 `not_found`，Run 不受影响，ACP 不调 `run.list` 等旁路；服务端：他人会话的 list / load / close / prompt 与不存在的会话回复完全相同，且从不读取、跟随、取消其中的 Run | B 对 A 的 runId 做 show / cancel / events / subscribe 均为 `not_found`，列表不含；A 的 Run 不受影响 | HB-09、HB-12；ACP-T07-01～04、ACP-31-01～03 |
| B5 | 撤销后已有连接不能提交新动作 | 桥：撤销后新提交为 `client_revoked`，重试不重发；已受理的提交重试只能读回，读不到就是 `unconfirmed`，不报成功、不重发；服务端：撤销拒绝只显示一次，不自动重提、不换身份重试 | 撤销后**同一条仍打开的连接**上 `unit.run / run.start / act / observe / desktop.create` 均被拒；其 Delegated Run 进入 stopping 或 ended | HB-05、HB-13 |
| B6 | 认证失败不泄露凭据或敏感数据 | 服务端：拒绝消息里带凭据时，编辑器与会话存储都看不到（5 个码）；caller 失败用固定文案替换；**桥：提交日志会落盘（F-1，known issue）** | 无效凭据的错误 JSON 不含凭据，`details` 只有 `reason` | P1 裁决；05 §四.5 |

### 测试数量（本包）

| 层 | 测试函数 | 运行实例（含参数化） | 今天状态 |
| --- | --- | --- | --- |
| Mock | 18 | 43 | 全部通过；其中 1 个按 known issue F-1 记录（期望失败、已记录） |
| Real · not run | 6 | 6 | 全部 `.disabled("waiting for A4: …")`，编译但不运行 |

Mock 测试带标签 `.a4Mock`、名字以 `[Mock]` 开头；Real 测试带 `.a4Real`、名字以 `[Real·not run]` 开头。Real 测试只连测试自己启动的 Runtime 子进程（`ACP_TEST_RUNTIME_BINARY`，见 [12-test-runtime-isolation.md](12-test-runtime-isolation.md)），不接受外部给的端点或 PID，不碰产品端点。

## 三、ACP 侧必须保持的规则（Mock 测试守护）

1. 身份只取自 Runtime 的认证上下文；编辑器发来的 `cwd`、prompt、输入里的身份字段一律无效（README §四.3）。
2. `verified=false` 时如实告知，不说「已认证」；A4 落地前不得把占位身份当作认证结果。
3. 认证类错误（`pairing_required`、`client_revoked`、`credential_*`、`grant_*`、`permission_denied`）是**确定拒绝**：不重发、不换身份重试、不当作结果不明。
4. 结果不明（已受理后读不回）记 `unconfirmed`，不报成功、不重发（README §四.6）。
5. 认证错误展示给编辑器前经 `ACPRedactor`；会话存储只存脱敏文本；caller 失败用固定文案。

## 四、给 Runtime 负责人（f1）的开放问题

| # | 问题 | 为什么 ACP 需要答案 |
| --- | --- | --- |
| Q1 | 同一 uid 下，Runtime 如何区分「本机 owner」与「未配对 App」？今天 getpeereid 只能证明同用户（RuntimeServer.swift:190）。是靠握手里显式声明（本文 P1 的 `auth.scheme`）、owner 也需要主窗口签发的凭据、还是靠代码签名 callerFacts？ | 决定 B1 能否在本机成立；若「不声明就是 owner」，任何本机进程都能自称 owner |
| Q2 | `agentdesktop acp` 在 A4 之后是 owner 还是配对客户端？若是 owner，ACP 会话按 clientId 隔离（07 R4 第 3 项）就退化为全部 `local:<uid>`；若是配对客户端，配对由谁在何时完成，凭据存在哪（04 §4.2 写客户端存自己的钥匙串，测试副本用文件凭据） | 决定 T07、ACP-31 能否在本机验收，以及 ACP 是否需要配对流程 |
| Q3 | 凭据的期限与 Grant 的期限是一件事还是两件事？过期时返回 `grant_expired` 还是新码 `credential_expired`？HB-05 写撤权后为 `grant_missing`，errors.json 写客户端被移除为 `client_revoked`，两者的边界是什么 | ACP 对两类错误的提示不同（重新配对 vs 重新授权） |
| Q4 | 撤销对**已打开连接**的语义：Runtime 是对其后续请求逐个回 `client_revoked`、还是主动关闭连接？若关闭，ACP 会按断连（connection_scoped 收尾）处理，与「撤权不等于取消 Run」（04 §4.3）如何一致？是否推送一个事件（如 `client.revoked`）给订阅连接 | 决定 B5 的 Real 断言与 ACP 的断连处理路径 |
| Q5 | 撤销时其 Delegated Run 的 `closingReason` 用什么值（建议 `grant_revoked`）？在途动作是否等静止后再结束，结果不明的记 `unknown` | E 线投影与「结果未知 · 需要核实」展示 |
| Q6 | 请求账本与 Session 何时改为按 clientId 分区（今天按 uid，RuntimeService.swift:178、SessionManager.swift:36）？R7 的 `request.show` 在分区后对他人 requestId 是否也回 `not_found` | ACP 的重发判定（07 R7）依赖它 |
| Q7 | 测试副本能否提供短凭据期限（例如启动参数或环境变量），让过期用例在秒级完成？ | B3 Real 测试需要 |
| Q8 | 未配对连接可调的方法白名单是否只有 `runtime.handshake / status / capabilities / hub.pairing.start / hub.pairing.status`？`runtime.capabilities` 对未配对是否隐藏 `unit.run` | ACP 任务列表（T15-01） |
| Q9 | docs/plan/03-runtime-contract.md:28 把含 principal 的握手记为「已实现」，代码未实现（C1）。是否在 PR2b-2 或 PR3 里一并更正 | 文档与代码一致 |

## 五、契约形状提案（仅为提案，由 f1 决定）

以下全部是**提案**，本包不改 `contracts/`。Real 测试按这些形状写成，契约冻结后对齐。

### P1　握手参数增加可选 `auth`

```json
// runtime_handshake_params 增加（缺省 = 今天的行为：本机 owner）
"auth": {
  "scheme": "local_owner | client_credential",
  "credential": "string?"     // 仅 client_credential；不出现在任何日志、错误或账本里
}
```

- `client_credential` 且没有 `credential`：握手成功，结果里没有 `principal`（未配对），只能调 Q8 的白名单。
- `credential` 无效 → `credential_invalid`；过期 → `credential_expired`；客户端已被移除 → `client_revoked`。三者都在握手阶段返回，连接随后关闭。

### P2　握手结果带 `principal`（即 07 R4，补 `grants` 摘要）

```json
// RuntimeIdentity 增加
"principal": { "clientId": "local:501 | app:<id>", "role": "owner | paired",
               "connectionId": "conn_…", "grantsRevision": 3 }
```

### P3　新增错误码

| code | exitCode | phase | 说明 |
| --- | --- | --- | --- |
| `credential_invalid` | 4 | handshake | 凭据不存在、格式错或签名不符 |
| `credential_expired` | 4 | handshake | 凭据过期（若 Q3 决定与 `grant_expired` 合并，则不新增） |

约束：所有认证类错误（含 `pairing_required`、`client_revoked`、`grant_*`）的 `message` 为固定文案，`details` 至多 `{reason}`（固定枚举），不回显凭据、clientId 以外的主体或他人资源是否存在。

### P4　撤销对在途连接（回应 Q4 的建议）

- `hub.clients.revoke` 生效后，该 clientId 的每条已打开连接上，除 `runtime.status` 外的请求一律 `client_revoked`，连接不由 Runtime 主动关闭（避免与断连语义混淆）。
- 该 clientId 的 Delegated Run 进入 stopping，`closingReason: "grant_revoked"`；在途动作按 A3 规则静止，无法确认的为 `unknown`。
- 推送 `client.revoked`（data：`{clientId}`）给该 clientId 的订阅连接，ACP 据此清空身份缓存并提示。

### P5　账本与会话按 clientId 分区

`requestLedger.key` 改为 `principal.clientId + requestId`；`SessionManager` 按 clientId 归属。对他人的 requestId、sessionId 一律 `not_found`。

## 六、验收标准与依赖

### A4 视为完成（ACP 角度）的条件

1. P1～P5（或 f1 冻结的等价形状）进入 `contracts/runtime/v1`，`RuntimeClient` 能递交凭据并读到 principal。
2. 本包 6 个 Real 测试去掉 `.disabled` 后，在 `/tmp/adt-*` 测试副本上全部通过，退出码与输出存档到 `docs/acp/tests/evidence/`。
3. R 线完成 07 R4「A4 之后 R 要改的」三项，F-1 修复，`bridgeLogDoesNotStoreCredential` 的 known issue 消失（测试改为普通断言）。
4. Mock 测试继续保留，作为 ACP 侧回归。**只有 Mock 通过时，不得在任何门禁或 PR 里写 A4 完成。**

### 解除阻塞的门禁与用例（06-gates.md 第 139 行「A4 身份与授权」）

| 门禁 | 用例 | 除 A4 外还需 |
| --- | --- | --- |
| G1-09 无权限任务不可执行 | ACP-T15-01～03 | A6 `unit.run` |
| G2-01 创建、列表、恢复关联正确 | ACP-T06-05 | A6 |
| G2-02 无权恢复他人会话 | ACP-T07-01～05、ACP-31-02 | — |
| G2-08 Ask / Auto 不扩权 | ACP-T15-04 | PR4 inbox |
| G2-10 重连后查询先前 Run | ACP-30-01～03 | A6；Zed 手工 Z1 |
| G2-11 观察他人 Durable Run 须授权 | ACP-31-01～04 | 07 R5；A6；U7 |
| G3-02 Durable Run 只读观察 | ACP-T13-01～04、ACP-P2A-01、02 | A6；U7 |
| G3-11 半开连接 | ACP-T03-06 | A6；Runtime 心跳 |

ACP-T07-05（编辑器伪造身份字段）不依赖 A4：本包 B2 的 Mock 测试即其 L1 证据，可由 Q 线在 cases.csv 里引用（本包不改 cases.csv）。

### 依赖顺序

PR2b（07 R4：本机 owner principal 透出，`verified` 可置 true）→ PR3 / A4（配对、凭据、撤销、clientId 隔离）→ 本包 Real 测试启用 → 上表门禁逐项复核。
