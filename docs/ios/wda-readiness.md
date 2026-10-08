# WDA / XCTest 真机后端：就绪清单与验收

状态：**客户端代码与单元测试已完成；真机从未运行。** 本页所有真机用例状态均为 `NOT_RUN`。

依据：《AgentDesktop · iPhone 实现审查与技术选型》（2026-10-08）第 5.1、5.3、6.1、6.2 节与测试矩阵 I04、I09、I11、I12、I14。

## 1. 现在有什么

| 部分 | 位置 | 状态 |
| --- | --- | --- |
| Swift WDA HTTP 客户端 | `Sources/AgentDesktopIOS/WDA/` | 已实现，mock 测试通过 |
| 能力探测 `probe()` | `Sources/AgentDesktopIOS/WDA/WDAProbe.swift` | 已实现，mock 测试通过 |
| 单元测试（进程内 `URLProtocol` 桩） | `Tests/AgentDesktopIOSTests/` | `swift test --filter AgentDesktopIOSTests` |
| WDA runner 的构建、签名、启动、端口转发 | 无 | 需要 Xcode 与真机，本机没有 |
| 接入 Runtime（设备会话、租约、ActionReceipt） | 无 | 归 Runtime 线，见第 7 节 |

客户端只对一个已经在手机上运行、HTTP 可达的 WebDriverAgent runner 说话。runner 怎么起来、谁签名、端口怎么到 Mac，都在本页第 2–4 节，不在客户端里。

客户端行为要点：

- 会话：首次调用时 `POST /session`（W3C `capabilities.alwaysMatch/firstMatch`），之后复用；`rebuildSession()` 先尽力 `DELETE` 旧会话再建新会话；`adoptRunnerSession` 可接管 runner 已有会话（默认关闭）。
- `POST /session` 按“会改变手机状态的命令”对待：`sessionCapabilities` 带 `bundleId` 时，建会话可能启动 App 或把它切到前台。请求发出后超时或断线，报 `delivery = unknown`（不是 `rejected`）；连接被拒等确定没发出的情况仍是 `notSent`。
- 同一时刻只有一个建会话请求在跑，它只受 `sessionCreateTimeout` 约束，不继承发起者的 deadline；每个等待方（包括发起者）都按自己的 deadline 有界等待，超时报 `timeout / unknown`，建会话本身可能仍会完成并被缓存。
- 观察 `observe()`：截图、窗口尺寸、scale、方向四次读取固定在同一个会话上，不会中途悄悄换会话；中途会话失效或代次变化，整次观察重拍一次，第二次仍变化则报 `sessionInvalid`，绝不把两个会话的截图和几何拼在一起。
- 会话失效（W3C `invalid session id` 或旧式 status 6）：客户端丢弃会话。读操作（status、截图、元素树、几何）在新会话上**重试一次**；输入动作**从不重试、从不重放**，直接向调用方报 `sessionInvalid / rejected`，下一次调用自然落在新会话。
- 手势全部走 W3C Actions（`POST /session/:id/actions`，单个 `touch` 指针 `finger1`）：
  - tap：move(0) → down → pause 50ms → up
  - swipe：move(0) → down → move(duration) → up
  - drag：move(0) → down → pause(hold，默认 600ms) → move(duration) → pause 150ms → up
  - longPress：move(0) → down → pause(duration) → up
  - 不使用已移除的 JSONWP TouchActions（`/touch/perform`、`/wda/touch/*`、`/wda/dragfromtoforduration` 等）。
