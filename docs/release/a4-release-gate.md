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

## 发布候选版构建

开发构建仍用 `scripts/bundle-app.sh`。正式候选版设置以下变量后运行同一脚本：

```sh
AGENTDESKTOP_RELEASE=1 \
DEVELOPER_ID_IDENTITY='Developer ID Application: …' \
TEAM=ABCDE12345 \
APP_PROVISION_PROFILE=/path/to/app.provisionprofile \
CLI_PROVISION_PROFILE=/path/to/cli.provisionprofile \
NOTARY_KEYCHAIN_PROFILE=agentdesktop-notary \
scripts/bundle-app.sh
```

两个 Developer ID provisioning profile 分别明确授权 `com.agentdesktop.app`、
`com.agentdesktop.app.agentdesktop`，并允许 `TEAM.com.agentdesktop.client-credential`。
`sign-release.sh` 检查 profile 的 Team、App ID、到期日和 access group；签名时启用
hardened runtime、时间戳，不生成任何注入 entitlement；公证成功并 stapling 后才生成分发 archive / manifest。
任何阶段失败都会停止，不降级为本地签名。

CLI 放在 `Contents/Helpers/AgentDesktopCLI.app` 中承载自己的 profile，原命令路径
`Contents/Resources/bin/agentdesktop` 是包内相对链接。CLI 不能脱离该包装单独分发。
依据：[Apple TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)
和 [Apple DTS 的命令行工具说明](https://developer.apple.com/forums/thread/836816)。

带 Team ID 的客户端从有效代码签名读取固定 product access group，使用
`kSecUseDataProtectionKeychain`，不读取传统钥匙串、不受 `AGENTDESKTOP_KEYCHAIN` 重定向。
缺少该 group 的签名版本报错。开发版本保留独立测试钥匙串。
不从传统钥匙串自动迁移凭据（旧条目可能被抢先写入）；候选版需要重新配对。

以上是发布准备，不能替代 S4 真机验收。当前机器无有效 Developer ID 签名身份。
拿到证书、两个 profile 和公证配置后，仍须运行门禁、验证 CLI 握手为 `verified`、
配对凭据在 Data Protection 钥匙串中读写及拒绝另一程序读取，并分别验收两种第三方 Agent。
Electron / Python 入口可能仍被识别为 `shared_interpreter`；仅签名不能把它们变为 `verified`。
