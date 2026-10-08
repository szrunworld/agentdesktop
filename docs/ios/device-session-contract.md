# iOS 设备会话契约草案

状态：**草案，需 f1 审阅**。不改冻结契约；所有“增量”在 f1 写进 `methods.json`、`runtime.schema.json` 与冻结文档前都只是提议。依据：审查报告《AgentDesktop iPhone 实现审查》4.4 与第 6 节；`docs/plan/03-runtime-contract.md`；`contracts/runtime/v1/`（FROZEN_2026_10_08）。

## 0. 原则

1. **不新增平行协议**。iOS 设备走 `agentdesktop.runtime/1` 的同一信封、同一 `observe` / `act` / `run.*`、同一 RunStore 与回执。手机不是另一套 API，而是一种 `targetKind=device` 的 Desktop。
2. **复用现有命名**：观察 ID 就是 `snapshotId`（审查报告里的 observationId），目标 ID 就是 `desktopId`，几何代次就是 `Binding.generation` / 计划中的 `geometryRevision`，请求 ID 就是信封 `requestId`（也是幂等键）。
3. **Runtime 唯一写 ActionReceipt**。后端只返回执行证据；“已投递”和“已确认”分开记录；unknown 不自动重放。
4. **能力按后端如实声明**：supported / unsupported / unverified，附证据与条件；不公布的动作在执行入口拒绝，不降级成点击、不借真实鼠标。
5. **宿主影响分项**：真实指针、前台激活、键盘焦点、宿主剪贴板各自表达，不压成一个“后台”布尔值。

## 1. Target：用 Desktop 表达设备目标

| 审查报告字段 | 现有契约 | 草案 |
| --- | --- | --- |
| targetId | `Desktop.desktopId`；请求 `context.desktopId` | 复用，不新增 targetId |
| kind=ios | 计划字段 `Desktop.targetKind = window \| device`（plannedFields，A5） | 复用 `targetKind=device`；新增 `Desktop.device.kind = "ios"`（Android 可用同一结构的 `"android"`） |
| backend | 无（`runtime.capabilities.backend.features` 只有全局字符串） | **增量** `Desktop.device.backend = "mirroring" \| "wda" \| "coredevice"`；全局 feature 另加 `ios.mirroring` 等（符合现有 `^[a-z]+(\.[a-z][a-zA-Z]*)+$`） |
| deviceIdentity | 无；Mirroring 现在只能拿到 `Binding.process{pid,startedAt}` + `windowId` | **增量** `Desktop.device.identity = {scheme, value}`，scheme 为 `udid`（WDA、CoreDevice 可得真实 UDID）或 `session`（Mirroring） |
| identityConfidence | 无 | **增量** `Desktop.device.identityConfidence = verified \| session_only \| unknown` |
| backendSessionId | 无 | **增量** `Desktop.device.backendSessionId`：Mirroring 为镜像进程一次启动（`pid + startedAt`）；WDA 为 WebDriver session id；CoreDevice 为隧道/服务会话 id |
| 连接状态 | 计划字段 `Desktop.control.state`（含 disconnected、error） | **增量** `Desktop.device.connection = ready \| phone_in_use \| disconnected \| auth_required \| reconnecting \| needs_user`；`control.state` 仍按 03 §3.4 派生，connection 非 ready 时 Runtime 关闭该 Desktop 的输入准入 |

**Mirroring 的身份限制（必须写明）**：iPhone Mirroring 不向 Mac 暴露 UDID 或其他稳定的物理设备标识。`identity.scheme=session`，value 取镜像会话（`ScreenContinuity` 进程 `pid + startedAt`），`identityConfidence=session_only`。含义：
- 只能保证“同一次镜像会话”，不能证明是哪一台物理手机；镜像进程重启后视为新会话，旧观察全部作废。
- Apple 规定一台 Mac 同时只镜像一台 iPhone，因此 Mirroring 后端全机最多一个设备目标；不得虚报多机。
- 不得伪造 UDID，也不得把手机名称（用户可改）当身份。

## 2. Observation

