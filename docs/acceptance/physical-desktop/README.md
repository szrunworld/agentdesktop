# 物理窗口 Desktop 验收（2026-10-08）

测试应用：计算器（无业务风险）。未使用微信，未执行任何外发。测试副本：本分支 `scripts/bundle-app.sh` 构建，`open -n -g --env AGENTDESKTOP_SOCKET=/tmp/adt-pwd/side.sock`，Runtime 端点 `/tmp/adt-pwd/side.runtime.sock`。脚本：`e2e_calculator.py`（一个连接内完成全部步骤，只做脚本列出的调用）。证据哈希见 `SHA256SUMS`。

## 自动化测试

- 新增 `Tests/AgentDesktopRuntimeTests/RuntimePhysicalDesktopTests.swift` 7 个用例（创建不建屏、绑定不移动、未绑定不截屏不启动、图像与输入只到绑定窗口、遮挡 fail closed、窗口关闭 fail closed、销毁不动显示器和应用）。
- 全量：`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test` → 717 通过，0 失败（跳过的是原有在线模型用例）。
- `scripts/verify-command-surface.py` → 退出码 0（17 个命令，旧入口拒绝）。

## 真机结果

| 运行 | 场景 | 结果 |
| --- | --- | --- |
| run1 | 计算器在后台、被用户的微信窗口遮挡 | P1–P5 通过；P6 `observe` 返回 `stale_observation / occluded`（`coveringWindowId` 为微信窗口），未截图、未输入：**fail closed 符合要求** |
| run2 | 用户空闲 ≥5 秒后，操作员把计算器短暂前置，结束后恢复原前台应用 | P1–P11 全部通过：物理 Desktop 未建屏；绑定前后窗口 frame 相同 `(0,38,198,350)`；截图 396×700 = 窗口 ×2，原点 = 窗口原点；点击 "7" 回执 `dispatched`，再次观察显示屏为 "7"；解绑重绑后旧快照被拒且 `notSent=true`；销毁后计算器仍在运行 |
| run3 | 绑定后操作员退出计算器 | C1 记录为 failed：拒绝了（`stale_observation`），但原因是"绑定进程已退出"，不是脚本预设的 `window_gone`——进程级检查先于窗口检查触发，fail closed 本身成立，脚本断言过严，记录保持原样；C2 输入被拒且未发送；C3 销毁只删记录 |

## 显示器数量

run1 全程 1。run1 结束后、run2 开始前出现第 2 个显示器 `d_7334dc990e04`（虚拟显示器，厂商号 0x3256，序列号 974），之后 run2、run3 各步都保持 2，没有再增加。测试副本的请求账本显示本次只做过 3 次 `desktop.create`，全部 `kind: physical`（`d_4b4df8e24e1b`、`d_e3395545eb07`、`d_4152bc994a11`），均已销毁；测试副本退出后该显示器仍在。结论：**不是本验收创建的**；当时唯一的候选进程是另一个会话自 18:23 起在 `~/orca/2ndscreen` 运行的 `swiftpm-testing-helper`（未处理，留给负责人确认）。

## 未覆盖

- 窗口重建（同进程新窗口）只有自动化测试，真机未做。
- 多显示器、Windows 后端未验证。
- 微信、CR01、CR03 不在本验收范围内。
