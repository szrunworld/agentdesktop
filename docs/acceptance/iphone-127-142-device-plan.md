# #127 / #142 真机验收计划与记录模板

状态：2026-10-09 已执行，结果见 `iphone-127-142-device-2026-10-09.md`（10 项通过、A6 部分、S4 NOT_RUN）。本表保留为计划原样。

## 1. 准备（不需要 Kevin，不碰设备）

```bash
scripts/iphone-acceptance/prepare.sh            # 产物在 ~/orca/.ios-ci/accept-127-142
```

它会建一个合并检出：main 加 #142（`iphone-fix-status-2`）再加 #127（`iphone-fix-paste`）。然后在这个检出上编译以下工具：
- engine CLI；
- 验收用宿主 harness：只链接 engine，开放专用的控制 socket，不打进安装包；
- 时间线记录器 `watch`：每 20 毫秒记录一次鼠标位置和前台应用；
- 剪贴板工具 `clip`：`clip set text|rtf|image|file` 写入固定测试数据，`clip dump` 输出每个类型的 SHA-256。

检出所在的提交写在 `ev/checkout.txt`，验收报告引用这个 SHA。

已核实的前提：真机上 iPhone 镜像窗口的辅助功能标题是 “iPhone Mirroring”（英文系统，2026-10-09），与 #142 的窗口绑定规则一致。中文系统下的标题没有核实。

## 2. 执行时的约定（需要 Kevin 在场）

- 宿主使用专用 socket：`AGENTDESKTOP_SOCKET=$HOME/Library/Caches/AgentDesktop/ia.sock`，不碰产品的 socket。
- 只在“备忘录”里新建一条空白备忘录上输入，不碰聊天类应用，不发送任何东西。验收结束后删掉这条备忘录（先留证）。
- 全程运行 `watch`，记录鼠标和前台应用。Kevin 解锁或手动操作的时段写进 `ev/marks.log`，这些时段不计入判定。
- 测试数据全部是无敏感信息的固定字符串（`clip` 内置的测试内容）。
- 每一项都保存命令输出、执行前后的截图、`clip dump` 前后对比，以及时间线片段。

## 3. 用例

| ID | PR | 场景 | 步骤（要点） | 预期 | 实际 | 证据 | 结论 |
|---|---|---|---|---|---|---|---|
| A1 | #127 | 结果未知后阻断 | 构造粘贴结果为 unknown（页面上有居中的许可框字样，或无法读到的输入），随后不截图，从新进程发起 tap / key / type | 不重贴，不发回车；`delivery_unknown` 或 `clipboard_pending` 拒绝新进程的输入；截图后（且没有粘贴在进行）阻断才解除 | | | NOT_RUN |
| A2 | #127 | 剪贴板原为图片 | `clip set image` 后粘贴 “acceptance A2” | 手机输入框里不出现图片；确认完成则剪贴板逐类型一致恢复；判为未知则剪贴板不恢复并报 `clipboard_withheld` | | | NOT_RUN |
| A3 | #127 | 剪贴板原为富文本 / 文件 | `clip set rtf`、`clip set file` 后各粘贴一次 | 能完整快照的恢复后逐类型一致；无法完整快照的报 `paste.not_delivered`，剪贴板不变 | | | NOT_RUN |
| A4 | #127 | 粘贴期间用户复制 | 粘贴开始约 1 秒后执行 `pbcopy` 写入一段测试文字 | 剪贴板保留用户的新内容；结果为 `unknown(user_copied_during_paste…)`；如果手机仍在“Pasting from”，点它的“取消”。记录手机实际粘进了什么（已知限制：可能是用户内容） | | | NOT_RUN |
| A5 | #127 | 结果未知后不提交 | 带尾随换行输入（`--text $'abc\n'`），并构造未知结果 | 不发回车；agent 路径停下交给人（`isIndeterminate`） | | | NOT_RUN |
| A6 | #127 | 只点系统许可框 | 在没授权过粘贴的应用里第一次粘贴，触发真实的系统许可框；再在页面上制造同名文字（先输入再粘贴） | 只点真实的系统许可框；页面上的同名文字一次都不点 | | | NOT_RUN |
| A7 | #127 | 其他进程粘贴时 | 进程 A 粘贴时，进程 B 截图、tap | B 的截图返回 `paste_in_progress`；B 的 tap 在发出前被拒绝；A 的“允许粘贴”和回车不受影响 | | | NOT_RUN |
| S1 | #142 | 设置窗口同时打开 | 打开镜像的设置窗口（与手机窗口重叠或不重叠），执行 status、screenshot、tap | 状态为 ready，截图只含手机画面；设置窗口压住手机窗口时 tap 被拒（`other_window_of_process_in_front`）；设置窗口不会被绑定为手机窗口 | | | NOT_RUN |
| S2 | #142 | 断线 | 截图后拿起手机（触发 iPhone in Use），再执行 tap 和 screenshot | 状态非 ready；tap 以 `not_connected` 拒绝；没有点到镜像自己的按钮 | | | NOT_RUN |
| S3 | #142 | 恢复连接 | 锁屏后执行 `iphone reconnect`，再截图 | 只点手机窗口里的 Connect / Resume；重新截图之前输入一律被拒；恢复后状态 ready | | | NOT_RUN |
| S4 | #142 | 手机内容像状态页 | 在备忘录里输入 “Timed Out / 正在连接”，再截图 | 判为 `uncertain` 并拒绝（已知可用性代价）；不会把它当 ready 去操作，也不会报成成功 | | | NOT_RUN |
| S5 | #142 | unknown 不能升级为 success | 在 S2、S4 的状态下执行 type | 不出现 `paste.confirmed` 或 `ok:true`；结果为拒绝或 unknown | | | NOT_RUN |

## 4. 记录与结案

- 每一项的“实际”和“证据”在执行时当场填写，证据路径在 `~/orca/.ios-ci/accept-127-142/ev/`。截图里如果有个人内容，不入库。
- 有任何一项不通过，都在对应的 PR 上修复后重测这一项，不跳过。
- 全部完成后，在 `docs/acceptance/iphone-2026-10-08.md` 第 9 节把相关条目更新为“正式结案”，或保留原状态并写明原因。
