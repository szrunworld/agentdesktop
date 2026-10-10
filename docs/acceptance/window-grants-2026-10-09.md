# 窗口级授权：测试与验收记录（2026-10-09）

依据：Kevin 2026-10-09 裁决 B。设计：`docs/security/window-grants.md`。PR #205（Draft）。

以下几项分开记录，互不代替：自动化测试、strict 线程池测试、CI、真机验收、独立审核。

## 自动化测试（作者本机）

| 项目 | 提交 | 结果 |
| --- | --- | --- |
| `swift build --build-tests` | c497ae4 | exit 0 |
| `swift test`（全部） | c497ae4 | exit 0，1069 个测试通过（机器负载 24–36） |
| `RuntimeWindowGrantTests` 等相关目标 | cf965a6 | exit 0 |

新增 `Tests/AgentDesktopRuntimeTests/RuntimeWindowGrantTests.swift`。最初 19 个测试，按 Codex 意见陆续补到 50 个。最初那批覆盖：

- 申请：只授权确认窗口里展示的那一个窗口；授权期限不超过客户端授权的到期时间。
- 用户拒绝、取消、超时、无法验证身份、digest 不符：都不产生授权；拒绝后有冷却期。
- 前置条件不满足时（App 不在授权内、缺少对应能力、Desktop 不在授权内）直接拒绝，不弹窗。
- 用户确认期间窗口关闭或移出显示器：不授权。
- 同一 App 的另一个窗口：不能绑定、不能观察、不能 `wait`，也不出现在 `window.list`。owner 绑定的窗口，客户端同样不能观察，`desktop.show` 也不显示绑定信息。
- 权限分离：
  - 只有 observe：不能操作；
  - 只有 act：看不到任何东西，但可以操作；
  - 没有 persist：截图是临时的，过期或撤销时连文件一起删除；
  - 有 persist：截图保留，但用户撤销后客户端不能再读。
- 自己启动的窗口不需要窗口授权。
- 生命周期：
  - 窗口关闭后授权粘滞失效，同 ID 窗口再出现也不会继承；
  - 进程重启后失效；
  - 撤销窗口授权、移除客户端、撤销或收窄客户端授权、去掉能力、到期、Desktop 销毁：后续访问都被拒绝。
- 撤销正好发生在投递之前、或发生在读取元素期间：不发送输入，不返回读到的内容，并删除已拍的截图。
- 客户端只能经确认放弃自己的窗口授权；身份未验证时不能撤销别人的；`hub.windows.list` 只返回自己的授权。
- 封印开关保持产品默认值；持有窗口授权也无法把用户窗口拉到虚拟 Desktop 上。

另外：

- `TrustedConfirmationWindowTests`：窗口授权的确认文案（物理窗口警告、权限逐项列出、“只授权这一个窗口”），不可信文字一律惰性显示。
- `CLITests.windowsCommandsSendTheirMethods`：CLI 的 windows 子命令。
- 现有测试按新规则调整：配对场景先持有窗口授权再绑定；SEC-05 改为验证 App 授权不再列出该 App 的全部窗口。

### 变异检查

分别去掉以下检查，每一处都至少有一个测试失败：

- act 的两次检查（拿锁后一次、投递前一次），以及只去掉投递前那一次；
- observe 的第 1 步和第 3 步；
- wait 的两次检查；
- `window.list` 的过滤；
- 窗口关闭的粘滞失效；
- 进程身份校验；
- 绑定时的有效权限判断；
- persist 判断。

## strict 线程池

`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test`：

- 提交 c497ae4：exit 0，1069 个测试通过。
- 后续提交上偶发失败，失败的都是 `SingleEndpointTests`（#166 已知问题：`RuntimeBridge` 用 `Task.detached` 加信号量）。负载高时还出现过 ACP、WDA、推理超时类失败，同样与本 PR 无关。
- 同一时段交替运行，对照干净 main（bb02b59）与本分支（Codex 第三轮修复后）：

| 轮次 | main | 本分支 |
| --- | --- | --- |
| 1 | exit 1：`SingleEndpointTests` 4 处 | exit 1：`SingleEndpointTests` 4 处 |
| 2 | exit 1：`SingleEndpointTests` 6 处 | exit 1：`SingleEndpointTests` 4 处 |

2026-10-10 凌晨负载低（约 3），又交替跑了四轮（本分支在 Codex 第八轮修复之后）：

