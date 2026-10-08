# iOS 设备目标（草案）

状态：**草案，待 f1（Runtime 与契约所有者）审阅**。本目录不改变冻结契约 `contracts/runtime/v1/`；其中提出的字段和方法在 f1 并入 `methods.json` 与冻结文档之前只是提议（冻结规则第 3 条）。

权威顺序：`docs/architecture/ADR-v2.2-*.md` > `contracts/runtime/v1/` 与 `docs/plan/03-runtime-contract.md` > `docs/plan/` > 本草案 > 旧文档。

| 文件 | 内容 |
| --- | --- |
| [device-session-contract.md](device-session-contract.md) | Target、Observation、Capabilities、HostEffects、Action、ActionReceipt、设备租约、宿主剪贴板租约；与现有契约逐项映射；需要 f1 决定的增量 |
| [backends.md](backends.md) | Mirroring、WDA、CoreDevice 三个后端如何落到同一接口（只写接口要求） |
| `engine/Sources/TarsAgent/IPhoneCapabilities.swift` | Mirroring 后端的逐项能力与宿主影响声明（代码，带单元测试） |

## 现状一句话

现有后端是 iPhone Mirroring：后台点按、粘贴输入（中文可用）、Return/Delete、Home / App Switcher / Spotlight（⌘1/⌘2/⌘3）已在 2026-10-04/07 真机验证。本后端没有可靠的后台滑动、滚动、拖动和长按，因此不公布这些动作——这是本后端的限制，Apple 说明用户用鼠标或触控板可以在镜像里滑动。宿主影响分项：不移动真实指针；点按短暂借用键盘焦点，且可能把镜像短暂置前（随后切回用户应用）；⌘ 快捷键瞬时激活镜像；输入占用宿主剪贴板，点按“允许粘贴”时同样可能短暂置前。

## 用例归属（审查报告 7.2）

所有真机用例当前状态：**NOT_RUN**。真机串行验收由主会话统一安排；各工作线只交付实现与离线测试。

| ID | 场景（摘要） | 归属 | 状态 |
| --- | --- | --- | --- |
| I01 | show 重复执行、hide 被拒或延迟；确认退出 | W2 绑定/状态 | NOT_RUN |
| I02 | 截图后移动/缩放/旋转/重建镜像窗口，旧观察的动作被拒 | W2 绑定/状态；Runtime 集成=f1（`target_moved`） | NOT_RUN |
| I03 | 设置窗口或其他应用遮挡，观察与输入绑定同一 windowID | W2 绑定/状态 | NOT_RUN |
| I04 | 宿主连续输入/用鼠标时执行 tap/Home/type/swipe，记录指针、前台、焦点 | 声明=W3（本 PR）；记录与比对=真机串行验收（主会话）；WDA 对照=W4 | NOT_RUN |
| I05 | 原剪贴板为文本/图片/文件 URL/富文本，粘贴后完整恢复 | W1 粘贴 | NOT_RUN |
| I06 | 粘贴期间用户复制、两个 Agent 同时输入 | W1 粘贴；宿主剪贴板租约=f1 | NOT_RUN |
| I07 | 粘贴提示持续、许可点按失败、OCR 无识别、无焦点 → 不宣称 confirmed | W1 粘贴；回执写入=f1 | NOT_RUN |
| I08 | 普通内容里出现“允许粘贴 / Allow Paste”不点 | W1 粘贴 | NOT_RUN |
| I09 | 中文、英文、emoji、多行、第三方键盘、受保护字段 | W1 粘贴；WDA 对照=W4 | NOT_RUN |
| I10 | 模型等待/粘贴等待/连续动作间取消 | Runtime 集成=f1（cancelGeneration、deadline）；后端清理=W1 | NOT_RUN |
| I11 | 解锁、断线、拔线、runner 崩溃、重连；不重放 unknown；两机不误绑 | W2 绑定/状态（Mirroring）；W4 WDA；W5 CoreDevice；身份规则=f1 | NOT_RUN |
| I12 | 长列表、嵌套滚动、边缘手势、长按与拖动 | W4 WDA（基线）；Mirroring 保持 unsupported（W3 声明已测） | NOT_RUN |
| I13 | CoreDevice 不同 iOS / DDI / 传输；相机与麦克风 | W5 CoreDevice | NOT_RUN |
| I14 | 一机两任务串行，两机独立 | Runtime 集成=f1（每设备租约） | NOT_RUN |
| I15 | 截图失败、灰底、旧帧、并发截图；回执含 capturedAt 与图像尺寸 | W2 绑定/状态；Runtime 集成=f1 | NOT_RUN |

说明：W3 的离线单元测试（`IPhoneCapabilitiesTests`）只证明“声明与公布给模型的动作集合一致”，不算任何 I 用例通过。
