# W1–W13 真机续测：物理 Desktop（2026-10-11）

测试副本：独立的 `Agent Desktop.app`、Runtime 数据目录、socket 和临时钥匙串；桥为同一 worktree 构建的 `agentdesktop-acp-dev`。测试使用独立 Calculator 窗口。窗口确认、配对确认和 Touch ID 均由 Kevin 操作。此记录是 PR #268 首轮报告的续测；本轮源码在修复 PR 提交前构建，不能当作最终提交的全量验收。

| 场景 | 结果 | 真机证据与边界 |
| --- | --- | --- |
| W1 | 通过操作链路 | 用户批准桥身份 `ACP-E2E` 的配对和物理显示器开放；Runtime 的 pairing 为 `approved`，物理 Desktop `d_8d82bc84e4a5` 授给桥 `app:ec7f050c32c0`。确认窗口内容由用户现场核对，未保存截图。 |
| W2 | 通过（首轮） | 缺少 `--desktops`、使用 `created` 均退出 2，未发请求。 |
| W3 | 部分通过 | fake editor 连真实 Runtime 时任务列表含 `unit-run`，没有桥的 `ai.profiles.list` 请求；隔离 Zed 打开 Agent Panel 后停在 Zed AI 登录页，未在 Zed 本身完成 `/help`。 |
| W4 | 通过 | 已绑定窗口、尚无窗口授权时，真实 `unit.run` 返回 `grant_missing` / `window_grant_missing`。 |
| W5 | 通过 | `request-window` 弹出 Calculator 窗口与 observe、act 的可信确认，由用户现场核对。 |
| W6 | 通过 | 首次误批的授权已撤销；重试时用户拒绝，CLI 返回 `permission_denied`，未自动重试。 |
| W7 | 部分通过 | 用户批准窗口 1149，桥获得 observe、act 授权，`unit.run` 越过窗口检查；随后被 `not_found` / `no_default_gui_profile` 拒绝。尚未验证执行成功。 |
| W8 | 通过 | 对授权外 Desktop `d_nonexistent_acp_e2e` 提交，返回 `not_found`；auth event 为 `desktop_out_of_grant`。 |
| W9 | 通过申请校验 | 第二个 Calculator 窗口 1214 获用户批准，但 CLI 检出它不是当时绑定的 1149 并退出 2；该测试授权随后被撤销。 |
| W10 | 通过拒绝链路 | 窗口 1214 获授权后从 owner UI 撤销；新 ACP 会话的 `unit.run` 返回 `grant_missing` / `window_grant_ended`。未分别执行 observe、act 命令。 |
| W11 | 通过拒绝链路 | owner 将物理 Desktop 从 1149 改绑至 1214，旧授权未延续；新会话 `unit.run` 返回 `grant_missing` / `window_grant_ended`。 |
| W12 | 未完成 | 测试副本没有默认 GUI profile 和可用模型连接，`unit.run` 无法进入执行阶段；提交、查询、订阅、取消 Run 尚未验收。 |
| W13 | 部分通过 | 数据库的三个窗口授权均只归属桥的 clientId `app:ec7f050c32c0`，权限为 observe、act；用户亲自批准配对和窗口请求。`same_user` 等级在首轮已核对，本轮未留新的身份等级快照。 |

真实 Runtime 的 `requests.sqlite` 记录了 W4 的 `window_grant_missing`、W7 的 `no_default_gui_profile`、W10/W11 的 `window_grant_ended`；`hub.sqlite` 记录窗口授权 1149/1214 的归属、权限及结束状态。fake editor 的 ACP transcript 与 summary 保存在隔离测试目录，输入中明确给出 `desktopId`。测试结束后所有测试窗口授权均为 `revoked` 或 `ended`。

**结论**：本轮证实了物理 Desktop 的配对、绑定、窗口申请和拒绝链路，并发现 ACP 编辑器原本无法填写 `desktopId`、owner UI 原本无法为物理 Desktop 绑定与撤销窗口。本修复 PR 处理这两处障碍。W3 的 Zed 部分、W7 的完整执行、W12，以及 W10 的独立 observe/act 操作仍待配置专用模型连接、默认 GUI profile 和合格测试凭据后重测；不能宣称 W1–W13 全通过。
