# Physical Window Desktop（物理窗口 Desktop）

状态：提案 + 最小实现，待 Runtime 负责人审核契约增量。依据：Kevin 2026-10-08 的架构裁决（不为微信 Agent 验收创建虚拟显示器；让 AgentDesktop 能绑定用户现有显示器上的应用窗口，作为通用平台能力）。

## 1. 架构差距

| 层 | 现状（main `e1e4f9f`） | 差距 |
| --- | --- | --- |
| Runtime Desktop | `desktop.create` 只有一条路：`platform.createScreen` 建虚拟显示器 | 没有"引用现有显示器"的 Desktop |
| `window.bind` | 先 `moveWindows` 把窗口搬到 Desktop 的屏上 | 物理场景不能搬用户的窗口 |
| `desktop.destroy` | 退出 `app.launch` 启动的应用，再 `destroyScreen` | 物理场景不能退出用户应用、不能动显示器 |
| `observe` 未绑定 | 截整块屏 | 物理场景会截到用户整块屏幕 |
| 引擎 | `AgentRuntime.handle` 已按名字寻址"宿主屏"（`hostScreens`），截图、读元素、输入同一路径；拒绝销毁/缩放宿主屏 | 产品宿主从未设置 `hostScreens`，物理显示器不可寻址 |
| G0 一致性 | `exposedTarget`：窗口消失、不可见、被遮挡、同进程其他窗口在前 → `stale_observation`；截图裁到窗口；派发后复核 | 无需改动，物理 Desktop 直接复用 |

## 2. 设计

```text
AgentDesktop Runtime（唯一）
  Desktop(kind: virtual)   createScreen → 虚拟显示器（行为不变）
  Desktop(kind: physical)  attachDisplay → 用户现有显示器（不创建任何东西）
        └─ 共用：Session、Run（Delegated/Durable）、observe/act、G0 检查、请求账本、事件、审计
```

物理 Desktop 的规则：

- 创建：`desktop.create {physical: {displayId?}}`，默认主显示器；与 `width/height` 互斥；一块显示器同时只挂一个物理 Desktop（`conflict`）。
- 绑定：必须给 `windowId`；窗口必须已经在该显示器上，否则 `invalid_target`（notSent）；**从不移动窗口**。
- 观察：只截绑定窗口的区域；未绑定时拒绝（`invalid_target`），绝不截整屏。
- 输入：只发往绑定窗口；遮挡、窗口关闭、进程退出、同进程其他窗口在前 → `stale_observation`，notSent，什么都不发（fail closed）。
- `app.launch`：拒绝（`invalid_target`）。
- 解绑/销毁：只清绑定、删记录；不退出应用、不销毁显示器。
- 宿主：`PhysicalDisplays.screens()` 把活动显示器里**非虚拟**的那些登记为引擎宿主屏（按虚拟显示器的厂商号 `0x3256`/型号 2 排除，无论是谁建的）。

## 3. runtime/1 契约增量（只加可选字段，遵守冻结规则 1）

| 位置 | 增量 |
| --- | --- |
| `desktop_create_params.physical` | `{ displayId?: integer ≥0 }`，`additionalProperties: false` |
| `Desktop.kind` | `enum ["virtual","physical"]`，缺省视为 virtual |
| CLI | `agentdesktop desktop create --physical [--display ID]` |
| 夹具 | `desktop-create-physical.valid`、`desktop-create-physical-extra-key.invalid`、`desktop-physical.valid`、`desktop-made-up-kind.invalid` |

未新增方法、错误码或事件类型。`DesktopPlatform` 增加 `attachDisplay(_:)`（带默认拒绝实现，其他平台替身不受影响）。

## 4. 复审第一轮（Kevin 2026-10-08）结论

### 4.1 目标失效与 Run 生命周期：现有契约足够，不新增 `run.target_lost`