- 文本：`/wda/keys` 或 `/element/:eid/value`，按字素簇拆成数组（emoji 组合、国旗不会被拆开），请求体 UTF-8。文本里有换行默认拒绝（换行在 iOS 上等于按 Return，可能提交表单）；确需换行显式传 `allowLineBreaks`。
- 其他：`/wda/apps/launch`（按 bundleId 启动）、`/wda/homescreen`（Home）、`/wda/activeAppInfo`、`/source`、`/screenshot`、`/window/size`、`/wda/screen`、`/orientation`、`/element`、`/element/:eid/click`。
- 每个请求都有上限：配置的请求超时，被调用方 deadline 进一步缩短；整次往返用任务竞速限时（`URLRequest.timeoutInterval` 只是空闲超时）。deadline 已过则**不发送**。
- 错误分类 `WDAErrorKind`：`runnerUnreachable`、`sessionInvalid`、`noSession`（没有会话且本次调用不允许新建，如 `probe()`）、`elementNotFound`、`timeout`、`unsupportedEndpoint`、`invalidArgument`、`wdaRejected`、`invalidResponse`。
- 投递状态 `WDADeliveryState`：`notSent`（没发出去）、`rejected`（WDA 明确拒绝，命令没执行）、`accepted`（WDA 回了成功）、`unknown`（发出后超时/断线，或手势中途报错——**可能已经发生，不得自动重放**）。
- 成功的输入返回 `WDAActionEvidence`，`delivery = accepted`、`effect = not_verified_by_client`。客户端从不声称效果已确认；是否生效由 Runtime 以新观察判定并写正式 ActionReceipt。

## 2. 真机跑通的前提

| 项 | 要求 | 说明 |
| --- | --- | --- |
| Xcode | 完整 Xcode（不是 CommandLineTools），版本须能支持手机的 iOS 版本 | iOS 17 及以上真机需要 Xcode 15 及以上；更新的 iOS 一般需要同代 Xcode。手机 iOS 比 Xcode 新时，Xcode 会提示缺少设备支持，runner 装不上。本机目前只有 CommandLineTools，没有 `xcodebuild` 测试能力和 `devicectl`。 |
| Apple 开发者签名 | 一个 Team（个人免费 Apple ID 或付费开发者账号） | WebDriverAgentRunner 是 XCTest UI 测试包，必须用开发证书签名并有匹配的 provisioning profile。免费个人 Team 的 profile 7 天过期，需要定期重签；付费账号为 1 年。 |
| Bundle ID | 改成自己 Team 下唯一的 ID | 默认 `com.facebook.WebDriverAgentRunner` 已被占用，免费 Team 无法注册。改成例如 `com.<你的前缀>.WebDriverAgentRunner`。 |
| Developer Mode | iOS 16 及以上必须开启 | 设置 → 隐私与安全性 → 开发者模式 → 开启，手机重启后再确认一次。该开关通常要先用 Xcode 连过一次手机才会出现。 |
| UI Automation | 开启 | 设置 → 开发者 → 启用 UI 自动化（Enable UI Automation）。关闭时 XCTest 无法驱动界面。 |
| 设备信任 | 手机信任这台 Mac | 首次 USB 连接时手机弹“要信任此电脑吗”，选信任并输入锁屏密码。 |
| 开发者证书信任 | 免费 Team 需要 | 首次安装 runner 后：设置 → 通用 → VPN 与设备管理 → 开发者 App → 信任。 |
| 连接方式 | USB（首选）或同一局域网 | 首次配对与安装建议 USB。runner 起来后也可通过 Wi-Fi 访问手机 IP（`/status` 的 `ios.ip`）。 |
| 端口 | Mac 上能访问 runner 的 8100 端口 | 见第 4 节。 |
| 手机状态 | 解锁，测试期间不自动锁屏 | 设置 → 显示与亮度 → 自动锁定 → 永不（仅测试期间）。锁屏会让 XCTest 会话失效。 |

另外注意（审查报告 5.3）：**不要同时用 Apple iPhone Mirroring 和 WDA 操作同一台手机。** Mirroring 要求手机锁定，WDA 要求手机解锁，两者会话互相影响。首版一个后端同时负责自己的观察和输入。

## 3. 首次接入清单（一步步）

以下步骤**全部未在本机执行过**，是按 Appium / WebDriverAgent 官方真机准备文档整理的操作顺序。

