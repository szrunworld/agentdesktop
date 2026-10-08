# A4 调用方身份认证与授权

范围：`runtime.sock` + `runtime/1` 上的调用方身份。这里不涉及第二个认证服务、GUI Runtime 或外部 Agent 托管，也不改 ADR v2.2 的 Delegated / Persistent Run 生命周期。完整的审批 / 提问 UI 属于 PR4；本 PR 只提前实现了一个最小的可信确认窗口（Kevin 2026-10-09 批准）。

## 身份模型

| Principal | 如何得到 | clientId |
| --- | --- | --- |
| owner | **只有**宿主 App 进程内的连接（主窗口、GUI 端口、AI 服务）。任何 socket 客户端都不是 owner：没有 owner 凭据文件、环境变量或 token；在 socket 上声称 `local:<uid>` 一律返回 `permission_denied`（reason `owner_not_on_socket`）。旧版本留下的 `<records>/owner.credential` 会在启动时删除。 | `local:<uid>` |
| paired | socket 连接在握手时出示配对得到的凭据；配对时绑定了代码身份的客户端，还必须满足它的 designated requirement | `app:<随机 id>`，每个独立 Agent 一个；CLI 也是其中之一 |
| unpaired | socket 连接未出示凭据 | `unpaired:<connectionId>` |

- 身份**只**来自握手凭据和内核给出的对端信息，由 Runtime 校验（token 以 SHA-256 存储、常量时间比较）。请求里自报的 `clientId`、`teamId`、`codeIdentity` 等字段不属于 Request schema，会被 `schema_invalid` 拒绝，任何字段都不能改变调用方身份。
- 凭据格式为 `adt1_` + 32 字节随机数的 base64url。Runtime 只存哈希；明文只交给发起配对的那条连接一次（`hub.pairing.status`），之后再查也拿不到。
- 测试可以给 Runtime 注入一个 socket owner token（`testSocketOwnerToken`），用于在 socket 上测试 owner 方法。产品代码（`RuntimeService.persistent`、宿主 App）从不设置它，有测试锁定这一点。

### 代码身份（S2）

Runtime 在接受连接时，通过 `LOCAL_PEERTOKEN` 取得对端进程的内核 audit token，再用 Security 框架读取它的签名信息（不信任客户端发来的任何内容）：

| 级别 | 条件 | 效果 |
| --- | --- | --- |
| `verified` | 签名有效、有 Team ID、开了 hardened runtime、不是 ad-hoc | 配对时记录 designated requirement；之后每次握手，对端都必须满足它，否则返回 `permission_denied`（reason `code_identity_mismatch`）。凭据被复制到别的程序后无法使用 |
| `shared_interpreter` | 同上，但是 python / node 等解释器 | 同样绑定，但这个解释器运行的任何脚本都共享此身份 |
| `same_user` | 其余情况（ad-hoc、自签名、无 hardened runtime，例如 Homebrew 的 node / python、当前未签发 Developer ID 的本产品 CLI） | 不绑定。只能确认是本机同一用户的进程；确认窗口会如实写明 |

握手结果的 `principal.codeIdentityLevel`、`HubClient.codeIdentity` / `HubPairing.codeIdentity` 中都能看到这个级别。

### 凭据存放（S3）

- CLI（包括 `agentdesktop mcp`）把凭据存进钥匙串（service `com.agentdesktop.client-credential`，account `<endpoint>|<profile>`，profile 默认为 `cli`，MCP 默认为 `mcp`）。不写文件，不进环境变量或命令行。条目的访问列表只信任创建它的程序；其他程序读取时，系统会询问用户。
- 测试使用内存存储；测试副本可以用 `AGENTDESKTOP_KEYCHAIN` 指定 `/tmp` 下的独立钥匙串文件，不碰登录钥匙串。
- Python / TS SDK 仍然由调用方自行决定是否把凭据写入 0600 文件（`save_credential`）。这只有同用户级别的保护，文档中已注明；签名 App 应使用钥匙串。
- `session exec` 不再给子进程传任何凭据。用 CLI 写的子程序会使用同一个钥匙串 profile；用 SDK 写的子程序需要自己配对。

## 可信确认（S1）