| 情况 | Runtime 行为 | 契约中的表达 |
| --- | --- | --- |
| 窗口关闭 / 最小化 / 移到其他显示器 / 被遮挡 / 同进程其他窗口在前 | observe、act 被拒：`stale_observation`，`details.reason` = window_gone / not_visible / occluded / other_window_of_process_in_front，act `notSent=true` | 每次拒绝写 `action.refused`（`reason.code`） |
| 绑定进程退出或重启（pid 复用） | 同上，消息"bound process … exited or restarted"（无 `details.reason`） | 同上 |
| 窗口关闭后重开（新 windowId） | 旧绑定、旧快照都不指向新窗口；只有显式 `window.bind` 才会成为目标，generation +1 | `action.refused`；新绑定可从 `desktop.show` 看到 |
| 窗口 ID 被他进程复用 | 绑定按 (windowId, 进程启动身份) 判定，他进程同号窗口不是目标 | 同上 |
| 派发过程中目标失效 | 回执 `delivery=unknown`、`action_delivery_unknown`，Run `unknownActions+1`；下一次输入在派发前被拒，不自动重试 | `action.unknown` |
| Run 本身 | 不因目标失效自动结束：Delegated Run 由 `run.finish` / `run.cancel` / 控制连接断开结束（ADR v2.2），Durable Run 同其规则 | `run.ended` + `closingReason` |

结论：目标失效后新的观察和输入立即被拒，未确认的投递保持 unknown 且不重试；现有 `action.refused` / `action.unknown` / `run.ended` 足以表达，**不提新事件类型**。可选改进（不阻塞，另行讨论）：进程退出这一条拒绝补上 `details.reason="process_gone"`，与其他原因对齐。

### 4.2 显示器来源识别

`DisplayOrigin.classify` 一次判定全部显示器，结果与显示器顺序无关：内置屏可信；引擎虚拟屏（厂商 0x3256 / 型号 2，无论谁建、即使自称内置）判为虚拟；外接屏必须有硬件帧缓冲（Apple 芯片 IOMobileFramebuffer 的 `LegacyManufacturerID` / `ProductID` / `SerialNumber`，Intel IODisplayConnect 的 `DisplayVendorID` / `DisplayProductID` / `DisplaySerialNumber`）报告**相同的厂商、型号和序列号**，而且声称这个身份的显示器不多于这样的帧缓冲（按厂商 + 型号再查一遍，覆盖不报序列号的帧缓冲）。虚拟屏抄用真实显示器的完整身份时多出一个声称者，**所有**声称这个身份的显示器都判为来源未确认——真实的那块也一起拒绝（fail closed），而不是按枚举顺序先到先得（Codex 在 e0be427 上的意见）。内置屏也计为它自己身份的声称者；注册表标为非外接的帧缓冲（Apple 芯片上只有外接端口带 `external = Yes`）不为任何外接屏担保，所以抄用内置屏身份的虚拟屏也不可信（Codex 在 cb64fce 上的意见）。Intel 机型的 IODisplayConnect 不标内外，此时只靠声称者计数：合盖使内置屏不在活动列表时，抄用内置屏身份的虚拟屏可能通过，这是已知残余。其余判为来源未确认。只有可信显示器登记为宿主屏，其余 `desktop.create {physical}` 返回 `not_found`。真机：另一会话的虚拟屏 9 被拒，内置屏 1 可挂接（run4）；本机外接屏（厂商 25001、型号 49155、序列号 1）与其帧缓冲三项一致（2026-10-10 只读探测）。剩余局限：若虚拟屏抄用了真实显示器的身份，那块真实显示器也无法挂接，直到虚拟屏移除。

### 4.3 "一块显示器一个物理 Desktop"不阻碍多窗口

这是第一版的保守限制，不是模型约束：
- `DesktopRecord` 一个 Desktop 一个绑定窗口；多个 Desktop 指向同一显示器时，各自 G0 检查只看自己绑定的窗口及其遮挡关系，互不依赖。
- 放开限制需要的只是：把唯一性从"每块显示器"改为"每个窗口（进程身份 + windowId）至多被一个 Desktop 绑定"（`ConflictRegistry` 已按进程串行化输入，可扩展到窗口），并把 `desktops.physical(displayId:)` 的冲突检查换成按窗口检查。
- 契约不需要变：`physical.displayId` 与 `Desktop.kind` 已足够。

### 4.4 独立代码审核（2026-10-08）及处理

结论"修改后可合并"。处理如下：

