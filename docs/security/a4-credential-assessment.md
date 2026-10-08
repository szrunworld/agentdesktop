# A4-SEC-03 凭据隔离安全评估（2026-10-08）

对象：PR #137 中的客户端凭据与 owner 凭据。目标是逐项写清楚：在当前实现下，一个**同一 macOS 用户下的普通进程**（没有 root，没有调试权限，没有关闭 SIP）能读取、复制或复用哪些凭据。

本文只陈述实测结果，或明确注明依据的平台文档；没有实测的结论都标为「未实测」。推荐方案需要 Kevin 裁决后再实施，本 PR 没有重构身份体系。

## 一、实测结果

测试环境：测试副本 `/tmp/adt-a4c`，本 PR 的构建产物，macOS 15.1 arm64。

| # | 攻击 | 结果 |
| --- | --- | --- |
| F1 | 没有任何授权的 Python 进程直接调用 `desktop.list` | `pairing_required`（正确） |
| F1 | 同一进程读取 `<endpoint 去掉 .sock>/owner.credential`（0600，同用户可读），用它握手 | **成功**，principal 为 `owner` |
| F1 | 用偷来的 owner 身份调用 `hub.pairing.approve`，给自己的配对申请批准全部 capability | **成功**，得到 `app:…`。等于提权成功 |
| F2 | App 凭据文件（`agents pair --out`、SDK `save_credential`）为 0600 普通文件 | 同用户任何进程都能读取并冒充该 App（与 F1 相同，属于文件读取；本轮没有单独演示） |
| F3 | Runtime 端存储 | 只存 SHA-256 哈希，以常量时间比较；审计和日志里不出现 token（已 grep 确认：CLI / Runtime 都不打印 token，token 也不出现在命令行参数中） |
| F4 | 环境变量 | 只有 `AGENTDESKTOP_CREDENTIAL_FILE`（路径，不是密钥）。`session exec` 的上下文文件里有 Run 级的 attach token（0600，Run 结束即失效），不是长期凭据 |
| F5 | Runtime 能否识别对端代码身份（`LOCAL_PEERTOKEN` + `SecCodeCopyGuestWithAttributes`） | 能。实测：Python 显示为 `Python-5555…`（ad-hoc，无 Team ID）；Node 显示为 `node`（Team HX7739G8FX，hardened runtime）；我们的 CLI 显示为 `com.agentdesktop.app.agentdesktop`（自签名，**无 Team ID，无 hardened runtime**） |
| F6 | 用 `DYLD_INSERT_LIBRARIES` 启动我们的 CLI | 能启动，签名校验仍然有效。没有 hardened runtime 时 dyld 会接受注入，进程的代码身份因此不能证明运行的是我们的代码（依据 Apple 文档；本次只插入了系统库来验证 dyld 接受该变量，没有演示恶意代码） |
| F7 | 不同 Python 脚本或不同 Node 脚本之间 | 对端代码身份完全相同，都是解释器本身，Runtime 无法区分 |

结论：**按当前实现，per-App 隔离对普通同用户进程不成立。F1 是最严重的问题：任何同用户进程都能提权为 owner。** PR #137 不应以当前形态作为最终安全模型合入。

## 二、各类客户端能达到的隔离级别

| 客户端类型 | Runtime 能确认的身份 | 偷到 token 能否冒充 | 可达到的级别 |
| --- | --- | --- | --- |
| 签名 App（Developer ID + Team ID + hardened runtime + library validation），例如打包后的 BOSS / WeChat Agent | 对端代码满足配对时记录的 designated requirement（Team + bundle id） | 不能：token 和代码身份都要匹配。剩余风险是对该进程的注入或调试，需要 root、SIP 关闭、`get-task-allow`，或用户授予的高级权限 | **进程级隔离** |
| 我们自己的 CLI（目前自签名，无 hardened runtime） | 身份可以伪造（F6）；而且任何进程都可以**执行**这个 CLI 来替它办事（confused deputy） | 能 | **仅同用户边界**。即使签名合格，“谁在调用 CLI”仍然无法确认，所以敏感的 owner 操作不能只靠 CLI 身份 |
| 无沙盒脚本 Agent（Python / Node 脚本、ACP bridge 若以脚本运行） | 只能确认是哪个解释器 | 能：同一解释器下的任何脚本都能复用 | **仅同用户边界**。Keychain 的 ACL 也只能精确到解释器，同一解释器下的所有脚本共享 |
| 进程内（主窗口） | 天然是 owner | 不涉及 | 最高 |