以下操作必须由用户在宿主 App 的可信窗口里确认：
- **配对**：App 调用 `hub.pairing.start` 后，宿主弹出确认窗口。窗口显示申请方名称、Runtime 读到的代码身份、程序路径和 pid、配对码，以及要授予的权限、Desktop / App 范围和期限。
- **配对客户端请求的 owner 方法**：`runtime.stopAll`、`runtime.enableInput`、`ai.*`、`hub.clients.*`、`hub.grants.*`、`hub.connections.list`。每次调用都单独确认，窗口显示方法和完整参数。

确认规则：
- 默认按钮是「拒绝」（Return / Escape 都是拒绝）。点「批准…」之后，还要通过系统的用户身份验证（Touch ID 或登录密码，LocalAuthentication）。别的进程即使能用辅助功能点按钮，也无法替用户完成这一步。
- 拒绝、取消、120 秒内未回答、无法进行身份验证、没有可信窗口：一律拒绝（`permission_denied`，reason 分别为 `user_denied`、`user_cancelled`、`confirmation_timeout`、`no_trusted_ui`）。不会降级为自动同意。
- 确认结果绑定到申请内容的摘要（digest）：批准的必须正好是展示的那份授权或参数（`confirmation_mismatch`）。配对得到的 grant 与展示的完全相同，期限从批准时刻起算。
- 同一时间只显示一个确认窗口，最多排队 3 个，每个客户端最多一个在等（`confirmation_busy`），防止弹窗轰炸。
- 批准的 owner 调用只对这一个请求有效：这个请求结束后，连接立即回到普通权限。
- 不能自己授权自己：`hub.pairing.approve` / `deny` 只有宿主进程内才能调用（socket 上一律 `owner_only`）；对自己的 clientId 调用 `hub.grants.set` / `revoke` 直接拒绝（`self_grant`），不弹窗。
- 没有可信窗口时（例如没有设置 confirmer 的测试 Runtime），配对保持待定，只有宿主进程内的 owner 能决定，否则到期失效。

## 授权（默认拒绝）

- unpaired 只能调用：`runtime.handshake`、`runtime.capabilities`、`hub.pairing.start`、`hub.pairing.status`。其余一律返回 `pairing_required`。
- paired 默认只有 `runtime.status`，其余按 grant：
  - `observe`：desktop/app/window 列表、observe、wait、artifact、session.show、request.show；
  - `act`：act、session.open/close；
  - `desktop.manage`：desktop create/destroy、app.launch、window bind/unbind；
  - `run`：run.\*、events.\*；
  - `unit.run`。
- Desktop 范围：`grant.desktops` 里列出的 id，或 `"created"`（自己创建的 Desktop）。App 范围：`grant.apps`（app.launch、window.bind 时检查 bundleId）。
- `desktop.create` 带 `physical`（挂接用户自己的显示器、原地绑定用户窗口）只允许 owner 调用，配对 App 调用时返回 `permission_denied`（审计 reason 为 `physical_display`）。
- 可确认的 owner 方法见上一节；其余 owner 方法（如 `gui.runs.*`、`hub.pairing.approve/deny`）只属于宿主进程内，socket 上返回 `permission_denied`，reason 为 `owner_only`。
- 列表按调用方过滤：paired 只看到自己有权限的 Desktop、自己的 Run、自己的请求。
- 别人的 session / Run / requestId 对调用方而言“不存在”（`not_found`），这次尝试会写进审计（reason `foreign_session` / `foreign_run` / `desktop_out_of_grant`）。请求账本和 session 都按真实 clientId 分隔。
- 每个请求都按 client 和 grant 的**当前状态**检查；act 在输入真正发出前再检查一次（`recheckAct`）。

## 过期、收窄与撤销

统一规则：**任何持续执行的操作，在整个执行期间都受授权约束**，不是只在请求开始时检查一次。

