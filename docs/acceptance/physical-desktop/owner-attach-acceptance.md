# owner 挂接显示器：真机验收记录（模板）

- 执行人：Kevin 本人（Touch ID / 登录密码只能由本人完成）
- 构建：`scripts/bundle-app.sh` 于提交 `________`
- 命令：`scripts/owner-attach-acceptance.sh`（测试副本 `/tmp/adt-oa-acc`，主窗口显示在你的主显示器上；证据留在 `/tmp/adt-oa-acc.evidence/`）
- 不创建虚拟显示器，不碰正式端点，不碰微信；只配对一个测试 CLI，开放的是你的主显示器，期间不绑定、不截图、不输入。

## 自动步骤（脚本输出 PASS / FAIL）

| # | 步骤 | 期望 | 结果 |
| --- | --- | --- | --- |
| 1 | 配对 oa-cli（批准 + Touch ID） | 得到 clientId | |
| 2 | 已配对 CLI 自己挂接显示器 | `permission_denied / owner_only`，什么都没挂接；显示器列表对它也是 `owner_only` | |
| 3 | **你在测试副本主窗口**：Desktops › 开放我的显示器 › 选主显示器与 oa-cli › 开放… › 核对确认窗口（显示器名称、编号、分辨率、"已证实为物理显示器"、程序名、"开放后它看不到任何窗口"）› 批准… › Touch ID | 脚本等到 oa-cli 的 `desktop list` 出现 `kind = physical` 的 Desktop | |
| 4 | 开放之后 | oa-cli `window list` 为空；绑定你屏幕上的任一窗口被拒 `bind_requires_grant`；系统显示器数不变 | |
| 5 | **你在主窗口**：同一显示器再开放一次给 oa-cli | 列表里它显示"已挂接"，不可再选（脚本只检查 Desktop 数仍为 1） | |
| 6 | **你在主窗口**：Desktops › 该 Desktop 详情 › 开放给的程序 › 全部收回并解除挂接 | 脚本等到 oa-cli 看不到这个 Desktop；审计里有 `hub.displays.detach revoked` 与 `ended` | |
| 7 | 收尾 | 显示器数不变；审计里没有窗口标题或应用名 | |

## 可选手动步骤

| # | 操作 | 期望 | 结果 |
| --- | --- | --- | --- |
| M1 | 第 3 步在确认窗口点"拒绝" | 主窗口显示 `permission_denied`（user_denied），Desktops 里没有新 Desktop；再点"开放…"可以重试 | |
| M2 | 第 3 步批准后，在 Touch ID 提示里取消 | 同上（user_cancelled） | |
| M3 | 另一个测试副本建一块虚拟显示器（如果你允许的话）后再打开"开放我的显示器" | 虚拟显示器置灰，标"虚拟显示器，不可开放" | |

## 结论

- 通过 / 不通过：
- 意外的弹窗或对其他窗口的影响：
- 备注：
