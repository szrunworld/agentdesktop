# 物理窗口 Desktop + 窗口授权：真机安全验收记录（模板）

- 执行人：Kevin 本人（Touch ID / 登录密码只能由本人完成）
- 构建：`scripts/bundle-app.sh` 于提交 `________`
- 命令：`scripts/physical-desktop-acceptance.sh`（测试副本 `/tmp/adt-pd-acc`，证据留在 `/tmp/adt-pd-acc.evidence/`）
- 前提：物理 Desktop 的封印按 Kevin 裁决已打开，且 owner 已在测试副本主窗口挂接主显示器、得到 `d_…`；运行时 `PD_DESKTOP=d_… scripts/physical-desktop-acceptance.sh`。不满足时脚本在第 2 步确认"已配对 App 不能挂接显示器"后报 `PENDING`（退出码 3），本记录其余各行不适用

- 注意：覆盖物检查是 fail closed 的。2026-10-10 只读探测本机主显示器：有一个第三方工具在 layer 1500 铺满整块显示器（不透明度 1.0），按规则它会让物理 Desktop 上的每次观察和操作都返回 `occluded`。验收前请先退出这类全屏覆盖工具，或把结果记为"按设计拒绝"。

## 自动步骤（脚本输出 PASS / FAIL）

| # | 步骤 | 期望 | 结果 |
| --- | --- | --- | --- |
| 1 | 配对 pd-cli（批准 + Touch ID） | 得到 clientId | |
| 2 | 使用 owner 挂接的物理 Desktop（`PD_DESKTOP`） | `kind = physical`，系统显示器数不变；脚本结束不销毁它 | |
| — | 授权前 | `window list` 为空；绑定 Chess 窗口被拒 `bind_requires_grant` | |
| 3 | 申请 Chess 窗口（查看 + 操作，无保存）；核对确认窗口：Chess、"这是你自己屏幕上的真实窗口"、权限两项、期限 10 分钟；批准 + Touch ID | 授权的正是该窗口 | |
| 4 | 原地绑定并观察 | 目标为该窗口；`image.transient = true`；图像尺寸 = 窗口 frame × 缩放、原点 = 窗口原点且小于整块显示器（Chess 窗口不要最大化）；测试副本内无 `*.screen.png` | |
| 5 | 发一次 Escape | `delivery = dispatched` | |
| 6 | 再次申请（含保存），点"拒绝" | `user_denied` | |
| 7 | CLI 放弃窗口授权（批准 + Touch ID） | 授权 `revoked`；之后观察被拒 `window_grant_missing` | |
| 8 | 收尾 | 显示器数不变；审计里没有窗口标题或应用名 | |

## 可选手动步骤（第 4 步之后、第 7 步之前）

| # | 操作 | 期望 | 结果 |
| --- | --- | --- | --- |
| M1 | 在 Chess 窗口上方弹出一个通知横幅后立即 `agentdesktop observe --session <SID>` | `stale_observation / occluded`，只含 `coveringWindowId`，无应用名 | |
| M2 | 系统设置里改一次主显示器分辨率后观察（之后改回） | `stale_observation / display_changed` | |
| M3 | 退出这个 Chess 实例后观察 | `stale_observation / process_exited` | |

## 结论

- 通过 / 不通过：
- 意外的弹窗或对其他窗口的影响：
- 备注：
