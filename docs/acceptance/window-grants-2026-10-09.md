# 窗口级授权：测试与验收记录（2026-10-09）

依据：Kevin 2026-10-09 裁决 B。设计：`docs/security/window-grants.md`。PR #205（Draft）。

以下几项分开记录，互不代替：自动化测试、strict 线程池测试、CI、真机验收、独立审核。

## 自动化测试（作者本机）

| 项目 | 提交 | 结果 |
| --- | --- | --- |
| `swift build --build-tests` | c497ae4 | exit 0 |
| `swift test`（全部） | c497ae4 | exit 0，1069 个测试通过（机器负载 24–36） |
| `RuntimeWindowGrantTests` 等相关目标 | cf965a6 | exit 0 |

新增 `Tests/AgentDesktopRuntimeTests/RuntimeWindowGrantTests.swift`，共 19 个测试：

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

PR #205，提交 cf965a6：`macOS` 与 `windows contracts` 都通过（run 37948499564、37948499566）。

## 真机验收（Touch ID）

**尚未进行。** 只能由 Kevin 本人执行：`scripts/bundle-app.sh && ALLOW_VIRTUAL_DISPLAY=1 scripts/window-grant-touchid-acceptance.sh`。

物理 Desktop 在产品里仍是关的，所以授权只能建在虚拟 Desktop 上，需要创建一个虚拟显示器，是否允许由 Kevin 决定。不允许的话，这一步改在 #143 集成后、在物理 Desktop 上进行。

## 审核

- Codex：见 PR #205。
- 非作者独立审核：**尚未进行。** 作者会话没有做子代理自审；即使做了，也不算独立审核。
