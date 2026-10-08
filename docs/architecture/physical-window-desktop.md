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

## 4. 未在本 PR 内的事项

- 窗口关闭、进程重启时，Run 目前只是后续每个 observe/act 被拒；是否主动结束或暂停 Run、发事件，待 Runtime 负责人决定（建议新增 `run.target_lost` 事件，另提契约增量）。
- 多显示器：已支持 `displayId`，但真机只验证了单显示器。
- CR01（配对认证）、CR03（接管/归还）不受本 PR 影响，仍按原计划独立验收。
- Windows 后端（C#）未实现物理 Desktop。

## 5. 验收

见 `docs/acceptance/physical-desktop/README.md`。
