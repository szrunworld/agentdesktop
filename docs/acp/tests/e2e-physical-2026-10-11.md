# W1–W13 真机续测：物理 Desktop（2026-10-11）

测试副本：独立的 `Agent Desktop.app`、Runtime 数据目录和 socket；桥为同一 worktree 构建的 `agentdesktop-acp-dev`，配对凭据保存在 macOS Keychain 的 `acp` profile。测试使用独立 Calculator 窗口。窗口确认、配对确认和 Touch ID 均由 Kevin 操作。此记录是 PR #268 首轮报告的续测；部分场景跨测试副本执行，不能当作 W1–W13 全通过。

| 场景 | 结果 | 真机证据与边界 |
| --- | --- | --- |
| W1 | 通过操作链路 | 用户批准桥身份 `ACP-E2E` 的配对和物理显示器开放；Runtime 的 pairing 为 `approved`，物理 Desktop `d_8d82bc84e4a5` 授给桥 `app:ec7f050c32c0`。确认窗口内容由用户现场核对，未保存截图。 |
| W2 | 通过（首轮） | 缺少 `--desktops`、使用 `created` 均退出 2，未发请求。 |
| W3 | 部分通过 | fake editor 连真实 Runtime 时任务列表含 `unit-run`，没有桥的 `ai.profiles.list` 请求；隔离 Zed 打开 Agent Panel 后停在 Zed AI 登录页，未在 Zed 本身完成 `/help`。 |
| W4 | 通过 | 已绑定窗口、尚无窗口授权时，真实 `unit.run` 返回 `grant_missing` / `window_grant_missing`。 |
| W5 | 通过 | `request-window` 弹出 Calculator 窗口与 observe、act 的可信确认，由用户现场核对。 |
| W6 | 通过 | 首次误批的授权已撤销；重试时用户拒绝，CLI 返回 `permission_denied`，未自动重试。 |
| W7 | 部分通过 | 首轮窗口 1149 授权后，`unit.run` 因没有默认 GUI profile 被拒绝。后续副本配置了真实模型、默认 profile，并获窗口 3452 授权；真实 `unit.run` 完成观察、4 次 HTTP 200 模型推理和 2 次已确认的 Calculator 点击，随后第三步以 `invalid_action` 结束，尚未验证目标完成。 |
| W8 | 通过 | 对授权外 Desktop `d_nonexistent_acp_e2e` 提交，返回 `not_found`；auth event 为 `desktop_out_of_grant`。 |
| W9 | 通过申请校验 | 第二个 Calculator 窗口 1214 获用户批准，但 CLI 检出它不是当时绑定的 1149 并退出 2；该测试授权随后被撤销。 |
| W10 | 通过拒绝链路 | 窗口 1214 获授权后从 owner UI 撤销；新 ACP 会话的 `unit.run` 返回 `grant_missing` / `window_grant_ended`。未分别执行 observe、act 命令。 |
| W11 | 通过拒绝链路 | owner 将物理 Desktop 从 1149 改绑至 1214，旧授权未延续；新会话 `unit.run` 返回 `grant_missing` / `window_grant_ended`。 |
| W12 | 部分通过 | ACP 提交与事件订阅记录了 Run 的观察、推理、动作受理/完成及终止，Runtime 显示 `ended` / `failed` / `confirmed`。真实模型在第三步给出无法解析的动作，故正常完成与取消链路仍未验收。fake editor 的 `PASS` 仅表示预期的权限请求出现，不代表任务成功。 |
| W13 | 部分通过 | 数据库的三个窗口授权均只归属桥的 clientId `app:ec7f050c32c0`，权限为 observe、act；用户亲自批准配对和窗口请求。`same_user` 等级在首轮已核对，本轮未留新的身份等级快照。 |

真实 Runtime 的 `requests.sqlite` 记录了 W4 的 `window_grant_missing`、首轮 W7 的 `no_default_gui_profile`、W10/W11 的 `window_grant_ended`；`hub.sqlite` 记录窗口授权归属、权限及结束状态。后续副本的 `runs.sqlite` 记录 `run_958627b54623` 的 2 次已完成点击及 `invalid_action` 终止，`ai.sqlite` 记录 4 次推理均为 HTTP 200。fake editor 的 ACP transcript 与 summary 保存在隔离测试目录，输入中明确给出 `desktopId`。测试结束后，后续副本的窗口 3452 授权 `wg_92908c8b7267` 已从 owner UI 撤销，`hub.sqlite` 显示 `revoked` / `window_grant_revoked`；物理 Desktop 已从 owner UI 解除挂接，页面显示 0 个 Desktop，隔离测试副本已退出。此前重启产生的同窗口授权均为 `ended`。

**结论**：物理 Desktop 的配对、绑定、窗口申请和拒绝链路已验证；真实模型现在可进入执行并在 Calculator 完成窗口级输入。ACP 编辑器填写 `desktopId`、owner UI 物理 Desktop 的绑定与撤销、AI 连接 URL 编辑、空闲后首次截图容量检查均有修复。W3 的 Zed 部分、W7 的目标完成、W12 的正常完成与取消，以及 W10 的独立 observe/act 操作仍待验收；不能宣称 W1–W13 全通过。

## 专用模型连接续测

在第二个隔离测试副本 `/tmp/adt-url-fix` 中，用户亲自输入并保存专用 API 密钥；密钥未进入报告或源码。Base URL 为 `https://ark.cn-beijing.volces.com/api/v3`。旧表单在输入框显示完整 URL 时仍保留“请输入完整的 URL”错误；修补版让保存按钮先结束输入框编辑并等待一次 UI 状态同步，还会在 URL 编辑后清掉旧错误。真机验证中，使用相同 URL、未填写密钥时只出现“需要填写 API 密钥”；用户随后在修补版保存成功。“获取模型”返回的列表含该账号不可调用的旧模型，不能用作权限证明。

基于该连接创建 `UI-TARS v1` 测试 GUI 配置和模型配置。能力测试以 `doubao-seed-2-1-pro-260628` 运行，T1 通过、T2 HTTP 404 / `UPSTREAM_PROTOCOL_ERROR`；改用“获取模型”返回的 `doubao-pro-128k-240515` 后，T2 HTTP 404 / `MODEL_NOT_FOUND`。核对账号开通状态后改用 `doubao-seed-2-1-lite-260915`，真实能力测试 T1 网络、T2 认证/模型、T3 图像输入、T4 GUI 输出全部通过，且未执行桌面输入；该模型的 GUI profile 成为默认（指针 d2）。

续测发现空闲超过一分钟后，首次截图的磁盘剩余容量查询在异步刷新完成前返回 `disk_unknown` / `limit_exceeded`。修补版允许短暂等待刷新，同时在 macOS 可选容量属性缺失时回退到 `statfs`；隔离副本首个真实 Run 越过该检查，后续回归测试 `idleScreenshotWaitsForFreshCapacity` 通过。另一次观察因 Orca 窗口遮挡 Calculator 返回 `stale_observation` / `occluded`，这是窗口隔离检查；临时隐藏遮挡窗口后，`run_958627b54623` 成功观察、推理和执行 2 次点击。该 Run 最终因模型第三步输出 `invalid_action` 失败；结果不算目标完成。另一次取消演练在截图前因 Chrome 窗口遮挡 Calculator 被拒绝，未形成有效的取消验收。两次遮挡均未造成额外桌面输入。