| 审查报告字段 | 现有契约 | 草案 |
| --- | --- | --- |
| observationId | `Observation.snapshotId`；`act_params.snapshotId` | 复用 |
| targetId | `Observation.desktopId` | 复用 |
| capturedAt | `Observation.capturedAt` | 复用 |
| imagePixelSize | `Observation.image.width/height`（ImageArtifact） | 复用 |
| 坐标换算 | `image.transform{originX, originY, scale}`：全局点 = origin + 像素 / scale | Mirroring 复用（全局点）。WDA/CoreDevice 没有 Mac 全局点：**增量** `image.transform.space = host_global \| device_points`（缺省 host_global，向后兼容） |
| contentRect | 无（`target.windowFrame` 是窗口框，含镜像边框） | **增量** `Observation.device.contentRect`：图像中手机画面的像素矩形；坐标只在其内有效 |
| orientation | 无 | **增量** `Observation.device.orientation = portrait \| landscape_left \| landscape_right \| unknown` |
| geometryVersion | `ObservedTarget.generation`（绑定代次）；计划字段 `Observation.geometryRevision` | 复用 `geometryRevision`；镜像窗口移动、缩放、旋转都加一 |
| backendSessionId | 无 | **增量** `Observation.device.backendSessionId`，与 Desktop 的一致才可执行 |
| Mirroring 的 PID / windowID | `ObservedTarget.process` / `windowId` | 复用；输入必须发往这个 windowId，而不是“最前普通窗口”（审查 4.3，W2） |
| elements | `Observation.elements`；计划 `coverage{ax, screenshot, ocr}` | Mirroring：`elements=[]`、`coverage.ax=false`；WDA 可给元素树 |
| 设备状态页 | 无 | 观察只读：遇到 “iPhone in Use” 等状态页返回错误并更新 `device.connection`，**不在观察里自动重连**；重连是独立动作 |

## 3. Capabilities 与 HostEffects

现有 `runtime.capabilities` 只描述宿主与方法目录。设备能力随目标变化，草案放在 Desktop 上：

```text
Desktop.device.capabilities = [
  { capability: tap | swipe | drag | longPress | scroll | unicodeText | editingKeys
                | elementTree | appLaunch | home | appSwitcher | spotlight | audio,
    support: supported | unsupported | unverified,
    evidence: deviceTested | sourceOnly | none,
    basis: string, conditions: [string],
    backendVersion?: string, probedAt?: Timestamp,
    hostEffects?: { usesPhysicalPointer, mayTemporarilyActivateApp, borrowsKeyFocus, usesHostClipboard } }
]
```

- Mirroring 的取值以 `engine/Sources/TarsAgent/IPhoneCapabilities.swift` 为唯一来源，单元测试保证它与 `TarsAgent.iPhoneActionSpaces` / `forIPhone()` 公布给模型的动作一致（不公布的手势必须是 unsupported）。
- 执行入口：action 对应能力不是 supported → 拒绝，`delivery=not_dispatched`。错误码复用已有 `capability_missing`，或 03 §3.5 预留的 `unsupported_backend`（**f1 决定用哪个**；建议：后端根本不支持用 `unsupported_backend`，unverified 用 `capability_missing` + `details.support="unverified"`）。
- `unverified` 默认不公布；只有显式的验收/探测 Run 可以调用。
- GuiExplorer / 模型动作集合由这里的 supported 能力构造，而不是写死在 prompt 里（审查 6.1 AgentDesktopGui）。

Mirroring 当前声明（摘要，详见代码）：

| 动作 | 能力 | 指针 | 前台激活 | 焦点借用 | 宿主剪贴板 |
| --- | --- | --- | --- | --- | --- |
| tap | supported | 否 | **可能**（点击可能把镜像短暂置前，`BackgroundInput.click` 随后把用户应用切回前台） | **是**（focusWithoutRaise → restoreFocus） | 否 |
| type（粘贴） | supported | 否 | **可能**（⌘V 以 holdModifiers 发送不激活；但点按“允许粘贴”走与 tap 相同的点击，可能短暂置前） | 是（点按“允许粘贴”时） | **是**（完整快照全部类型，无法完整保存则拒绝粘贴；手机可能仍在拉取时暂缓恢复） |
| Return / Delete | supported | 否 | 否 | 否 | 否 |
| Home / App Switcher / Spotlight（⌘1/2/3） | supported | 否 | **是**（withMenuShortcutActivation 瞬时置前再恢复） | 否 | 否 |
| swipe / drag / scroll / longPress | unsupported | — | — | — | — |
| elementTree | unsupported | | | | |
| appLaunch（经 Spotlight） | unverified | | | | |
| audio | unverified（只有 Mac 系统音量，无每机音量、无采集） | | | | |