1. 安装完整 Xcode（App Store 或 developer.apple.com），启动一次，接受许可，安装附加组件。确认 `xcode-select -p` 指向 `/Applications/Xcode.app/Contents/Developer`。
2. Xcode → Settings → Accounts 登录 Apple ID，确认出现 Team。
3. 用 USB 连接 iPhone，手机上点“信任”。在 Xcode → Window → Devices and Simulators 看到设备，等待“准备设备”完成。记下 UDID（Identifier）。
4. 手机打开开发者模式（重启后确认），再打开 设置 → 开发者 → 启用 UI 自动化。
5. 获取 WebDriverAgent 源码（appium/WebDriverAgent 的发布版本；记录所用版本号，验收证据要写）。
6. 打开 `WebDriverAgent.xcodeproj`，对 `WebDriverAgentLib` 与 `WebDriverAgentRunner` 两个 target：Signing & Capabilities 选自己的 Team，勾选自动签名，把 Bundle Identifier 改成唯一值。
7. 构建并运行 runner（命令行任选其一）：
   ```bash
   # 一次构建 + 运行
   xcodebuild -project WebDriverAgent.xcodeproj -scheme WebDriverAgentRunner \
     -destination "id=<UDID>" -allowProvisioningUpdates \
     DEVELOPMENT_TEAM=<TEAM_ID> test

   # 或者先构建，之后每次只启动（更快）
   xcodebuild -project WebDriverAgent.xcodeproj -scheme WebDriverAgentRunner \
     -destination "id=<UDID>" -allowProvisioningUpdates \
     DEVELOPMENT_TEAM=<TEAM_ID> build-for-testing
   xcodebuild -xctestrun <DerivedData 里生成的 .xctestrun> \
     -destination "id=<UDID>" test-without-building
   ```
   日志出现 `ServerURLHere->http://<手机IP>:8100<-ServerURLHere` 表示 runner 已监听。
8. 免费 Team：首次安装后在手机上信任开发者证书，再重复第 7 步。
9. 把 8100 端口带到 Mac（第 4 节），执行 `curl http://127.0.0.1:8100/status`，应看到 `"ready": true`。
10. 用本模块做只读探测（探测本身不会改变手机；其中 `ensureSession()` 一行会建会话，是否执行由你决定）：
    ```swift
    let client = WDAClient(configuration: WDAConfiguration(
        baseURL: URL(string: "http://127.0.0.1:8100")!, deviceUDID: "<UDID>"))
    // probe() 自己从不建会话（POST /session 可能启动 App）。没有会话时，
    // 截图、元素树、手势路由都记为 unverified（证据写 noSession）。
    // 要探测这些项，先显式建会话（或打开 adoptRunnerSession 接管 runner 已有会话）：
    try await client.ensureSession()   // 带 bundleId 时可能启动 / 前台化该 App
    let report = await client.probe()
    // report.capabilities: screenshot / elementTree 直接观察到才是 supported；
    // screenshot 只看截图路由本身；几何端点（window/size、wda/screen、orientation）缺失
    // 只让 report.observationState 变成 unverified，不影响 screenshot 能力；
    // tap / swipe / drag / longPress / appLaunch 只证明路由存在，仍是 unverified；
    // unicodeText / home 不在探测里发送；audio 恒为 unsupported。
    ```
11. 逐项执行第 6 节的真机验收，把通过记录作为 `probe(acceptedOnDevice:)` 的输入，相应能力才会变成 `supported`。

## 4. 端口转发

| 方式 | 命令 | 备注 |
| --- | --- | --- |
| iproxy（libimobiledevice） | `iproxy 8100 8100 -u <UDID>` | 通过 usbmuxd 走 USB；需 `brew install libimobiledevice`。 |
| pymobiledevice3 | `pymobiledevice3 usbmux forward 8100 8100` | Python 工具，同样走 usbmuxd。 |
| 局域网直连 | `baseURL = http://<手机IP>:8100` | 不需要转发；手机与 Mac 同一网段，IP 从 runner 日志或 `/status` 的 `ios.ip` 取得。公司网络可能隔离客户端。 |
| Appium 托管 | Appium XCUITest driver 自动启动 runner 并转发 | 见第 5 节。 |

Xcode 本身不提供 Mac 本地端口转发；“Xcode 自带方式”即上面的局域网直连：runner 由 `xcodebuild` 拉起后监听手机 IP。

多台手机：每台用不同本地端口（如 8100、8101），`WDAConfiguration.deviceUDID` 填对应 UDID，两个 `WDAClient` 互不共享状态。

## 5. Appium 包装 vs 直接 WDA client

