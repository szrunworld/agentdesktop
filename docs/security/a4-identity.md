# A4 调用方身份认证与授权

范围：`runtime.sock` + `runtime/1` 上的调用方身份。这里不涉及第二个认证服务、GUI Runtime 或外部 Agent 托管，也不改 ADR v2.2 的 Delegated / Persistent Run 生命周期。审批 / 提问 UI 属于 PR4；本阶段由 owner 通过 CLI（`agentdesktop agents …`）或 runtime/1 的 `hub.*` 方法审批。

## 身份模型

| Principal | 如何得到 | clientId |
| --- | --- | --- |
| owner | 进程内连接（主窗口、GUI 端口、测试），或 socket 连接在握手时出示 owner 凭据（`<records>/owner.credential`，0600，Runtime 首次启动时以 O_EXCL 创建） | `local:<uid>` |
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

| 情况 | 结果 |
| --- | --- |
| grant 到期 | 之后的请求返回 `grant_expired`，owner 用 `hub.grants.set` 续期 |
| `hub.grants.set` 收窄范围 | policyEpoch 加 1；新 grant 不再覆盖的 Desktop 上的 Run 立即停止（`grant_narrowed`） |
| `hub.grants.revoke` | client 保留，但请求返回 `grant_missing`，它的 Run 停止（`grant_revoked`） |
| `hub.clients.revoke` | 软删除；已打开的连接从下一个请求起返回 `client_revoked`，包括向已存在 Run 发送的新动作；它的所有 Run 停止（`client_revoked`）；旧凭据握手返回 `client_revoked`；重新配对得到新的 clientId |
| 撤销 / 过期 / 收窄时已打开的事件流 | 推送循环每轮都检查访问权限：一旦失效，不再推送任何事件，连接被关闭，并写入审计（`events.subscribe` denied） |
| 进行中的 `wait` | 每次轮询都会重新检查，失效后立即返回对应错误，不会等到超时 |

## 断连

连接断开时，它拥有的 connection_scoped（Delegated）Run 按原有 ADR v2.2 规则以 `owner_lost` 结束。投递结果未知的动作保持 `unknown`，Run 的 outcome 也是 `unknown`；同一 App 重连后用同一 requestId 重试，得到的仍是 `action_delivery_unknown`，不会重发。

## 审计

`hub.sqlite` 的 `auth_events` 表记录：时间、connectionId、真实 clientId（握手失败时记录**声称的** clientId）、method、runId、decision（requested / approved / denied / revoked / granted）、reason。会记录的事件包括：所有拒绝（握手失败、`pairing_required`、`owner_only`、grant 外、他人目标）、配对申请 / 批准 / 拒绝、grant 变更、撤销。

## 接入要求

ACP bridge、BOSS Agent、WeChat Agent 都是外部 App，必须各自配对并持有自己的凭据文件，不能使用 owner 凭据。MCP 宿主使用 `agentdesktop mcp --credential-file <file>`。

## 已知限制

- 同一 uid 下的恶意代码可以读取 `owner.credential`，以及其他 App 的凭据文件。A4 防的是 App 之间的冒充和越权，不防同用户的恶意本地代码；后者需要钥匙串 / 签名校验，留待后续。
- callerFacts（pid、可执行文件路径）只做记录和审批时展示，不参与认证。
- 配对短码靠 owner 人工比对；在 PR4 的审批 UI 上线之前，审批只能通过 CLI 进行。
