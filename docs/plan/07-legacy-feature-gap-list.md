# 7 历史功能对照（Legacy Feature Gap List）

对照来源：2ndscreen@da5677c 的 CLI 命令表与 README（已由 #20 完整保全在本仓提交 49218be，当前树在 main 的 `engine/`）、TS task-runtime 与 Agent Hub、Windows C# 引擎、Android 与 iPhone、旧菜单栏 App；`docs/migration/runtime-semantics-to-port.md` 的七项接缝。

「现状」列：**R** = 新 runtime/1 已有（原在 ai-gui-foundation，2026-10-08 经 #2 合入 main）；**E** = 只在 main 的 `engine/` 旧实现里（旧 CLI `agentdesktop-cli`，A0 后退出发布路径）；**H** = 只在导入历史；**—** = 没有。

本文逐项差距保留 2026-10-08 的规划基线，用于追溯迁移范围；后续 A4 身份与窗口授权等实现进展以 [02 实施计划 §2.2](02-implementation-plan.md#22-与-2ndscreen-f1-的-pr-编号对照) 为准，不将历史差距列当作当前能力清单。

## 7.1 桌面与窗口

| 历史功能 | 旧入口 | 现状 | 规划 | 迁移 | 架构冲突 |
| --- | --- | --- | --- | --- | --- |
| 创建、列出、销毁 agent screen | `screen create/list/destroy` | R（desktop.*） | 已完成 | — | 无 |
| 调整 screen 尺寸 | `screen resize` | E | A5 增 `desktop.resize`；U2 尺寸菜单 | 是 | 无 |
| 屏幕 TTL 与空闲超时、owner-pid 自动回收 | `--ttl --idle-timeout --owner-pid` | E | A5：Desktop 空闲策略，Run 与租约主导回收 | 是，语义改为由 Run 生命周期驱动 | 与 ADR 的 Durable 语义需对齐：有 Durable Run 时不回收 |
| HiDPI 选择 | `--hidpi` | E | A5 desktop.create 参数；U2 高级尺寸 | 是 | 无 |
| 启动应用到 screen（新实例、fill、fit-screen） | `app launch` | R（app.launch），fill 与 fit-screen 部分 | A5 | 是 | 无 |
| 请应用退出（⌘Q 语义） | `app quit` | E | A5 `app.quit` | 是 | 只结束本 Desktop 启动的进程 |
| 移动窗口、交还窗口 | `window move/release` | R（window.bind/unbind） | 已完成 | — | 无 |
| 窗口跟随（Fit to Window，iPhone 转向跟随） | 菜单 Fit to Window | E | A5 binding 选项 | 是 | 无 |
| 显示器重排保护（建屏不推动用户显示器） | 引擎内部 | E | A0 后随 engine 链接沿用 | 是 | 无 |
| 显示睡眠保护 | DisplaySleep | E | A0 沿用 | 是 | 无 |
| 测试副本（侧实例、独立 socket、Test Copies 菜单） | SECONDSCREEN_SOCKET | R（产品 HostRole） | 已完成 | — | 无 |
| 主虚拟显示、分辨率预设、搬前台窗口热键 ⌃⌥⌘M | 菜单栏 | E | 不迁 | 否 | Design v2.0 无此功能（D35） |
| Agent 光标叠加层 | AgentCursorOverlay | E | U6 设置「光标标记开关」（P21）；A5 事件 | 是 | 无 |
| 预览窗口工具栏（缩放、旋转、音量、iPhone Home/Switcher） | DisplayPreview 工具栏 | E | U2 独立预览：缩放；旋转与音量随 M2 | 部分 | 无 |

## 7.2 观察与输入

| 历史功能 | 旧入口 | 现状 | 规划 | 迁移 | 架构冲突 |
| --- | --- | --- | --- | --- | --- |
| 窗口状态与 AX 元素、查询过滤 | `state --query` | R（observe 含 elements） | 查询过滤 A5 | 是 | 无 |
| 截图（含 `--windows` 窗口合成） | `screenshot` | R（observe image） | 已完成 | — | 无 |
| 点击（索引、文本、坐标、右键、双击） | `click` | R（act click，button、count） | 已完成 | — | 无 |
| 悬停 | `hover` | E | A5 Action `hover` 已定参数；runtime/1 的 `act` 在 macOS 上拒绝（`unsupported_backend`）。引擎层的 hover 仍是中键点击（产品宿主不开引擎 control socket，只经 runtime/1 到达引擎，故产品里不可达；是否让引擎层也拒绝见 #263 B-2），只发移动事件的方式 Chrome 与 AppKit 都收不到（#263 第 0 阶段实验）。Kevin 2026-10-11 选 B，有「独立浏览器中必须 hover」的场景时再评估 CDP 方案 | 否 | 不得以按键事件代替悬停 |
| AX 按压 | `ax-press` | R（act press） | 已完成（A5） | — | 无 |
| 输入文本（替换） | `type --replace` | R | 已完成 | — | 无 |
| 按键与修饰键 | `key` | R | 已完成 | — | 无 |
| 滚动（行、页） | `scroll --by` | R（amount） | 按页滚动 A5 | 是 | 无 |
| 拖动（需前台） | `drag --foreground` | E | A5 Action `drag` 已定参数；runtime/1 的 `act` 在 macOS 上一律返回 `unsupported_backend`（`background_drag_unsupported`），没有「显式允许前台」的入口；恢复须另提设计、安全分析与验收方案并经批准 | 否 | 不得静默抢前台（D19 相关规则） |
| 本机 OCR、比较、拼接 | `vision` | E | A6 后作为观察能力（coverage.ocr） | 是 | 无 |
| MCP 原子工具 | `mcp` | E（旧）；R（#29 新 MCP） | A7 | 新 MCP 取代 | 旧 MCP 原子工具绕过检查链，不迁 |

## 7.3 Agent、学习与任务

| 历史功能 | 旧入口 | 现状 | 规划 | 迁移 | 架构冲突 |
| --- | --- | --- | --- | --- | --- |
| UI-TARS 视觉 Agent 循环 | `agent --screen` | E（TarsAgent）；R（GuiRunDriver） | A6、X1 | 新循环取代；解析与坐标算法复用 | 旧循环接受模型 finished 为成功，不迁该语义 |
| 探索一次、之后本地回放（Procedure/Learning） | TarsAgent Learning、Procedure | E、H | L1–L4 | 是 | 末态相似度 0.6、就近匹配、`try?` 存盘不作为信任基础 |
| 旧探索 Bridge | `agent-bridge` | H | 不迁接口；十项语义按 runtime-semantics-to-port 接管 | 语义迁 | 无 |
| TS task-runtime：skill 任务、账本、产物校验、恢复、run_unit | `task run/status/…` | H | 语义进 A3、A5、L 阶段 | 语义迁，代码不迁 | TS 宿主已退出（D11、ADR） |
| TS Agent Hub：inbox、grants、usage、submit、outcome | `task inbox/grant/usage…` | H | A4、U9 | 语义迁 | 进程托管已 deprecated（D02） |
| 常驻 agent（resident mode） | agent-daemon | H | 不迁 | 否 | ADR 第一节 deprecated |
| BOSS 内置采集 workflow | task-runtime/src/boss | H | 不迁 | 否 | 平台不依赖业务（D04） |
| 模型配置文件 `~/.config/agentdesktop/model.env` | engine CLI | E | A6：并入 AI 连接配置库，导入一次 | 是 | 不保留第二套配置 |

## 7.4 手机与 Windows

| 历史功能 | 旧入口 | 现状 | 规划 | 迁移 | 架构冲突 |
| --- | --- | --- | --- | --- | --- |
| Android 配对、连接、镜像、声音 | `android pair/connect/show` | E（engine/optional/mobile） | M1 | 是 | 设备服务必须由 Runtime 持有 |
| Android 截图、点按、滑动、输入、按键 | `android screenshot/tap/swipe/type/key` | E | M1，device 目标类型 | 是 | 无 |
| Android 视觉 Agent | `agent --android` | E | M1 后接 unit.run | 是 | 无 |
| raw adb 透传 | `android adb` | E | 不进正式 API | 否 | 绕过 Runtime |
| iPhone Mirroring 显示、截图、点按、输入、Home | `iphone show/tap/type/key` | E | M2 | 是 | 修粘贴确认、剪贴板租约、窗口绑定后才开放 |
| iPhone 滑动与滚动 | — | — | 评估 WDA | 待定 | 当前后端不支持，不公布 |
| Windows 虚拟显示、UIA 与消息输入、托盘、CLI、MCP | engine/windows | E | L-Win：接 runtime/1 契约；输入执行权接到原生 Runtime | 是 | 前台失败后仍发输入、换行转 Enter 两处缺陷先修 |
| Windows 视觉 Agent 与回放 | engine/windows Tars | E | L-Win 随 A6、L 阶段 | 是 | 同 7.3 |

## 7.5 原生接缝（runtime-semantics-to-port.md）

| 接缝 | 规划 |
| --- | --- |
| 同一 Desktop 动作顺序 | A3 |
| 停止等待在途输入 | A3 |
| 模型请求取消 | A3、A6 |
| Windows 输入归属 | L-Win |
| 零模型回放不应先要求模型配置 | A6（inferenceBinding 可空）、L3 |
| 流程存储并发 | L2 |
| 单元成功条件需新观察验证 | A6、X1 |

## 7.6 维护方式

每个 PR 若完成某行，在本表把「现状」改为 R 并写 PR 号。发布门禁要求本表中「迁移 = 是」且规划阶段属于 P0 的行全部为 R。
