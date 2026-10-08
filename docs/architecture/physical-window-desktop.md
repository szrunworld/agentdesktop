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

两路独立信号（`DisplayOrigin.classify`）：内置屏可信；外接屏必须在 I/O 注册表中有厂商号一致的硬件帧缓冲（Apple 芯片 IOMobileFramebuffer，Intel IODisplayConnect）；引擎虚拟屏（厂商 0x3256 / 型号 2，无论谁建）判为虚拟；其余判为"来源未确认"。只有可信显示器登记为宿主屏，其余 `desktop.create {physical}` 返回 `not_found`——**无法确认来源时安全拒绝**。真机：另一会话的虚拟屏 9 被拒，内置屏 1 可挂接（run4）。局限：伪造与真实外接屏同厂商号的虚拟屏仍可能通过，需要更强信号时可加 EDID 序列号比对。

### 4.3 "一块显示器一个物理 Desktop"不阻碍多窗口

这是第一版的保守限制，不是模型约束：
- `DesktopRecord` 一个 Desktop 一个绑定窗口；多个 Desktop 指向同一显示器时，各自 G0 检查只看自己绑定的窗口及其遮挡关系，互不依赖。
- 放开限制需要的只是：把唯一性从"每块显示器"改为"每个窗口（进程身份 + windowId）至多被一个 Desktop 绑定"（`ConflictRegistry` 已按进程串行化输入，可扩展到窗口），并把 `desktops.physical(displayId:)` 的冲突检查换成按窗口检查。
- 契约不需要变：`physical.displayId` 与 `Desktop.kind` 已足够。

### 4.4 C1

首次记录（run3）保持 failed：脚本断言过严（只认 `window_gone`）。按裁决修正断言为"`stale_observation` 且未发送即等价安全拒绝"，不改 Runtime；新增"窗口消失但进程仍在"的覆盖（run5，⌘M 经 Runtime 发出，原因 `window_gone`），并重跑 C1（run6）。

## 5. 未在本 PR 内的事项

- 多显示器：已支持 `displayId`，但真机只验证了单显示器。
- CR01（配对认证）、CR03（接管/归还）不受本 PR 影响，仍按原计划独立验收。
- Windows 后端（C#）未实现物理 Desktop。

## 6. 验收

见 `docs/acceptance/physical-desktop/README.md`。
