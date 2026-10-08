# A4 调用方身份认证与授权

范围：`runtime.sock` + `runtime/1` 上的调用方身份。这里不涉及第二个认证服务、GUI Runtime 或外部 Agent 托管，也不改 ADR v2.2 的 Delegated / Persistent Run 生命周期。审批 / 提问 UI 属于 PR4；本阶段由 owner 通过 CLI（`agentdesktop agents …`）或 runtime/1 的 `hub.*` 方法审批。

## 身份模型

| Principal | 如何得到 | clientId |
| --- | --- | --- |
| owner | 进程内连接（主窗口、GUI 端口、测试），或 socket 连接在握手时出示 owner 凭据（`<records>/owner.credential`，0600，Runtime 首次启动时以 O_EXCL 创建）。**这个文件会导致同用户进程提权，见 `a4-credential-assessment.md` F1，方案待裁决** | `local:<uid>` |
| paired | socket 连接在握手时出示配对得到的凭据 | `app:<随机 id>`，每个独立 Agent 一个 |
| unpaired | socket 连接未出示凭据 | `unpaired:<connectionId>` |

- 身份**只**来自握手凭据，由 Runtime 校验（SHA-256 后常量时间比较）。请求里自报的 `clientId`（params、context）不属于 Request schema，会被 `schema_invalid` 拒绝，任何字段都不能改变调用方身份。
- 凭据格式为 `adt1_` + 32 字节随机数的 base64url。Runtime 只存哈希；明文只交给发起配对的那条连接一次（`hub.pairing.status`），之后再查也拿不到。
- 用户自己的 CLI 读取 owner 凭据（或 `AGENTDESKTOP_CREDENTIAL_FILE`）。`agentdesktop mcp` 从不使用 owner 凭据，只用 `--credential-file`。
- `session exec` 把启动者使用的凭据文件路径通过 `AGENTDESKTOP_CREDENTIAL_FILE` 传给子进程：子程序是启动者自己的代码，以同一身份调用。

## 配对

1. App 用未配对连接调用 `hub.pairing.start`（agentName、publisher、requested：capabilities / desktops / apps / durationSeconds），拿到 pairingId 和 6 位短码。等待窗口为 600 秒；Runtime 重启后，尚未审批的配对一律过期。
2. owner 核对短码后 `hub.pairing.approve`（授予的范围只能是请求范围的子集，时长默认 1 小时、最长 7 天），或用 `hub.pairing.deny` 拒绝。
3. App 在**同一连接**上轮询 `hub.pairing.status`，取回凭据（只给一次），然后用新连接带凭据握手。

SDK：Python `RuntimeClient.pair(...)`，TypeScript `client.pair(...)`；CLI：`agentdesktop agents pair --name … --out <file>`。

## 授权（默认拒绝）

- unpaired 只能调用：`runtime.handshake`、`runtime.capabilities`、`hub.pairing.start`、`hub.pairing.status`。其余一律返回 `pairing_required`。
- paired 默认只有 `runtime.status`，其余按 grant：
  - `observe`：desktop/app/window 列表、observe、wait、artifact、session.show、request.show；
  - `act`：act、session.open/close；
  - `desktop.manage`：desktop create/destroy、app.launch、window bind/unbind；
  - `run`：run.\*、events.\*；
  - `unit.run`。
- Desktop 范围：`grant.desktops` 里列出的 id，或 `"created"`（自己创建的 Desktop）。App 范围：`grant.apps`（app.launch、window.bind 时检查 bundleId）。
- `desktop.create` 带 `physical`（挂接用户自己的显示器、原地绑定用户窗口）只允许 owner 调用，配对 App 调用时返回 `permission_denied`（reason `owner_only`，审计 reason 为 `physical_display`）；owner 可以把某个 physical Desktop 的 id 明确写进 App 的 grant。
- 其他方法（`hub.*` 管理、`runtime.stopAll`、工作区、设置……）只属于 owner，返回 `permission_denied`，reason 为 `owner_only`。
- 列表按调用方过滤：paired 只看到自己有权限的 Desktop、自己的 Run、自己的请求。
- 别人的 session / Run / requestId 对调用方而言“不存在”（`not_found`），这次尝试会写进审计（reason `foreign_session` / `foreign_run` / `desktop_out_of_grant`）。请求账本和 session 都按真实 clientId 分隔：两个 App 用同一个 requestId 互不影响，也不会重放对方的结果。
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

**凭据隔离未通过安全验收**：同用户普通进程可以读取 owner 凭据和 App 凭据文件（实测可以提权为 owner）。实测结果、各类客户端能达到的隔离级别和推荐方案见 `docs/security/a4-credential-assessment.md`，等待 Kevin 裁决。

- callerFacts（pid、可执行文件路径）只做记录和审批时展示，不参与认证。
- 配对短码靠 owner 人工比对；在 PR4 的审批 UI 上线之前，审批只能通过 CLI 进行。
