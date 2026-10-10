# 物理窗口 Desktop + 窗口授权：真机安全验收记录（模板）

- 执行人：Kevin 本人（Touch ID / 登录密码只能由本人完成）
- 构建：`scripts/bundle-app.sh` 于提交 `________`
- 命令：`scripts/physical-desktop-acceptance.sh`（测试副本 `/tmp/adt-pd-acc`，证据留在 `/tmp/adt-pd-acc.evidence/`）
- 前提：物理 Desktop 的封印按 Kevin 裁决已打开（否则脚本在第 2 步报 `PENDING`，退出码 3，本记录不适用）

## 自动步骤（脚本输出 PASS / FAIL）

| # | 步骤 | 期望 | 结果 |
| --- | --- | --- | --- |
| 1 | 配对 pd-cli（批准 + Touch ID） | 得到 clientId | |
| 2 | 挂接主显示器为物理 Desktop | `kind = physical`，系统显示器数不变 | |
| — | 授权前 | `window list` 为空；绑定 Chess 窗口被拒 `bind_requires_grant` | |
| 3 | 申请 Chess 窗口（查看 + 操作，无保存）；核对确认窗口：Chess、"这是你自己屏幕上的真实窗口"、权限两项、期限 10 分钟；批准 + Touch ID | 授权的正是该窗口 | |
| 4 | 原地绑定并观察 | 目标为该窗口；`image.transient = true`；测试副本内无 `*.screen.png` | |
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
