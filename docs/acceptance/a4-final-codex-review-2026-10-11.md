# A4 最终 head 补审（Codex，2026-10-11）

审核对象是 #137 最终 head `2e26a1635e33d9e534caca96bb1a9dc8cc83de3e`，
上次记录的审核基线是 `8db990d`。本次阅读最终版本及差异中的 A4 文件：
`RuntimeService+Auth.swift`、`RuntimeService+Confirm.swift`、`RuntimeService+Hub.swift`、
`RuntimeService.swift`（身份与 respond）、`IPC/RuntimeServer.swift`、`IPC/CodeIdentity.swift`、
`Records/HubStore.swift`、`AgentDesktopClient/CredentialStore.swift` 及对应测试。
其他并入主线的 GUI、引擎、iPhone、ACP 会话历史改动不属于本次逐行审核范围。

## 发现与处理

- **P2：协议错误帧绕过发送闸门。** 最终 head 的 `RuntimeServer.serve` 在
  `.tooLarge` / `.truncated` 分支直接 `channel.writeLine`，正常答复和事件则经过
  `ConnectionState.send`。撤销承诺是返回后该连接不能再开始写出；这两种错误帧
  没有使用同一个闸门。错误帧不含敏感数据，socket shutdown 通常也会阻止实际写出，
  所以本次按 P2 记录，不能作为数据外泄已发生的证据。当前修复将两条路径都改为
  `state.send`，与正常响应一致。
- 审核范围内未发现新的 P0/P1。身份由内核 audit token 校验；socket 无 owner；
  普通配对客户端的权限逐次核对；未验证身份只能缩小自己的权限；确认后重查
  grant revision，数据库比较与写入使用同一锁；撤销切断连接、结束会话与 Run。
  单次 owner elevation 在 `respond` 的 defer 中清除。

## 验证及边界

修复在当前 main 基线 `0feb4b1` 上验证（不是声称在旧提交上运行新代码）：

- `swift test --filter 'RuntimeIdentityTests|RuntimeConfirmationTests|RuntimeRevocationTests|RuntimeServerTests'`：61 项通过。
- `swift test --filter AgentDesktopClientTests`：20 项通过；其中真实钥匙串测试按原规则跳过。
- 新增签名 access group 策略测试：1 项通过。
- 完整 `swift test`：1563 项通过，保留 7 个已知问题；没有新增失败。
- `git diff --check`、发布脚本语法检查通过。

S4 仍为发布阻断项。本次附带的 Developer ID 发布流程和 Data Protection
钥匙串实现是候选版准备；机器上没有有效签名身份，尚未完成签名、公证、
`verified` 握手、真实 Data Protection 条目隔离或第三方 Agent 的签名验收。
没有代替用户操作 Touch ID，没有把 mock 或单元测试标为真机通过。