2026-10-04/07 实测：点按、按键、粘贴前后真实指针与前台应用未见变化；上表“是”取自代码路径，表示**可能**发生的瞬时影响。

## 4. Action

| 审查报告字段 | 现有契约 | 草案 |
| --- | --- | --- |
| requestId | 信封 `requestId`（幂等键，同键异义 `idempotency_conflict`） | 复用 |
| targetId | `context.desktopId` | 复用 |
| observationId | `act_params.snapshotId` | 复用；执行前校验 `backendSessionId`、`geometryRevision`、windowId 未变，否则 `target_moved`（已预留）或 `stale_observation` |
| lease | Run 租约（“one per Desktop, held by one live Run”），冲突 `control_busy` | 复用；见第 6 节设备级唯一性 |
| deadline | 信封 `deadline`（只限受理等待）；Run 执行限额 | 复用：设备动作的总时限来自 Run 限额，粘贴等待、OCR、许可点按都计入同一 deadline，不按尝试续期 |
| cancelGeneration | 线上无；`docs/ai-gui/interfaces` 有 `ObservationStamp.runGeneration` / `currentGeneration` | **增量（内部为主）**：Runtime 在每次投递前比对当前取消代次，不由客户端传；回执记录 `cancelGeneration`。客户端仍只用 `run.cancel` |
| 坐标 | `action.target.imagePoint`（相对该观察图像） | 复用；必须落在 `device.contentRect` 内，否则 `invalid_target` |
| 动作种类 | `Action.kind = click \| type \| key \| scroll`；计划 `hover \| drag \| press` | tap=`click`；type=`type`；Return/Delete=`key`；**增量**设备导航键名 `key = home \| app_switcher \| spotlight`（由后端翻译：Mirroring 为 ⌘1/2/3，WDA 为 pressButton 等），客户端不直接发 ⌘ 组合；swipe/drag 用计划中的 `drag`（起止点 + 时长）；longPress 用计划中的 `press` 加 `durationMs`（**f1 确认 press 的语义**） |
| 提交 | `type` 文本末尾换行即发 Return | **建议**设备目标上提交为显式 `key=return` 动作，`type` 不隐式提交（审查 4.1） |

## 5. ActionReceipt：投递与确认分离

现有 `ActionReceipt`：`delivery = dispatched | not_dispatched | unknown`，`execution = completed | failed | unknown`，`verification` 固定 `not_requested`，`route`（如 `event.click`），`target{generation, process, windowId, elementRef, point}`，`timing{acceptedAt, dispatchedAt, completedAt}`；计划字段 `reconciliations`、`geometryRevision`、`dispatchSequence`、`elapsedMs`。

| 审查报告状态 | 映射 |
| --- | --- |
| delivered | `delivery=dispatched` |
| 未投递 | `delivery=not_dispatched`（拒绝、取消在投递前） |
| 投递未知 | `delivery=unknown`（可能已发出但证据丢失） |
| confirmed | **增量**（f1 2026-10-08 裁决：不放宽已冻结的 `verification`，它仍只表示调用方是否请求验证）：新增可选字段 `postCondition{state: confirmed \| not_confirmed \| unknown, observationId?, checkedAt?}`，挂在 plannedFields 下，由 f1 纳入目录；`observationId` 与 `docs/ai-gui/interfaces` 的 `confirmationObservationId` 对应 |
| unknown 效果 | `execution=unknown`；只能追加 `reconciliations`，不得自动重放 |

- **后端只给证据**：`BackendEvidence = {route, backendSessionId, dispatchedAt?, steps[{what, at, ok}], beforeArtifactId?, afterArtifactId?, notes}`，由 Runtime 写入回执（**增量** `ActionReceipt.evidence`，或放进现有 `route` + 产物引用，f1 决定）。
- Mirroring `route` 已能区分宿主影响：`event.click`（借焦点）、`event.key.menu`（瞬时激活）、`event.key.held`（粘贴 ⌘V）、`event.key`。建议冻结这些值的含义。
- 粘贴的回执规则：⌘V 已发出 → `delivery=dispatched`；粘贴提示超时、许可点按失败、OCR 未识别 → `execution=unknown`、`postCondition.state=unknown`，**不再发 Return、不重贴**，并在重新观察前拒绝该目标的后续输入；只有核对输入框可见内容（非敏感字段）后才 `postCondition.state=confirmed`。`verification` 保持冻结语义不变。