| 维度 | Appium + XCUITest driver | 直接 WDA client（本模块） |
| --- | --- | --- |
| runner 生命周期 | driver 负责构建、安装、启动、重启 runner，自动端口转发 | 需要自己写 runner 启停（`xcodebuild test-without-building` 进程管理）和转发 |
| 签名诊断 | 有现成的 `xcodeOrgId`、`updatedWDABundleId` 等能力与错误提示 | 自己解析 `xcodebuild` 输出 |
| 依赖 | Node.js、Appium 服务、driver 插件；多一跳 HTTP | 只有 Foundation；产品包里不带 Node |
| 协议 | W3C WebDriver + Appium 扩展（`mobile:` 命令） | WDA 原生路由；版本变化需自己跟 |
| 会话恢复 | driver 处理部分 runner 崩溃重连 | 本模块已有会话失效检测与重建；runner 崩溃后的重启要另做 |
| 适合阶段 | 首轮跑通与对照基线（审查报告 5.1 建议先用它验证需求） | 需求稳定、操作集合确定后做产品内置 |

建议顺序（与审查报告一致）：先用标准 Appium + WDA 跑通第 6 节验收，取得基线数据；再决定产品是保留可选 Appium 服务，还是用本模块直连 WDA。两种包装都放在同一个 backend 接口后面。本模块直连的是同一个 WDA runner，所以 Appium 拉起的 runner 也能被本模块的 `WDAClient` 直接访问（Appium 默认把 runner 转发到 8100），可用于对比。

## 6. 真机验收（全部 NOT_RUN）

通用记录要求：Mac 与 iPhone 系统版本、设备型号、Xcode 版本、WDA 版本、连接方式（USB/网络）、运行次数、每次操作的 `WDAActionEvidence`、前后截图、输入到画面变化的 p50 / p95。`delivery = accepted` 或 HTTP 200 **不算通过**，必须以新的手机画面或元素树确认效果。

### I04 宿主隔离 — NOT_RUN

目的：证明 WDA 的 `usesPhysicalPointer / mayTemporarilyActivateApp / borrowsHostFocus / usesHostClipboard` 全部为 false（目前只是设计声明）。

1. Mac 上打开文本编辑器并持续键入，同时移动鼠标；开启屏幕录制记录指针与前台应用。
2. 期间脚本依次执行：tap、Home、`typeText("测试abc")`、swipe，各 10 次。
3. 每次动作前后记录：鼠标位置（`NSEvent.mouseLocation`）、前台 App、key window、Mac 剪贴板 `changeCount`。
4. 通过标准：指针位置与轨迹只受人控制；前台 App、焦点不变；Mac 编辑器收到的字符与人键入一致，没有串入；剪贴板 `changeCount` 不变；手机上的动作效果经截图确认。

### I09 文本 — NOT_RUN

1. 在备忘录（或测试 App）的普通文本框中，分别输入：纯中文、纯英文、中英混合、emoji（含肤色修饰、ZWJ 家庭、国旗）、标点全角/半角。
2. 每类用 `/wda/keys` 和 `/element/:eid/value` 两条路径各 5 次。
3. 用 `/source` 读回字段 value 并与原文逐字比较；记录不一致的字符。
4. 多行：`allowLineBreaks: true` 输入两行，确认没有触发提交；`allowLineBreaks: false` 时被拒且手机无变化。
5. 切换到第三方键盘（如搜狗、微信键盘）重复第 1 步，记录差异。
6. 安全文本框（密码）：输入后无法读回，结果记为“未确认”，不得记为通过。
7. 通过标准：非敏感字段逐字一致；不发多余换行；失败类型按字符类别公布。

### I11 断线与恢复 — NOT_RUN

1. 正常会话下执行一次 tap，记录 sessionId。
2. 分别制造：手机锁屏再解锁、拔 USB 再插、杀掉 `xcodebuild`（runner 崩溃）并重启、Wi-Fi 切换（网络直连时）。
3. 每种情况下：先发一次读（截图），再发一次输入。
4. 期望：runner 不可达时报 `runnerUnreachable`；会话失效时读操作在新会话成功、输入报 `sessionInvalid` 且**不被重放**；手机画面证明失效时发出的那次输入没有执行；之后的新输入落在新 session。
5. 两台手机时：拔掉 A 的线，B 的 client 状态不受影响，A 恢复后不会连到 B 的端口（`deviceUDID` 与端口对应正确）。
6. 制造一次 `unknown`（在手势进行中拔线），确认上层没有自动重放，并以截图人工判定是否发生。