| 轮次 | main | 本分支 |
| --- | --- | --- |
| 3 | exit 0 | exit 1：`SingleEndpointTests` 4 处 |
| 4 | exit 0 | exit 1：`SingleEndpointTests` 7 处 |
| 5 | exit 0 | exit 0 |
| 6 | exit 0 | exit 0 |

只跑 `SingleEndpointTests`（strict）时，main 和本分支各跑 6 次，全部通过。也就是说，这个用例只在全量并发运行时失败，与 #166 记录的机制一致（`RuntimeBridge.answer` 用 `Task.detached` 加信号量，依赖协作线程池调度）。本分支多了约 30 个测试，全量运行时的并发更高，失败率也随之上升，这与 A4 基线（main 4/15，#137 7/15）的情况相同。本 PR 没有改动 `RuntimeBridge` 或 AI 服务的代码路径。这个不稳定用例需要在 #166 修复，不在本 PR 范围内；请 Kevin 知悉。

除此之外，本分支没有其他失败。窗口授权、撤销、身份相关的 strict 定向运行（`RuntimeRevocationTests|RuntimeWindowGrantTests|RuntimeIdentityTests`）连续 5 次通过。

## CI

- PR #205 每轮修复后都跑了 CI：cf965a6 起到 d2dbf96，`macOS` 与 `windows contracts` 都通过。
- 例外是 8e9eb9d（合入 main 后的那一轮）：有两个测试在 CI 工具链（Swift 6.1.2）上失败，原因是在 `#expect` 里对加括号的表达式取反，被这个版本求值错了。已改写这两个断言，下一轮起恢复通过。
- d2dbf96：run 38010567629、38010567645 通过。

## Codex 审核

从 7629d6b 到 d2dbf96 共 17 轮，所有意见都已逐条修复并在 PR 上回复。d2dbf96 这一轮 Codex 没有新意见，并给了 👍。

截至 d2dbf96：全量测试 1116 个通过（exit 0），strict 全量测试 exit 0。

## 合并

#205 于 2026-10-10 以 head `8813877` 合并，合并提交 `0ac22c4`。依据是 Kevin 在会话中的明确授权："免独立审核 授权合并 #205，head 8813877"。合并时 CI 的 build 和 test 都已通过，Codex 在该 SHA 上没有新意见，48 条意见都已回复。

后续 PR：

- #212（合并提交 `7fa1b15`）：
  - 验收脚本先记录基线，清理后逐项核实，任何一项不符都会打印"清理失败"并以退出码 3 结束（裁决第 1 条第 4、5 项）；
  - "until per-window grants exist"等过时文案改为当前限制，涉及 Runtime、MCP 和 UI 提示（裁决第 4 条）。
- #217：真机运行时发现，确认等待超过 CLI 接收超时后，脚本仍会继续执行。修复后同一个 requestId 只提交一次，结果不明确时用 `request show` 查询，不会重复提交写入。

## 真机验收（Touch ID）

**第一阶段：通过。** 以下转录自 PR #217 的验证记录，本文件作者没有在现场：

- Kevin 本人参与身份验证；构建为 main `7fa1b15` 的签名构建，脚本为带 #217 修复的版本；
- 结果：15 项通过，0 项失败，退出码 0；
- 通过的检查：配对、仅查看授权、拒绝、冷却、撤销、审计中无窗口标题；
- 拒绝和撤销都实际触发了超时后的结果查询，没有重复提交请求；
- 清理核实通过：显示器、测试进程、钥匙串搜索列表都已恢复，临时钥匙串和临时目录已删除。

按 Kevin 的裁决，这次运行使用了一个临时虚拟显示器，只允许用于本次验收。脚本中出现的 `bind_requires_grant` 只能证明 #145 的封堵仍然有效。

**第二阶段：未完成。** 已授权窗口上的观察、绑定和实际输入，还没有在真实 Desktop 上做过端到端验证。#143 已合并（`e771e3b`），但 `physicalDesktopsEnabled` 仍为关，`bindsOnlyLaunchedProcesses` 仍为开。阻断原因和进展见 #168。第一阶段通过，不代表第二阶段完成。

## 审核

- Codex：见 PR #205、#212。
- 非作者独立审核：**未进行。** Kevin 合并 #205 时明确豁免了这一项。后续是否需要补做，由 Kevin 决定。
