# 启动归属证明验收（#151，2026-10-09）

依据：Kevin 2026-10-09 对 #151 的裁决。

- 两个条件必须同时成立：**应用准入**（用户授权哪些应用可以启动，属于 SEC-04，由 #137 实现）和**归属证明能力**（能证明进程确实由这次启动创建，即本 PR）。
- 本 PR 只实现 L1：一次性启动令牌经 LaunchServices 写入进程环境，打开后通过 `KERN_PROCARGS2` 读回核对。
- 证明不了的应用，在打开之前就拒绝。

## 一、首批真机验证（`run1-first-batch.json`）

工具：`verify_launch_token.swift`。它按引擎完全相同的方式打开应用：
- 新开实例，不激活；
- 不加入“最近使用”，不弹提示；
- 带一次性令牌。

打开后读回进程环境。退出时使用打开时返回的句柄，并把前台还给原来的应用。用户正在运行的应用不启动、不触碰，只统计内核能看到它多少个环境变量，不读取任何值。

| 应用 | 结果 | 依据 |
| --- | --- | --- |
| TextEdit | **无法证明** | 读不到环境（0 个变量）；已通过句柄退出，没有残留进程 |
| Calculator | **无法证明** | 同上 |
| Terminal | **无法证明** | 同上 |
| Safari | 未验证 | 用户正在使用，没有启动；运行中的实例能看到 0 个变量 |
| Google Chrome | 未验证 | 用户正在使用，没有启动；运行中的实例能看到 0 个变量（与 b9 实测一致：Chrome 会改写自己的环境） |
| WeChat | 未验证 | 用户正在使用，没有启动；运行中的实例能看到 12 个变量。这只说明它是候选，没有实际启动核对过，不能据此加入名单 |
| 自建探针 .app（对照组） | **可以证明** | 读回令牌，说明验证方法本身有效 |

结论：
- Apple 自带应用（TextEdit、Calculator、Terminal）都无法证明归属，macOS 会隐藏平台二进制的进程环境。
- 验证名单 `LaunchOwnership.verifiedApps` 保持为空。
- 这是一份待验证清单，不是允许启动清单。

## 二、验证记录的内容

`VerifiedApp` 记录以下字段，打开前要求逐项完全一致：
- 当时验证的签名身份：Bundle ID、Team ID、签名标识、版本号、构建号，以及**指定要求**（designated requirement，用来锁定签发方：Apple 自带应用为 `anchor apple`，第三方应用为其证书链）；
- 证明方式（`launch_token_env`）；
- 验证日期。

应用升级、换了团队、签名或签发方、签名校验不通过，都在打开前拒绝，需要重新验证。

签名校验采用严格模式，并检查嵌套代码，在主线程之外进行。ad-hoc 签名的代码没有可锁定的签发方，它的指定要求只是一个哈希，因此读不出身份，永远匹配不上验证记录（b9 第四轮复审）。

### 残余风险

- **签名读取与打开之间存在时间差。** 读取签名身份之后、LaunchServices 打开应用之前，磁盘上的应用如果被替换，打开的就会是替换后的版本。
  - 这需要攻击者已经能以同一用户身份改写 `/Applications` 里的应用。
  - 令牌核对仍然有效：被打开的进程必须带有这次的令牌，才会被移动和绑定。
- **应用自行重启时可能留下窗口。** 应用启动后把自己重启成另一个进程时，那个进程无法证明是这次启动的，所以不移动、不绑定、不退出。它的窗口可能留在用户屏幕上，引擎会返回明确的错误说明这一情况。

## 三、主窗口独立于 `app.launch`（测试副本，2026-10-09 11:23）

- 本分支的构建（`scripts/bundle-app.sh`，源码 2b4f6d7）用以下命令启动：
  `open -n -g --env AGENTDESKTOP_SOCKET=/tmp/adt-151/side.sock --env AGENTDESKTOP_MAIN_WINDOW=1`
- Runtime 端点 `/tmp/adt-151/side.runtime.sock`：握手成功，`runtime.status` 成功。
- 主窗口已打开（1440×876，在屏幕上可见）。前台应用前后都没有变化。
- 主窗口由应用自己打开，不经过 `app.launch`。
- 验证名单为空时，`app.launch` 对所有应用在打开前拒绝：
  - 返回 `permission_denied`，`notSent`，`details.reason = no_launch_apps_configured`；
  - 界面提示“未配置允许启动的应用”。
- 名单编译在代码里，运行时任何 Agent 或客户端都无法修改。

测试副本无法经 Runtime 调用 `app.launch`：调用需要先有一个 Desktop，物理 Desktop 已被封堵，而本次验收不创建虚拟显示器。因此“打开前拒绝”用真实系统调用的引擎测试 `aRealLaunchOfAnUnverifiedAppOpensNothing` 验证：
- 以真实的 TextEdit 路径、真实的签名读取和真实的 LaunchServices 配置发起启动；
- 结果为拒绝，原因是 `no_launch_apps_configured`；
- 1 秒后系统中没有任何 TextEdit 进程。

## 四、测试结果

均为清空构建缓存后、在 `714e308`（已合入 main `fefa72e`）上测得：

| 命令 | 结果 |
| --- | --- |
| `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test`（根包） | 866 个测试，全部通过 |
| `swift test --package-path engine` | 242 个测试，全部通过（合入 main 前测得） |
| `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test --package-path engine` | 247 个测试，**没有全绿**：`anOwnerThatExitsDuringTheWaitIsRefused` 不稳定 |

不稳定测试的对照（严格模式，引擎全量，同一时段）：

| 版本 | 次数 | 失败次数 |
| --- | --- | --- |
| 干净 main（e43234e、fefa72e） | 8 | 3 |
| 本分支 | 7 | 2 |

单独运行这条测试时，两边都通过。它是主线原有的计时类不稳定测试（`SecondScreenCoreTests/AgentScreenAdmissionTests.swift`），已另开 issue 跟踪，本 PR 没有放宽它。

另外，增量构建在本分支上出现过 TarsAgent 测试段错误（信号 11）。原因是 `ControlResponse` 新增字段后，构建缓存里还是旧的结构布局；清空 `engine/.build` 后不再出现。CI 每次都是全新构建，不受影响。