| 审核意见 | 严重度 | 处理 |
| --- | --- | --- |
| `displayId` 超出 UInt32 时 `UInt32.init` 使宿主崩溃（`window.bind` 的 `windowId`/`pid` 同类老问题） | 高 | 全部改为 `exactly:` 转换，越界返回 `invalid_argument`；schema 加 `maximum`；新增反例夹具与测试；CLI 用 `UInt32(s)` 解析 |
| 物理 Desktop 观察先截整屏落盘再裁剪 | 高 | 物理 Desktop 改用引擎的单窗口截图（ScreenCaptureKit 独立窗口过滤，忽略阴影，截图前后核对窗口未动），整屏图从不产生；真机验证产物目录无 `.screen.png`（run10） |
| 遮挡检查只看普通层，通知、菜单等高层窗口会被截进图 | 中 | 单窗口截图后高层窗口进不了图像；另外物理 Desktop 的 G0 检查加入高层覆盖物（只排除 Dock 的全屏透明层、菜单栏条与小于 4×4 的锚点窗口；未知的全屏高层窗口与绑定进程自己的浮层也算遮挡（fail closed），通知横幅等 → `occluded` |
| 显示器几何只在创建时记录，改分辨率后映射错误 | 中 | 物理 Desktop 每次观察和输入前重新取显示器几何，变化或拔出 → `stale_observation / display_changed` |
| 来源判定只比厂商号 | 中低 | 改为一对一匹配帧缓冲（见 4.2） |
| `kind` 与 `methods.json` `plannedFields` 中预留的 `targetKind` 含义相近 | 低 | 两者含义不同（`kind` 是 Desktop 的显示面来源，`targetKind` 是绑定目标是窗口还是设备），**请 Runtime 负责人确认命名**并决定是否在 `plannedFields` 登记 |
| `physical` 与 `width/height` 互斥只写在描述里 | 低 | schema 用 `if/then/not` 表达（`window_list_params` 已用 `not`），新增反例夹具 |
| CLI `--display` 不带 `--physical` 隐式生效；无 CLI 用例 | 低 | 要求同时给 `--physical`；新增映射与反例测试 |
| 测试缺口 | 低 | 新增：高层覆盖物、显示器变化、进程退出、ID 越界、8 个连接并发挂接同一显示器只成功 1 个、覆盖物判定纯函数、CLI 解析 |

审核中关于"另一个虚拟 Desktop 的 `window.bind` 仍可能把用户屏上的同一窗口搬走"（老行为，物理 Desktop 随之 `window_gone`，失败但安全）与"点击可能让被绑定应用短暂到前台"两点，属于虚拟 Desktop 与 FocusGuard 的既有行为，未在本 PR 修改，留给 Runtime 负责人评估。

### 4.5 C1

首次记录（run3）保持 failed：脚本断言过严（只认 `window_gone`）。按裁决修正断言为"`stale_observation` 且未发送即等价安全拒绝"，不改 Runtime；新增"窗口消失但进程仍在"的覆盖（run5，⌘M 经 Runtime 发出，原因 `window_gone`），并重跑 C1（run6）。

## 5. 未在本 PR 内的事项

- 多显示器：已支持 `displayId`，但真机只验证了单显示器。
- CR01（配对认证）、CR03（接管/归还）不受本 PR 影响，仍按原计划独立验收。
- Windows 后端（C#）未实现物理 Desktop。

## 6. 验收

见 `docs/acceptance/physical-desktop/README.md`。接入窗口授权后的真机验收见 §7.4。

## 7. 接入窗口级授权（#205，2026-10-10）

依据：Kevin 2026-10-09 裁决「选择 B，坚持按窗口授权」；#205 合并于 main `0ac22c4`。本 PR 在 #205 之上重放 #143 的独立审核修复，**不改任何封印开关**。

### 7.1 授权模型（来自 #205，本 PR 不改）

物理 Desktop 上的窗口一律属于"需要窗口授权"的一类（`docs/security/window-grants.md`）：

| 入口 | 已配对客户端需要 |
| --- | --- |
| `desktop.create {physical}` | `desktop.manage`，且产品里封印打开（目前关，见 7.3） |
| `window.bind` | 该窗口的有效窗口授权（任一权限），必须给 `windowId`；窗口留在原处 |
| `observe` / `wait` | `observe`（加锁后查、存储前再查、每次轮询都查） |
| `act` | `act`（投递前最后一刻查） |
| 截图保存 | `persist`；没有则截图为临时（120 秒、随授权失效删除） |
| `window.list` / `desktop.show` | 只列有 `observe` 的已授权窗口；无权时绑定信息为 `null` |

