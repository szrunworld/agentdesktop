# 窗口级授权（Window Grants）

依据：Kevin 2026-10-09 裁决「选择 B，坚持按窗口授权」。#137（A4）的应用级授权不能替代窗口级授权；本 PR 是 #143（物理窗口 Desktop）的前置 PR，在 A4 授权模型之上增加按窗口的 Observe / Act / Persist 授权。

**本 PR 不打开任何封印**：`physicalDesktopsEnabled` 仍为关、`bindsOnlyLaunchedProcesses` 仍为开、`refusesScreenCaptureWithoutBinding` 仍为开；产品里没有任何路径改变它们。窗口授权机制可独立于这些开关测试（测试用 `@testable` 翻开关覆盖物理 Desktop 和“绑定用户窗口”两条路径）。开关何时、如何打开，留给 #143 之后另行裁决。

## 原则

AgentDesktop 是通用执行平台，各 Agent 是独立客户端。**客户端只能操作用户明确授权的目标窗口**，拿到某个 App 的授权（`grant.apps`）不等于拿到它所有窗口。之后的 BOSS / WeChat 等 Agent 都复用这一套机制，不另建窗口授权。

## 哪些窗口需要窗口授权

对**已配对客户端**（paired）而言，一个窗口属于以下两类之一：

| 类别 | 判定 | 需要窗口授权 |
| --- | --- | --- |
| 自己启动的窗口 | 窗口所属进程是**这个客户端**用 `app.launch` 在**这个 Desktop** 上启动的那一次启动（pid + 启动时间） | 否：沿用 A4 的应用级授权（`grant.apps` + 能力）。这些是 Agent 自己的进程实例，不是用户的窗口 |
| 其他一切窗口 | 用户自己打开的窗口、别的客户端或 owner 启动/绑定的窗口、物理 Desktop 上的任何窗口 | **是** |

owner（宿主进程内的主窗口、GUI 端口、AI 服务）就是用户本人，不受窗口授权约束。

> 需要 Kevin 确认：“自己启动的窗口”沿用应用级授权（配对时用户已确认 App 列表）。若要求这类窗口也逐个确认，只需把判定改为“一律需要窗口授权”，机制不变。

## 授权记录

`hub.sqlite` 新表 `window_grants`，一条记录就是一个窗口授权：

| 字段 | 含义 |
| --- | --- |
| `windowGrantId` | `wg_<随机>`，Runtime 生成 |
| `clientId` | 被授权的客户端（A4 身份，来自握手凭据） |
| `desktopId` | 授权所在的 Desktop；只在这个 Desktop 上有效 |
| `window.windowId` | WindowServer 的窗口 ID |
| `window.process` | 进程身份：pid **+ 进程启动时间**（ProcessIdentity），即“哪一次启动” |
| `window.bundleId` / `appName` | 所属 App（系统给出，不是客户端自报） |
| `permissions` | `observe` / `act` / `persist` 的子集 |
| `state` | `active` / `revoked`（被撤销）/ `ended`（失效） |
| `endedReason` | 失效原因（见下文生命周期） |
| `createdAt` / `expiresAt` | 用户批准后起算；按绝对时间计，不晚于批准那一刻客户端授权的到期时间 |
| `confirmationId` | 用户确认的那一次（可在审计里对上） |

### 防止窗口 ID 复用

窗口 ID 不单独作为授权身份。每次使用都要求以下**全部**与记录一致：

1. 窗口 ID；
2. 进程身份（pid + 启动时间）：进程退出后 pid 被复用，启动时间不同，不匹配；
3. bundleId：同一 pid 换了程序（exec），不匹配；
4. Desktop 和 clientId。

而且失效是**粘滞**的：任何一次检查发现窗口已关闭、进程已变、App 已变，这条授权立刻标为 `ended`，以后即使出现同 ID、同进程的窗口也不会恢复。macOS 的 WindowServer 在一次登录会话内单调分配窗口 ID，不会把已关闭窗口的 ID 立即重新分配；粘滞失效再加一道保险：只要关闭被看到过一次，授权就不会被继承。

已知残余：如果窗口关闭后、在任何一次检查之前，同一进程的同一窗口 ID 被重新分配，检查无法区分。按 WindowServer 的分配方式，这在一次会话内不会发生；登出 / WindowServer 重启会让所有进程重启，进程身份不再匹配。

## 三种权限分离

| 权限 | 允许 | 不含 |
| --- | --- | --- |
| `observe` | 查看这个窗口：`observe` 的窗口截图和元素、`wait` 的元素轮询、`window.list` 列出它 | 截图的长期保存 |
| `act` | 向这个窗口发送输入：`act` | 查看 |
| `persist` | 把窗口内容保存下来：截图按正常期限（24 小时，或所在 Run 结束前）保留，窗口关闭后仍可读取 | 用户撤销授权后：客户端再也读不到在这条授权下保存的截图（owner 仍可读） |

