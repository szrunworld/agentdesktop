# 发布阻断项：A4 S4（Developer ID 签名与 Hardened Runtime）

裁决：Kevin 2026-10-09 将 S4 列为**正式发布阻断项**。开发版本可以继续测试，但当前状态不能视为生产安全验收通过。

## 为什么是阻断项

- **代码身份绑定**：Runtime 只能把凭据绑定到「有 Team ID、开 hardened runtime、签名有效」的程序（`verified`）。当前本产品 CLI 是自签名、未开 hardened runtime，实测级别为 `same_user`：凭据被复制后可以被同用户的其他程序使用；按 R1 裁决，它也不能请求任何敏感管理操作。
- **注入**：没有 hardened runtime，`DYLD_INSERT_LIBRARIES` 等方式可以把别人的代码注入本产品的进程，签名校验仍然显示有效。
- **钥匙串**：开发版用的是传统钥匙串。同用户进程可以抢先写入同名条目，让 CLI 以攻击者的身份工作。签名之后，应改用 Data Protection 钥匙串加 access group（需要 Team ID 和 provisioning profile）。

## 发布前必须全部满足

| # | 要求 | 检查方式 |
| --- | --- | --- |
| 1 | `Agent Desktop.app` 和包内 `agentdesktop` CLI 都使用 Developer ID Application 证书签名，带 Team ID | `scripts/verify-release-signing.sh` |
| 2 | 两者都开启 hardened runtime | 同上 |
| 3 | 不带 `allow-dyld-environment-variables`、`disable-library-validation`、`get-task-allow` entitlement | 同上 |
| 4 | 已公证（notarized） | 同上（`spctl`） |
| 5 | Runtime 把签名后的 CLI 识别为 `verified`（握手结果里 `principal.codeIdentityLevel == "verified"`） | 在发布候选版上手动核对 |
| 6 | CLI 凭据改存 Data Protection 钥匙串、使用本产品的 access group；不再使用传统钥匙串 | 代码改动 + 发布候选版验收 |
| 7 | 第三方 Agent（BOSS / WeChat）以签名 App 形式分发，配对后显示为 `verified` | 各 Agent 的发布验收 |

`scripts/verify-release-signing.sh` 在当前开发包上会如实失败（无 Team ID、非 Developer ID、hardened runtime 关闭、未公证）。CI 不对开发包运行它；它是发布候选版的门禁。
