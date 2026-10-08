# 4 Agent Hub 接入

依据：ADR v2.2 第一至三节；Hub v1 执行方案第 3、6–10 节；BOSS Agent 方案第 9 节（消费方需求）。

## 4.1 边界

| 对象 | 负责 | 不负责 |
| --- | --- | --- |
| 外部 Agent App | 自己的 UI、业务任务、模型、账号、数据、进程与生命周期 | 绕过 Runtime 操作桌面；自批平台权限 |
| Agent Hub（平台模块） | 登记、配对与认证、能力授权、连接管理、平台 Run 管理、审批 Inbox、诊断 | 启动、托管、重启或终止外部 App |
| Runtime | 身份核验、授权判定、控制租约、动作执行、动作与 Run 回执、恢复 | 业务判断 |

平台空生态也必须可启动：零已连接 Agent、无业务包、无模型 key 时，Desktop、Agents 页面与诊断可用。

## 4.2 配对与认证

```
用户在 Agents › 接入应用 打开配对窗口（本机 owner 行为，默认 10 分钟；是否需要单独方法在 PR3 定稿）
外部 App 经 SDK 发起 hub.pairing.start {agentName, publisher, requested{capabilities, desktops, apps, duration}}，用 hub.pairing.status 等待结果
Runtime 记录 callerFacts（连接对端 pid、代码签名、可执行路径）与 callerClaims（自报）分开存
UI 同时显示双方短码；用户逐项勾选（只能勾请求方已请求的；Desktop 初始不选「所有」；期限默认 1 小时，可选 8 小时或最长 7 天）
owner 调 hub.pairing.approve（或 hub.pairing.deny）→ 签发 `clientId = app:<id>` 与客户端凭据（只交给发起配对的那条连接）
客户端此后每次 runtime.handshake 用凭据认证 → 得到 principal{clientId, grants 摘要}
```

- clientId 是平台签发的稳定主体（本机 owner 为 `local:<uid>`，配对 App 为 `app:<id>`，见冻结文档第 2 节）；agentName 只用于显示；connectionId 每次连接重建。
- 凭据存平台安全存储；客户端侧存其自己的钥匙串。测试副本用文件凭据，不写登录钥匙串。
- 未配对连接只能调用 handshake、capabilities、pairing.request；其他方法返回 `pairing_required`。
- 首发只接本机同一用户的连接；远程与多租户不在本版。

## 4.3 授权

- Grant 字段：能力（observe、act、app.launch、unit.run 等）、Desktop 范围、目标应用、期限、限额。
- 判定在最终原生入口进行：每次动作按当前 `policyEpoch` 复核；收窄或撤销立即对后续动作生效（修复 HUB-B01：活跃任务捕获旧授权）。
- 撤权不等于取消单个 Run，更不等于退出外部 App；受影响的 Run 进入停止流程，UI 显示「应用仍在线；权限已撤销；N 个平台运行停止中」。
- 移除登记是软删除：不卸载 App，不删账本；存在活跃执行时保留其跟踪项。

## 4.4 连接与 Run

| 事件 | 处理 |
| --- | --- |
| 外部 App 连接并 `run.start` | 建 Delegated Run（agent_hub / external_client / connection_scoped），带 clientId 与 connectionId |
| 心跳超时 | Connection 进入 heartbeat_stale，暂停新输入；超出检测窗口进入 disconnected |
| 控制连接确认失效或进程退出 | 立即拒绝新输入；Run 进入 stopping，在途动作结束后 ended（owner_lost）；无法确认的动作为 unknown |
| 外部 App 重连 | 新 connectionId；旧 Run 不恢复；App 用新 requestId 重新发起 |
| 用户关闭 Agents 页面或 UI 订阅断开 | 不影响任何 Run |
| 外部 App 请求 platform_durable | `ownership_escalation_denied`，不建 Run（已实现） |

ActiveExecutionRegistry 独立于登记与配置表，直到真实输入静止才摘除（修复 HUB-B02）。unknown、intent、阻断持久化，跨 Run、重连、重启都不自动重放（修复 HUB-B03、B04）。

## 4.5 审批（P1）

- 平台审批只针对平台能力上的具体动作：permit 绑定规范化指纹、目标、代次与期限，一次消费。
- 业务审批（发不发消息、联系谁）属于外部 App，只以引用跳转。
- 等待审批时客户端退出：挂起请求立即失效（修复 HUB-B06）；迟到回答零输入。

## 4.6 页面（详见 06 文件）

首发：Agents › 总览（W01）、接入应用（W02）、Agent 详情与授权（W03），Runs › 全部运行（W04）、运行详情（W05）。第二批：Inbox（W06）、Settings › 核实（W07）、诊断与用量（W08）。页面数据只来自正式 Client 的快照与事件游标；服务离线显示带同步时间的缓存并禁止变更；不回退样例数据。

## 4.7 外部 App 接入示例（中性）

`examples/neutral-agent`（Python，经 SDK）：配对 → 列出被授权的 Desktop → 观察 → 动作 → 正常结束；以及断开、重连、撤权三个分支。它是 Hub 的验收客户端，不包含任何业务逻辑。BOSS 等业务 App 用同一 SDK 自行接入，平台不为其加任何特殊判断。