- 申请时，每种权限都要求客户端授权里有对应能力：`observe` 和 `persist` 需要 `observe` 能力，`act` 需要 `act` 能力；`window.bind` 本身还需要 `desktop.manage`。
- **没有 `persist` 时**，`observe` 的截图仍然要写到文件才能交给客户端，但只作为**临时**文件：
  - 标记 `transient: true`，`expiresAt` 为 120 秒后；
  - 过期、授权被撤销或失效时立刻删除；不因所在 Run 未结束而保留；
  - 只有在授权仍有效且仍有 `observe` 时才能用 `artifact.show` / `artifact.read` 读到；
  - Runtime 重启时，上次留下的临时截图一律删除。
- 元素文字（标题、按钮、输入框内容）只在 `observe` / `wait` 的回复里出现，不写入请求账本、Run 事件、审计或日志。Run 事件和动作回执只含窗口 ID、坐标、元素引用，不含窗口内容。

## 申请与本人确认

新方法 `hub.windows.request`（已配对客户端）：

```json
{"desktopId": "d_…", "bundleId": "com.tencent.xinWeChat", "windowId": 12345,
 "permissions": ["observe", "act"], "durationSeconds": 3600}
```

- 前提：客户端授权有效，`desktopId` 在授权范围内，`bundleId` 在 `grant.apps` 里，每种权限都有对应能力。不满足时直接拒绝，不弹窗。
- `windowId` 可省略：省略时 Runtime 选这个 App 在该 Desktop 显示器上（物理 Desktop）或用户屏幕上（虚拟 Desktop，供之后绑定）的最前面的普通窗口。最终授权的就是确认窗口里展示的那一个。
- 找不到符合条件的窗口：`grant_missing`（reason `window_not_grantable`），不弹窗，不说明是窗口不存在还是不属于该 App。
- **每一次授权都要用户本人确认**，走 A4 的可信确认窗口（TrustedConfirmationWindow）+ LocalAuthentication（Touch ID / 登录密码），新增确认类型 `windowGrant`。窗口里显示：
  - 申请方（系统核实的代码身份在前，自报名称标为“自报”）；
  - 目标窗口：App 名、bundleId、窗口标题、位置大小、进程 pid、所在显示器；
  - Desktop：ID 和类型。物理 Desktop 额外警告“这是你自己屏幕上的真实窗口”；
  - 权限逐项写明（查看 / 操作 / 保存），以及期限。
  所有非 Runtime 核实的文字（标题、自报名称）一律惰性显示。默认按钮是“拒绝”。
- 确认结果绑定到展示内容的 digest：确认的是哪个窗口、哪些权限、多久，Runtime 就记录哪个。拒绝、取消、超时、无法验证身份：一律拒绝（`permission_denied`，reason 同 A4）。之后 60 秒内同一客户端不能再申请（`window_grant_cooldown`）。
- 用户确认期间窗口关闭或进程变化：确认后再核对一次，不一致则拒绝（`target_changed`），不记录授权。
- 代码身份未验证（`same_user`、`shared_interpreter`）的客户端也可以申请（与配对一致），确认窗口如实标出其身份级别。
- `hub.windows.list`：已配对客户端只看到自己的窗口授权；owner 看到全部。
- `hub.windows.revoke`：owner 直接撤销；已配对客户端按 A4 R1 规则，只能放弃**自己的**窗口授权，并且须经可信窗口确认。

CLI：`agentdesktop windows request|list|revoke`。

## 生命周期：何时拒绝后续访问

每次使用（bind、observe 的两个加锁阶段、wait 的每次轮询、act 投递前最后一刻、artifact 读取）都按**当前**状态检查。以下任何一项成立，访问即被拒绝：

| 事件 | 结果 | reason |
| --- | --- | --- |
| 窗口关闭（进程仍是同一次启动，但它的窗口列表里没有这个窗口；列表为空也算，因为被授权的可能是它唯一的窗口） | 授权 `ended`，粘滞 | `window_closed` |
| 进程退出或重启（pid + 启动时间不符） | `ended`，粘滞 | `process_changed` |
| 同一 pid 变成另一个 App | `ended`，粘滞 | `app_changed` |
| 用户撤销这条窗口授权 | `revoked`；该客户端所有连接被切断（同 A4 收窄） | `window_grant_revoked` |
| 客户端被移除 / 客户端授权被撤销 | 该客户端的全部窗口授权 `revoked` | `client_revoked` / `grant_revoked` |
| 客户端授权收窄，去掉了该 App 或该 Desktop | 相应窗口授权 `ended`，粘滞 | `app_removed` / `desktop_removed` |
| 客户端授权去掉了 `observe` / `act` 能力 | 对应权限立即不可用（按能力实时计算） | `window_*_not_granted` |
| 到期（窗口授权或客户端授权） | 拒绝 | `window_grant_expired` / `grant_expired` |
| Desktop 被销毁 | 该 Desktop 上的窗口授权 `ended` | `desktop_destroyed` |
| 客户端身份失效（代码身份不符、凭据无效） | 握手被拒，任何请求都无法到达 | A4 |

