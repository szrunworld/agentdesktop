# G0 窗口一致性验收记录（2026-10-08）

针对 MAC-001 的失败（`docs/acceptance/mac-001-2026-10-08.md`，原样保留）：截图按整屏拍，元素读取和输入却对准绑定窗口；Safari 新开窗口后两者不再是同一个窗口。Kevin 裁定这是 G0 阻断项。本记录只覆盖窗口一致性的回归。完整的 MAC-001 端到端验收要等 AX 与 A6 完成后再做，结果另写新文件。

## 规则（Runtime 实现）

- 窗口身份由 Runtime 管理：windowId + 进程启动身份 + 所属 Desktop + 绑定代次。不看标题，也不只看 PID。
- observe：先证明绑定窗口**暴露**，才截图：
  - 没有其他窗口与它重叠（遮挡）；
  - 本进程没有其他窗口在它前面（按键送给 App 的最前窗口）。
  截图**只取绑定窗口的区域**，图像的 transform 原点就是窗口左上角。截图和读元素之后再检查一次叠放，期间有变化就作废这次观察（`changed_during_capture`）。
- act：每次输入前，在该 Desktop 的锁内重新检查：绑定代次、进程身份、窗口位置大小、遮挡、同进程前置窗口。不满足时返回 `stale_observation`（`notSent: true`，`details.reason` 写明原因），dispatch=0。
- 检查与使用之间的竞态：操作系统无法让“检查 + 发送”成为原子操作，所以发送后**立即复核**。目标在发送前后发生变化时，这次动作记为 `delivery: unknown`（`action_delivery_unknown`，reason `target_changed_during_dispatch`），Run 的 outcome 随之为 unknown；不重试，也不改投其他窗口；之后的输入被发送前检查拒绝。
- 新窗口不继承绑定；需要用新窗口时必须显式 `window bind`。
- 回执新增 `businessResult: "not_evaluated"`：`delivery: dispatched` 只表示已送达，不表示生效。
- 未绑定窗口的 Desktop 没有输入目标，observe 仍然返回整屏。

剩余风险（如实说明）：发送后复核只能发现“发送前后窗口变化”。如果变化恰好发生在复核之后、App 处理事件之前，这一次仍可能落到新窗口；这种情况由下一次观察发现，并靠后续输入被拒来控制。真正的按窗口投递和按窗口截图留到后续。

## 自动化测试

`swift test`：374 项全部通过，退出码 0（已合入 A0）。新增 RuntimeTargetIdentityTests：

| 测试 | 断言 |
| --- | --- |
| aCoveredWindowIsNeitherObservedNorTyped | 其他 App 的窗口盖住绑定窗口：observe 拒绝（reason occluded，带 coveringWindowId）；type 拒绝且 notSent，perform 次数为 0 |
| aNewWindowOfTheSameAppInheritsNothing | 同进程新开一个不重叠的窗口：key 与 observe 都拒绝（other_window_of_process_in_front）；新窗口关掉后恢复 |
| aWindowAppearingWhileInputIsSentMakesItUnknownAndStopsTheNext | 检查通过之后、发送之时弹出新窗口：本次 action_delivery_unknown，回执 delivery unknown；下一次输入在发送前被拒，perform 次数仍为 1 |
| windowsChangingDuringTheCaptureVoidTheObservation | 截图过程中叠放顺序变化，观察作废 |
| theImageIsTheBoundWindowAndReceiptsSayDeliveryIsNotEffect | 图像原点和尺寸等于窗口位置和大小（2 倍）；回执符合 Schema，businessResult 为 not_evaluated |
| aDesktopWithoutABindingStillShowsTheWholeScreen | 未绑定窗口时仍是整屏 |

已有测试按“图像即窗口”改了坐标：RuntimeActTests、RuntimeDesktopTests、RuntimeGuiPortsTests。模型输入图仍然是窗口裁剪，GUI 端口的变换链经测试验证。

## 真机回归（测试副本，自写中立探针 App）

探针 `/tmp/adt-g0/Probe.app`：一个带输入框的窗口 “Probe A”，按 n 时同一进程新开窗口 B（与 Safari 的行为一致），并把每个按键记录到它实际落到的窗口。不使用用户的 Safari、TextEdit 等 App。

**A0 合并前的构建（13:32–13:36）**

| 步骤 | 结果 |
| --- | --- |
| observe | 图像 800×656，原点 (3200,618)，等于窗口 400×328 的 2 倍；截图内容只有 Probe A |
| type “hi” 到输入框 | dispatched（ax.insert），businessResult not_evaluated |
| key n | dispatched；探针日志显示 n 的 keyUp 落到了**新窗口 B**，即 MAC-001 的现象 |
| 之后 observe | 拒绝：stale_observation / occluded，coveringWindowId = B |
| 之后 key x | 拒绝：stale_observation，notSent true，探针没有收到 x |
| 计算器开在同一 Desktop 但不重叠 | observe 照常通过（不误拒） |

**合入 A0 后的构建（13:43）**

| 步骤 | 结果 |
| --- | --- |
| observe | 图像 800×656，原点等于窗口位置 |
| key a | dispatched，探针日志 “key a in Probe A” |
| key n（发送中弹出 B） | **action_delivery_unknown，reason target_changed_during_dispatch**：发送后复核抓到了变化 |
| 之后 key x | 拒绝：stale_observation，notSent true，reason other_window_of_process_in_front，coveringWindowId = B；探针没有收到 x |
| 之后 observe | 拒绝：other_window_of_process_in_front |

清理：关闭会话，结束探针，销毁 Desktop，停止测试副本，删除 /tmp/adt-g0。没有碰产品 endpoint 和用户窗口。

## 对应 Kevin 的 G0 条目

| 条目 | 状态 |
| --- | --- |
| 截图必须来自绑定窗口，不能用整屏代替 | 已实现：按窗口裁剪，并先证明窗口没有被遮挡 |
| GUI 操作前重新校验目标窗口身份 | 已实现：每次 act 都在 Desktop 锁内检查 |
| 模型看到的截图与执行目标一致 | 已实现：模型图来自同一张窗口截图 |
| 目标失效或身份变化时拒绝 | 已实现：window_gone / occluded / other_window_of_process_in_front / 代次 / 进程身份 |
| 新窗口不继承旧窗口的执行授权 | 已实现：必须显式 bind |
| 回执区分已送达和已生效 | 已实现：businessResult not_evaluated |
| 检查与使用之间的竞态：每次输入前复核、发现变化立即拒绝、失败不自动切换窗口 | 已实现；剩余风险见上文 |
| AX 整树总时限、AX 异常不阻塞其他 Desktop | 下一步（A3 / AX），不在本 PR |