## 6. 每设备串行租约

- 现有规则：一个 Desktop 一个租约，由一个活的 Run 持有；冲突 `control_busy`。
- **增量**：同一 `device.identity` 只能绑定到一个 Desktop（第二次绑定返回 `conflict`，`details.reason="device_bound"`），这样“每 Desktop 一个租约”就等价于“每台手机一个租约”。Mirroring 因为全机只有一个镜像会话，等价于全局单例。
- 同一台手机上的多个任务排队（同一 Desktop 上的 Run 串行）；不同真机（WDA/CoreDevice）可以并行。
- 人工接管沿用计划中的 `desktop.takeover` / `handback`（`origin=user` 的租约 Run）。手机解锁会结束镜像：Runtime 把它当作 `device.connection=phone_in_use`，关闭输入准入，正在进行的动作按 unknown 处理。

## 7. 宿主剪贴板租约

- 剪贴板是**宿主级**资源，跨 Desktop、跨 Run、跨 CLI/MCP/Agent 进程共享，不能只靠单个 CLI 进程的锁（审查 4.2）。
- **增量**：Runtime 内部 `ClipboardLease`，全宿主同一时间只有一个持有者；粘贴事务（快照 → 写入 → ⌘V → 等待许可/完成 → 恢复）整体在租约内，受 Run deadline 与取消约束。
- 快照全部 pasteboard items 与 types；恢复前检查 `changeCount` 仍是自己写入的那次（用户中途复制则不覆盖）；无法无损快照时不清空、拒绝本次输入（建议 `conflict`，`details.reason="host_clipboard_unavailable"`；租约被占用时 `control_busy`，`details.reason="host_clipboard"`）。
- 能力声明里 `usesHostClipboard=true` 的动作必须走这个租约；Android（手机端剪贴板）与 WDA/CoreDevice 能直接输入 Unicode 时不需要它。
- 线上不新增方法：租约对客户端不可见，只在回执证据和事件里出现（如 `device.clipboard.acquired/released`）。

## 8. 需要 f1 决定 / 新增 / 冻结的增量清单

| # | 增量 | 类型 | 建议 |
| --- | --- | --- | --- |
| 1 | `Desktop.targetKind=device` 提前冻结，并加 `Desktop.device{kind, backend, identity{scheme,value}, identityConfidence, backendSessionId, connection, capabilities[]}` | 可选字段 | iOS 与 Android 共用 |
| 2 | `Observation.device{contentRect, orientation, backendSessionId}`；计划字段 `geometryRevision` 同期落地 | 可选字段 | — |
| 3 | `ImageTransform.space = host_global \| device_points` | 可选字段，缺省 host_global | WDA/CoreDevice 需要 |
| 4 | 能力条目结构（support / evidence / basis / conditions / hostEffects） | 新对象 | 以 `IPhoneCapabilities` 为参照 |
| 5 | 设备导航键名 `home \| app_switcher \| spotlight`；`press` 是否带 `durationMs` 表达长按；`drag` 的时长 | Action 计划字段的语义 | — |
| 6 | 新增可选 `ActionReceipt.postCondition{state: confirmed \| not_confirmed \| unknown, observationId?, checkedAt?}`（plannedFields） | 新增可选字段；**不**改 `verification`（f1 2026-10-08 裁决：冻结规则 1 不允许扩大已冻结枚举） | 关键 |
| 7 | `ActionReceipt.evidence`（后端证据）与 `cancelGeneration` | 可选字段 | — |
| 8 | 冻结 `route` 取值含义：`event.click` / `event.key` / `event.key.menu` / `event.key.held` | 文档 | — |
| 9 | 不支持动作的错误码：`unsupported_backend`（预留）与 `capability_missing`（已有）分工 | 错误码语义 | 见第 3 节 |
| 10 | 设备唯一绑定：`conflict` + `details.reason="device_bound"` | 规则 | — |
| 11 | 宿主 `ClipboardLease`（Runtime 内部）与其 `details.reason` 值、事件名 | 内部实现 + 事件 | 与 W1 粘贴修复对齐 |
| 12 | 设备目标上 `type` 不隐式提交 | 行为规则 | 审查 4.1 |