### I12 手势 — NOT_RUN

1. 长列表（设置 → 通用 → 关于本机 之类的长页面或测试 App）：swipe 上下各 10 次，截图对比滚动距离。
2. 嵌套滚动区（横向卡片 + 纵向列表）：水平 swipe 只滚动内层。
3. 边缘手势：从屏幕左边缘右滑返回；从底部上滑回主屏（如 runner 允许）。
4. 长按：主屏图标长按弹出菜单；文本长按出现选择菜单；时长 0.5s / 1s / 2s 各测。
5. 拖动：主屏编辑模式下拖动图标到另一位置；列表重排。调 `hold` 与 `duration` 找最低可靠值。
6. 通过标准：每次以手机画面变化确认；记录成功率与 p50/p95；任何一次未触发都要记录参数。通过后把记录填进 `probe(acceptedOnDevice:)` 对应项。

### I14 并发与多设备 — NOT_RUN

1. 一台手机、两个任务同时请求输入：在 Runtime 设备会话接入前，本客户端不做串行；预期由 Runtime 设备租约串行化。本用例需等 Runtime 线接入后执行。
2. 两台真机（不同 UDID、不同端口）各跑独立任务 10 分钟，交替 tap/swipe/typeText。
3. 通过标准：同一台手机上的动作严格串行；两台手机互不干扰，证据里的 targetId / sessionId 不串；任何一台断线不影响另一台。

## 7. 需要 Kevin 本人做的事

这些都需要本人账号、实体设备或管理员权限，代理无法代做：

1. **安装完整 Xcode**（体积大，需 Apple ID 下载；首次启动接受许可、安装组件，这一步需要管理员密码）。
2. **Apple 开发者签名**：在 Xcode 登录 Apple ID，选定 Team（免费个人 Team 可用但 7 天过期；长期使用建议付费开发者账号）；决定 WDA 的 Bundle ID 前缀。
3. **手机开开发者模式**（重启确认），并打开“启用 UI 自动化”。
4. **接线并信任电脑**：USB 连接，手机上点信任、输入锁屏密码；免费 Team 还要在手机上信任开发者证书。
5. **确认用哪台手机做测试机**：WDA 会改变手机前台 App 和状态，测试期间手机需要解锁、不自动锁屏，不要同时用 iPhone Mirroring。
6. 决定是否安装 `libimobiledevice`（iproxy）或 Appium（Node.js）作为首轮工具。
7. 以上完成后告诉代理 UDID 与 runner 地址，代理再按第 6 节执行验收并回填结果。

## 8. 与契约的对齐

本模块的类型刻意不依赖并行线（W3 在 `docs/ios/` 起草的契约），字段按审查报告 6.2 命名，便于逐项映射：

| 报告 6.2 | 本模块 |
| --- | --- |
| Target：targetId、kind=ios、backend、deviceIdentity、identityConfidence | `IOSTarget`（`identityConfidence` 取 `configured_udid` 或 `runner_endpoint`；WDA `/status` 不报 UDID，没配置时不伪造） |
| Observation：observationId、targetId、capturedAt、imagePixelSize、contentRect、orientation、geometryVersion、backendSessionId | `WDAObservation`（另带 `screenScale` 与 PNG） |
| Capabilities：tap、swipe、longPress、unicodeText、elementTree、appLaunch、audio + 版本/证据/条件 | `IOSCapability`（另加 drag、screenshot、home） |
| Host effects：真实指针、前台激活、焦点借用、宿主剪贴板 | `IOSHostEffects`（WDA 全为 false，`basis` 注明 I04 未跑） |
| ActionReceipt：Runtime 唯一写入 | 客户端只给 `WDAActionEvidence`，`effect` 恒为 `not_verified_by_client` |

契约定稿后，由 Runtime 侧的适配层把这些类型转换成正式契约类型；本模块不反向依赖契约。
