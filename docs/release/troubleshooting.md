# 故障场景

先跑 `agentdesktop doctor`：它只读，不启动任何东西、不建 Run、不写审计。`--format json` 时每项检查带 `id`、`status`（ok / warn / fail / skip）和失败的 `code`。

所有错误都是同一个信封：`error.code` 是稳定的机器接口（契约 `contracts/runtime/v1/errors.json`），退出码只是粗分类。`notSent: true` 表示请求没有发出，可以放心重试；`notSent: false` 的写操作不要盲目重发，见退出码 9。

## 退出码 3：Runtime 不在线

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `runtime_offline`，`doctor` 的 `endpoint.socket` 为 fail「nothing is listening」 | Agent Desktop 没在运行 | `agentdesktop runtime start`（只会启动已安装的产品并等握手；对 `--endpoint` 指定的别处端点会拒绝） |
| `runtime start` 返回 `wait_timeout`（退出码 8） | App 启动了但 20 秒内 Runtime 没应答 | 看菜单栏图标是否出现；`/usr/bin/log show --last 2m --predicate 'process == "Agent Desktop"'`；用 `--wait-timeout` 加长 |
| 宿主被强杀后残留 socket | 上次进程没清理 | 不需要手动删：再次启动会接管残留 socket；CLI 在此期间如实返回 3 |

## 退出码 4：权限与授权

| 错误码 | 含义 | 处理 |
| --- | --- | --- |
| `pairing_required` | 本程序还没配对 | `agentdesktop agents pair …`，在弹出的确认窗口确认（[安装 §5](install.md#5-配对)）。MCP 用 `--profile mcp` 单独配对 |
| `grant_missing` | 能力、Desktop 或应用不在授权里 | 重新申请更大的授权；写操作若已执行，`details.recovery` 为 `look_up_same_request_id`，用 `request show` 查结果，不要重发 |
| `grant_expired` | 授权到期 | 重新配对或延长授权；处理同上 |
| `client_revoked` | 本程序已被移除 | 重新配对；若 `details.recovery` 为 `check_outcome_do_not_resubmit`，先查结果再决定 |
| `permission_denied` | 端点不属于当前用户 / 目录别人可写，或缺系统权限 | `doctor` 指出具体项：`permission.screenRecording`、`permission.accessibility` 去系统设置授予 Agent Desktop；`endpoint.directory` fail 时修目录权限，CLI 在修好前不会连接 |
| `permission_denied` / `owner_only` | 物理显示器的 attach/detach 只能由主人在主窗口做 | 在 Agent Desktop 主窗口 Desktops › 开放我的显示器（Touch ID） |
| `permission_denied` / `iphone_mirroring_blocked` | iPhone 镜像不对 Agent 开放 | 首发不支持 |
| `ownership_escalation_denied` | 客户端要平台所有权或持久生命周期 | 客户端只能建 Delegated Run（ADR v2.2），改用 `session exec` 或 `run.start` |

换了签名证书（例如开发包换正式包）后，`doctor` 的两项权限会重新变成未授予：系统把授权绑定在证书上，需要重新勾选。

## 退出码 5：状态冲突

| 错误码 | 含义 | 处理 |
| --- | --- | --- |
| `control_busy` | 另一个控制者持有这个 Desktop（包括人工接管） | 等对方交还，或换一个 Desktop |
| `stale_observation` | 快照与目标不再一致（窗口移动、重新绑定、进程重启、元素重编号） | 重新 `observe`，用新的 `snapshotId` 再 act；输入没有发出 |
| `target_moved` | 发送前复核发现几何或绑定代次变了 | 同上 |
| `idempotency_conflict` | 同一个 requestId 带了不同内容 | 新请求用新的 `--request-id` |
| `conflict` | 状态不允许，例如 Desktop 上还有打开的 Session 时 destroy | 先 `session close`，再 `desktop destroy` |
| `run_not_active` | Run 已取消或结束 | 开新 Run |
| `input_disabled` | 有人执行了全部停止（`runtime stop-all`） | 由主人 `runtime enable-input` 或在主窗口恢复后再继续 |
| `stop_pending` | Run 正在停，输入未静止 | `run wait` 或 `run cancel --wait` 等它静止 |
| `limit_exceeded` | 步数、时长、预算或配额到上限 | 调整限额或拆分任务 |

## 退出码 6：版本与能力

| 错误码 | 含义 | 处理 |
| --- | --- | --- |
| `version_mismatch` | CLI 与 Runtime 没有共同的 API 版本 | 使用同一个包里的 CLI（`doctor` 的 `version` 一项会显示两边版本） |
| `instance_mismatch` | 端点应答了，但不是 Agent Desktop Runtime | 检查 `--endpoint` / `AGENTDESKTOP_ENDPOINT` 指向 |
| `capability_missing` | 方法或选项没有提供 | `runtime capabilities` 看实际提供的方法。最常见：`unit run` 需要先开启 GUI 执行器（`defaults write com.agentdesktop.app guiExecution -bool true` 并重启） |
| `unsupported_backend` | macOS 后台做不了这个动作 | 拖拽（`background_drag_unsupported`）、悬停（`background_hover_unsupported`）首发不支持 |
| `model_unavailable` | 需要模型但没配置 | 在设置里配置模型连接 |

## 退出码 7：已知失败

| 错误码 | 含义 | 处理 |
| --- | --- | --- |
| `execution_failed` | 单元或任务已知失败，可能有副作用 | `run show <runId>` 和 `run events` 看过程，按观察结果决定是否重做 |
| `audit_unavailable` | 证据写不进去，输入暂停直到恢复 | 检查磁盘空间与数据目录权限（`~/Library/Application Support/AgentDesktop/runtime/`） |
| `internal_error` | 只读请求处理出错 | 收集 `doctor --format json` 与系统日志反馈 |

## 退出码 8：等待超时

`wait_timeout`、`deadline_exceeded`：本地等待到点，服务端状态不变。`run wait`、Ctrl-C 只停本地等待，不取消 Run；要停 Run 用 `run cancel`。

## 退出码 9：结果未知

`connection_lost`、`request_acceptance_unknown`、`action_delivery_unknown`：请求发出后没有完整应答，**不要换 requestId 重发**。

1. `agentdesktop request show <requestId>` 回查（未指定 `--request-id` 时，CLI 发送前把生成的 requestId 记在 `~/Library/Application Support/AgentDesktop/cli/requests.jsonl`）；
2. 或用同一个 `--request-id` 重试：Runtime 对同一请求只执行一次；
3. 动作结果未知时，先 `observe` 看界面实际状态再决定下一步。

## 退出码 2：参数

`invalid_argument`、`schema_invalid`、`frame_too_large`、`not_found`、`invalid_target`：请求没有执行。`agentdesktop help <命令>` 看参数；`not_found` 多是 ID 过期（Desktop 已销毁、Session 已关闭）。

## 安装与启动

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 双击提示「无法打开」/「无法验证开发者」 | 开发包未公证，下载后被 Gatekeeper 隔离 | 见 [安装 §2](install.md#2-安装)；正式版本公证后不会出现 |
| 打开后没有窗口、Dock 没图标 | 菜单栏应用 | 从菜单栏图标打开主窗口 |
| 退出时提示还有 Run 在运行 | 退出要等输入静止 | 等它完成，或先停止这些 Run 再退出 |
| 两个 Agent Desktop 同时运行 | 端点有单实例锁 | 第二个不会接管已在服务的端点；`doctor` 的 `endpoint.owner` 显示当前持有者 pid |