失效时，这条授权的临时截图立即删除。

## 最小可见

对已配对客户端：

- `window.list` 只返回：它持有有效窗口授权、且授权含 `observe` 的窗口（检查时已验证仍存活；列表会给出标题和位置，所以只有 `act` 不够），以及它自己启动的进程的窗口。**不再**返回 `grant.apps` 里 App 的其他窗口；按 pid 或 bundleId 查询也一样。
- `desktop.show` / `desktop.list` 里的 `binding`：调用方对绑定窗口没有访问权时显示为 `null`，不透露那是哪个 App 的哪个窗口。
- 同一 App 另一个窗口已授权，不会扩大到这个窗口：每个检查都按窗口 ID + 进程身份精确匹配。
- 拒绝信息不包含窗口标题、App 名或 pid 是否存在（沿用 #153 / SEC-05 的写法）。

## 每个入口的检查点

“绑定”只决定 Desktop 的目标窗口，**不代表**授权；每次使用都按调用方自己的窗口授权重新判定。这堵住了“owner 绑定了用户窗口，再把 Desktop 授权给客户端”这条路。

| 入口 | 检查 | 位置 |
| --- | --- | --- |
| `window.bind` | 需要该窗口的有效窗口授权（任一权限）且必须给出 `windowId`；自己启动的进程除外 | `bindWindow`，Desktop 锁内 |
| `observe` 截图 / 元素 | `observe`；拿锁后检查一次，存储前在锁内再查一次 | `observe` 第 1、3 步 |
| 截图长期保存 | 有 `persist` 才按正常期限保留，否则临时 | `observe` 写入 artifact 时 |
| `wait` | `observe`，每次轮询 | `wait` 锁内 |
| `act` | `act`，在投递边界前最后一刻（与 A4 `recheckAct` 同处） | `act` 锁内 |
| `artifact.show` / `artifact.read` | 临时截图：授权仍有效且有 `observe`，且未过期；保存的截图：授权未被用户撤销 | `visibleArtifact` |
| `window.list` | 只列含 `observe` 的有效授权窗口和自己启动的窗口 | `handle(.windowList)` |
| `desktop.show` / `desktop.list` | 绑定信息按调用方权限显示 | `desktopJSON(_:for:)` |
| MCP / ACP / CLI | 都是 runtime.sock 上的已配对客户端，走同一套检查，没有旁路 | — |
| GUI Run（`gui.runs.*`）、AI 服务 | 只属于宿主进程（owner），socket 上一律拒绝（A4） | — |
| 日志 / 账本 / Run 事件 | 不写窗口标题、元素文字或截图内容 | — |

## 审计

`auth_events` 新增以下记录，reason 中只有授权 ID 和权限名，不含窗口内容：

- 申请：`hub.windows.request` 的 `asked` / `confirmed` / `denied`（含用户拒绝、超时等）；
- 授予：`granted`（reason `wg_… observe,act`）；
- 每次使用：`window.observe` / `window.act` / `window.persist`，decision `used`；被拒为 `denied`，reason 为具体原因；
- 撤销与失效：`revoked` / `ended`，reason 为上表原因。

`used` 记录与拒绝记录一样计入总上限，可被清理；授予、撤销、失效等访问决定不会被清理（同 A4）。

## 测试

`Tests/AgentDesktopRuntimeTests/RuntimeWindowGrantTests.swift`：

- 同一 App 的两个窗口，只授权其中一个：另一个不能绑定、不能观察、不能操作、不出现在 `window.list`；
- Observe / Act / Persist 各自独立：只有 observe 不能 act，只有 act 不能 observe，没有 persist 时截图为临时、到期即删；
- 用户拒绝、取消、超时、无可信窗口：不产生授权；
- 窗口关闭、进程重启、同 ID 窗口重新出现：粘滞失效，不继承；
- 撤销窗口授权、移除客户端、撤销 / 收窄客户端授权、到期、Desktop 销毁：后续访问全部拒绝；
- owner 绑定的窗口 + Desktop 授权给客户端：客户端仍无法观察或操作；
- 封印开关保持原样：产品默认值不变（`physicalDesktopsEnabled == false`，`bindsOnlyLaunchedProcesses == true`）。

真机部分（Touch ID 确认）由 Kevin 本人执行：`scripts/window-grant-touchid-acceptance.sh`。它用测试副本、独立钥匙串文件，只打开并关闭一个自己的 TextEdit 实例。因为物理 Desktop 在产品里仍是关的，授权只能建在虚拟 Desktop 上，会创建一个虚拟显示器，所以脚本要求显式设置 `ALLOW_VIRTUAL_DISPLAY=1` 才运行。