关于 Keychain（**未实测**：按约定不写登录钥匙串，也不在用户屏幕上弹授权框；以下依据 Apple 文档）：
- 传统（文件式）钥匙串的条目有可信应用 ACL。不在 ACL 内的进程读取时，会弹出系统授权框，不会静默拿到。代价是：用户点了「始终允许」就失效；ACL 对 ad-hoc 签名按 cdhash 识别，每次重新构建都会再次弹框；对脚本只能精确到解释器。
- Data Protection 钥匙串（`kSecUseDataProtectionKeychain`）靠 `keychain-access-groups` entitlement 隔离，不弹框，其他 App 读不到。前提是使用带 Team ID 的签名和 provisioning profile；无签名 CLI 和脚本用不了。
- 结论：Keychain 能显著提升「签名 App」这一类的凭据保密性，但对脚本类 Agent 无法提供 App 之间的隔离，**不能宣称 Keychain 能防御所有同用户进程**。

## 三、推荐方案（待裁决）

方案按依赖程度递增排列。S1–S3 是最小修复，不改 runtime/1 冻结契约的形状，也不引入第二套身份系统。

**S1 · 撤掉 owner 凭据文件（修复 F1，必做）**
- 删除 `owner.credential`。socket 上的 owner 只有一种情况：对端是本产品包内的 CLI，经 `LOCAL_PEERTOKEN` 校验 designated requirement（本产品的 identifier，签名合格后再加上 Team ID）。
- 即便如此，CLI 仍可能被别的进程调用，所以**授权扩大类操作**（`hub.pairing.approve`、扩大范围的 `hub.grants.set`）必须由用户亲自确认：只能在主窗口内（进程内连接）完成，或者 CLI 发起后需要主窗口确认，或系统 Touch ID / 密码确认（LocalAuthentication）。撤销、收窄、列表这类只会减少权限的操作，CLI 可以直接做。
- 影响：PR4 的审批 UI 之前，需要一个最小的确认面板（一个原生确认弹窗即可），这一点需要 Kevin 决定是否提前做。

**S2 · 配对时把凭据绑定到代码身份（缓解 F2 / F7）**
- 配对时记录对端的代码身份：Team ID、identifier、是否开 hardened runtime，以及能否验证。之后每次握手，除了校验 token，还校验对端满足当时记录的 requirement。
- 对端无法验证身份时（ad-hoc 签名、解释器），在审批界面和 `agents list` 中标为「无法验证代码身份」。owner 由此知道这个 App 只有同用户级别的隔离。可以考虑这类 App 默认不授予 `act` / `desktop.manage`，或要求更短的授权时长。
- 这需要在 runtime/1 的 HubClient 中增加只读字段（属于契约的增量，不改形状），以及在 Runtime 握手中增加一步校验。

**S3 · 凭据不落普通文件（满足要求 3）**
- 签名 App 的 SDK 把凭据存在 Data Protection 钥匙串（自己的 access group）；CLI 的 `agents pair` 存在传统钥匙串，ACL 只授予本产品 CLI。
- 脚本 SDK 的选择：要么存传统钥匙串（ACL 为解释器，只能挡住非该解释器的进程），要么保留文件并在文档中明确为同用户级别。不能宣称两者有更强的隔离。
- 测试仍然使用内存存储，不写登录钥匙串。

**S4 · 发布侧（与 A4 正交，但 S1 / S2 的效果依赖它）**
- 本产品 App 和 CLI 使用 Developer ID 签名、开启 hardened runtime、公证（notarization），否则 F6 会让代码身份校验失去意义。
- 建议第三方 Agent（BOSS / WeChat）以签名 App 的形式分发，以达到进程级隔离。

**剩余风险（即使 S1–S4 全部完成）**：有 root 或调试权限的进程、关闭了 SIP 的机器、用户自己点了钥匙串「始终允许」、用户被诱导在确认框里点了批准、对已签名进程的内存注入（需要高级权限）。这些都超出应用层凭据机制能防的范围，需要在安全文档中明确声明。

## 四、本 PR 里已经做到的（不依赖上述裁决）

- 每个 App 有独立的 clientId 和凭据；撤销后，旧凭据在握手阶段永久返回 `client_revoked`；重新配对得到新的 id 和凭据。
- Runtime 不存明文；token 不进日志、不进命令行参数、不进环境变量。
- 撤销 / 收窄 / 撤销授权在 Runtime 内有明确的线性化边界（`docs/security/a4-identity.md`「撤销的线性化边界」）。