首次及每次授权走 A4 可信确认窗口 + Touch ID；物理 Desktop 的确认窗口额外警告"这是你自己屏幕上的真实窗口"。窗口身份 = 窗口 ID + 进程身份（pid + 启动时间）+ bundleId + Desktop + clientId，失效粘滞，防窗口 ID 复用。owner（宿主进程内）不受窗口授权约束。

### 7.2 本 PR 在授权之上保留的 #143 安全修复

授权回答"谁可以动这个窗口"，下面这些回答"此刻动的是不是用户以为的那个窗口"，对 owner 与已配对客户端同样生效：

| 修复 | 失败时 |
| --- | --- |
| 显示器来源按厂商 + 型号 + 序列号匹配硬件帧缓冲，与顺序无关（4.2） | `desktop.create {physical}` → `not_found`，报错不列出有哪些显示器 |
| 高层覆盖物（通知横幅、他应用菜单、绑定应用自己的浮层、未知全屏层）盖住绑定窗口 | `stale_observation / occluded`，只给覆盖窗口编号，不给应用名、标题、pid |
| 显示器几何变化或拔出 | `stale_observation / display_changed` |
| 绑定进程退出或重启 | `stale_observation / process_exited`，act `notSent=true` |
| `pid` / `windowId` 超出 Int32 / UInt32 | `invalid_argument`，不崩溃，不截断成别的窗口 |
| `physical` 与 `width/height` 同给 | 契约 `if/then/not` → `schema_invalid` |
| CLI `--display` 不带 `--physical` | 本地拒绝，不连接 |
| 物理 Desktop 任何路径 | 只做单窗口截图；未绑定时一律拒绝，不受虚拟 Desktop 的 `refusesScreenCaptureWithoutBinding` 开关影响 |

被 main 上已合并的 PR 覆盖、因此本 PR 不再重复的部分：单窗口截图与 `windowScreenshot`（#145）、物理 Desktop 关闭开关与无绑定拒绝截图（#145）、启动/发现授权（#151/#153/#137）、窗口授权与绑定检查（#205）。

### 7.3 封印开关：需要 Kevin 裁决

本 PR 不改产品默认值，测试 `theSealsStayAsTheProductShipsThem` 锁定：

| 开关 | 产品默认 | 打开后的行为 |
| --- | --- | --- |
| `physicalDesktopsEnabled` | 关：`desktop.create {physical}` 对所有调用方返回 `permission_denied / physical_desktop_requires_grant`，不查显示器 | 已配对客户端可以挂接用户显示器；挂接本身看不到任何窗口——绑定、观察、操作、保存都要逐窗口 Touch ID 授权（7.1），并受 7.2 全部检查 |
| `bindsOnlyLaunchedProcesses` | 开：虚拟 Desktop 只能绑定在它上面 `app.launch` 的进程 | 虚拟 Desktop 可以把用户窗口**搬过来**绑定（仍需窗口授权）。与物理 Desktop 无关；搬动用户窗口是另一类风险，建议单独裁决 |
| `refusesScreenCaptureWithoutBinding` | 开：无绑定的虚拟 Desktop 不截整屏 | 与物理 Desktop 无关（物理 Desktop 无绑定时始终拒绝） |

建议的裁决选项（由 Kevin 决定）：只打开 `physicalDesktopsEnabled`，另两个保持；或先只允许测试副本（side instance）打开以完成真机验收，产品仍关。在裁决之前，WeChat Agent 第四阶段仍无法绑定用户自己打开的微信窗口。

### 7.4 真机验收（Kevin 本人）

`scripts/physical-desktop-acceptance.sh`：测试副本、独立钥匙串文件、只开并只关一个自己启动的 Chess 实例，只对它发一次 Escape，不创建虚拟显示器、不碰正式端点和微信。物理 Desktop 关闭时脚本在第 2 步停下并报 `PENDING`（退出码 3），什么都不截、不绑。记录模板：`docs/acceptance/physical-desktop/window-grants-acceptance.md`。覆盖物和显示器变化两项需要人为制造（通知、改分辨率），写在模板里作为可选手动步骤。

