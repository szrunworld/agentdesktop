# iOS 后端如何落到同一接口（草案）

状态：**草案，需 f1 审阅**。只写接口要求，不写实现。三个后端都实现同一组后端操作，由 Runtime 的设备会话（每设备串行、状态机、租约、回执）调用；客户端只看到 [device-session-contract.md](device-session-contract.md) 里的 Desktop / Observation / Action / ActionReceipt。

## 1. 后端接口（Runtime 内部，非线协议）

| 操作 | 输入 | 输出 | 要求 |
| --- | --- | --- | --- |
| `discover()` | — | 设备列表 `{identity, identityConfidence, name, osVersion?}` | 不得把“已连接”当成“能力可用” |
| `open(identity)` | 设备身份 | `backendSessionId`、`connection` | 一个身份同一时间只开一个会话 |
| `capabilities(session)` | 会话 | 能力条目（support / evidence / basis / conditions / hostEffects） | 按实际探测或验收结果给出；未测即 `unverified` |
| `observe(session)` | 会话 | 图像、`contentRect`、`orientation`、`geometryRevision`、可选元素树、`capturedAt` | 只读；不自动重连；失败不返回旧帧或灰帧当成功 |
| `perform(session, action, binding, deadline, isCancelled)` | 已校验的动作 + 绑定的观察 | `BackendEvidence`（route、步骤、时间、前后产物） | 投递前检查取消与 deadline；不公布的动作直接拒绝；**不写回执** |
| `cleanup(session)` | 会话 | 证据 | 抬起触点、松开修饰键、交还剪贴板租约 |
| `reconnect(session)` | 会话 | `connection` | 独立动作，不藏在观察里 |
| `close(session)` | 会话 | 是否确认关闭 | 确认后才返回成功 |

## 2. Mirroring（现有）

| 项 | 落法 |
| --- | --- |
| 身份 | `scheme=session`，`identityConfidence=session_only`；全机最多一个设备目标 |
| 观察 | 绑定 `ScreenContinuity` 进程的具体 windowId；窗口级采集；`space=host_global` |
| 输入 | 宿主事件投递到该 windowId；宿主影响见能力声明（借焦点、瞬时激活、宿主剪贴板） |
| 文本 | 宿主剪贴板 + ⌘V（必须持有宿主 ClipboardLease） |
| 能力 | 以 `engine/Sources/TarsAgent/IPhoneCapabilities.swift` 为准；手势 unsupported |
| 迁移 | 审查 6.1：`IPhoneAgentScreen` 有效部分下沉为 `MirroringBackend`，去掉对 TarsAgent 类型的依赖（W1/W2 之后） |

## 3. WDA / XCTest（W4）

| 项 | 接口要求 |
| --- | --- |
| 身份 | 真实 UDID，`scheme=udid`，`identityConfidence=verified`；两台设备不得误绑 |
| 会话 | `backendSessionId` = WebDriver session；runner 崩溃或重建 → 新会话，旧观察全部作废，进行中的动作按 unknown |
| 观察 | 设备截图，`space=device_points`；有控件树时给 `elements`、`coverage.ax=true` |
| 输入 | 在手机上执行，`usesPhysicalPointer / mayTemporarilyActivateApp / borrowsKeyFocus` 均应为 false（需 I04 真机验证后才能声明）；文本若能直接输入 Unicode，`usesHostClipboard=false` |
| 能力 | tap、swipe、drag、longPress、scroll、elementTree 先为 `unverified`，I09/I12 通过后逐项改为 supported |
| 前提 | 设备信任、Developer Mode、UI Automation、runner 签名与 provisioning；缺失时 `connection=needs_user` 并说明哪一项 |
| 包装 | Appium 或直连 WDA 都藏在同一后端接口后面；协议差异不得泄漏到 runtime/1 |
| 与 Mirroring 共存 | 首版不混用（Mirroring 看画面 + WDA 触控）；一个后端负责自己的观察与输入 |

## 4. CoreDevice（W5，实验）

| 项 | 接口要求 |
| --- | --- |
| 身份 | UDID（`scheme=udid`）；探测失败时 `unknown`，不伪造 |
| 能力 | 逐组合探测（设备型号 + iOS + DDI + 传输 + 服务路径），每条能力带 `backendVersion`、`probedAt` 与探测证据；隧道连通不等于输入可用 |
| 观察 | 屏幕流取帧，`space=device_points`；帧时间与方向必须与输入对象一致 |
| 输入 | HID tap / drag；注意 pymobiledevice3 的 `swipe` 是无接触移动，接触式划动对应 `drag`；HID 文本目前仅 ASCII，中文与 emoji 另行验证，未验证前 `unicodeText=unverified` |
| 定位 | 可选模块，独立版本与能力矩阵；通过与 WDA 相同的 I 用例对比后才能升为正式后端 |