| 操作 | 撤销 / 撤销授权 / 收窄之后 | 过期之后 |
| --- | --- | --- |
| 新的 RPC 请求 | 立即拒绝（`client_revoked` / `grant_missing`），握手也一样 | `grant_expired` |
| 同一连接上排在后面、尚未执行的请求 | 执行前按当时的状态检查，被拒绝；而且连接已被切断，不会再有回复 | 执行前检查，被拒绝 |
| 已打开的事件订阅 | 连接被切断，之后不再发送任何事件 | 推送前每一轮都检查；失效后关闭连接，写入审计 |
| 进行中的 `wait` | 每次轮询都检查，立即返回错误；轮询中途读到的结果不返回 | 同左 |
| 进行中的 `run.wait`、`observe` 等读请求 | 回复前再检查一次（审计 decision 为 `withheld`），返回错误而不是数据 | 同左 |
| 已投递的写操作（act 等） | 回复的是已经发生的事实（账本记录）；投递前的最后一次检查（`recheckAct`）会拦下尚未投递的动作 | 同左 |
| 正在执行的 Run | 按 ADR v2.2 生命周期立即停止：`client_revoked` / `grant_revoked` / `grant_narrowed`（收窄时只停新范围外的 Run）；已有 Run 内的新动作被拒 | 新动作被拒；Run 由断连或 owner 处理 |
| 撤销后重连 | 旧凭据永久失效；重新配对得到新的 clientId | 续期后用原凭据重连 |
| 扩大授权 | 不切断连接 | 不涉及 |

### 撤销的线性化边界

`hub.clients.revoke`、`hub.grants.revoke`，以及收窄范围的 `hub.grants.set`，按以下顺序执行：
1. 写入数据库：从此刻起，新请求和握手都会被拒绝；
2. **切断**该 App 的所有已打开连接：先 `shutdown` socket，让正在写出的数据失败；再在每个连接的发送闸门下标记为已切断。所有回复和事件帧都必须经过这个闸门才能写出；
3. 停止它的 Run，关闭它的 session，写入审计（decision 为 `cut`）。

owner 的调用返回时，第 2 步已经完成：**此后该 App 的连接上不会再开始任何写出**；Run 停止时产生的事件也不会发给它。已经写进内核发送缓冲区的数据无法追回，这是边界之外的部分。

过期没有 owner 动作作为分界点，边界就是「检查时刻」：每次轮询、每帧推送、每个回复之前都会对照当前时间检查。检查通过的那一份数据可能在过期后几毫秒内才写出，不会有更多。

测试：`RuntimeRevocationTests`（A4-SEC-01 / 02）。其中「检查 → 读取帧 → 写出」的竞态是用测试检查点确定性复现的：先停在检查之后，此时撤销并产生新事件，再放行，验证这些事件一个都不会被发出。变异测试确认：去掉切断后该测试失败，去掉 wait 的轮询检查后 wait 测试失败。

## 断连

连接断开时，它拥有的 connection_scoped（Delegated）Run 按原有 ADR v2.2 规则以 `owner_lost` 结束。投递结果未知的动作保持 `unknown`，Run 的 outcome 也是 `unknown`；同一 App 重连后用同一 requestId 重试，得到的仍是 `action_delivery_unknown`，不会重发。

## 审计

`hub.sqlite` 的 `auth_events` 表记录：时间、connectionId、真实 clientId（握手失败时记录**声称的** clientId）、method、runId、decision（requested / approved / denied / revoked / granted）、reason。会记录的事件包括：所有拒绝（握手失败、`pairing_required`、`owner_only`、grant 外、他人目标）、配对申请 / 批准 / 拒绝、grant 变更、撤销。

## 接入要求

ACP bridge、BOSS Agent、WeChat Agent 都是外部 App，必须各自配对并持有自己的凭据文件，不能使用 owner 凭据。MCP 宿主使用 `agentdesktop mcp --credential-file <file>`。

## 已知限制

- 隔离级别取决于客户端的代码身份（见「代码身份」一节）：`same_user` 级别的客户端，凭据被同用户进程复制后仍可使用；这类客户端在确认窗口里会如实标出。本产品 CLI 要到 S4（Developer ID + hardened runtime）之后才能达到 `verified`。
- 能调试或注入其他进程的程序（root、关闭 SIP、`get-task-allow`、用户授予的高级权限），以及用户自己在钥匙串里点了「始终允许」、或在确认窗口里批准了不该批准的申请，都超出应用层能防御的范围。
- callerFacts（pid、可执行文件路径）只做展示，不参与认证；参与认证的是内核 audit token 对应的代码签名。
- 详见 `docs/security/a4-credential-assessment.md`。
