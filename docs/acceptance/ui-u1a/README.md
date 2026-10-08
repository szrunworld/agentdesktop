# U1a UI Shell 库：离屏渲染验收记录（2026-10-08）

渲染方式：`SnapshotRenderer`（`NSHostingView` 放在从不显示的无边框窗口里，绘制到 sRGB 位图），1440 × 1000，1x。不显示在屏幕上，不改焦点。数据来自 `MockRuntime.sample()`，所以每张图的状态栏都带「样例数据 · 非真实 Runtime」标识。

复现：

```bash
AGENTDESKTOP_UI_SNAPSHOTS=$PWD/docs/acceptance/ui-u1a swift test --filter AgentDesktopUITests.RenderTests
```

## 与 Design v2.0 对照

P01、P06、P19、P21 是**组件样张**（`Sources/AgentDesktopUI/Specimens/`），用来检查 token 与组件，不是 U2、U5、U6 的页面：按钮不接动作，数据只用契约里的字段。

| 设计 | 本 PR | 一致 | 差异与原因 |
| --- | --- | --- | --- |
| [P01](../../design/v2/P01.webp) | [P01-desktops-overview.png](P01-desktops-overview.png) | 标题栏 54、侧栏 206、状态栏 28、内边距 32；颜色 token；卡片结构（名称 + desktopId、画面、状态徽章、控制者、动作数、打开预览 / 停止） | 画面是占位（U2 才接 ScreenCaptureKit）；控制者显示 `clientId`，动作数取 `Run.receipts`，并标「来自运行记录」，因为 `Desktop.control` 还不在契约里（A5）；没有传输方式（MCP / CLI），契约里没有这个字段；设计稿里的业务示例（BOSS、微信）换成中性的 Desktop；顶部原型条（查看场景、重置）不属于产品 |
| [P06](../../design/v2/P06.webp) | [P06-desktop-detail.png](P06-desktop-detail.png) | 详情布局：左侧画面，右侧「连接 / 输出 / 详情」面板；desktopId 为主身份，displayId、windowId 只放在「详情」标签 | 「我要接管」禁用，提示需要 `desktop.takeover`（A5）；最近动作的结果按 6.4 分级显示（已受理 / 已执行，未验证 / 未发出），不显示「已回执」 |
| [P19](../../design/v2/P19.webp) | [P19-action-records.png](P19-action-records.png) | 列：时间、Desktop / 调用者、动作、请求、结果、详情 | 结果列按 6.4 三级文案显示，不显示「已回执」；「动作」列只能显示方法名 `act` 和 `route`：回执里没有动作种类（缺口 F1-04）；数据由 `run.events` + `request.show` 拼出来，`request.list` 在 A5 |
| [P21](../../design/v2/P21.webp) | [P21-settings-general.png](P21-settings-general.png) | 设置二级导航、通用面板、开关行（标题 + 后果说明）、两个选择框、主按钮 | 二级导航按 06 §6.1 列七项（设计稿只有四项）；「保存偏好」禁用（偏好存储属于 U6）；开关在离屏窗口里按非活动窗口样式画成灰色，真实窗口里是主色 |

## 页面四态与导航

| 图 | 内容 |
| --- | --- |
| [state-loading.png](state-loading.png) | 握手前：加载中 |
| [state-empty.png](state-empty.png) | 没有 Desktop：空状态，不显示示例应用（UC52） |
| [state-error.png](state-error.png) | `desktop.list` 失败：错误码与建议，保留上次数据和同步时间 |
| [state-disconnected.png](state-disconnected.png) | Runtime 不可达：「Runtime 未连接」，没有缓存时明说，不回退样例数据；全局停止按钮禁用 |
| [shell-desktops-loaded.png](shell-desktops-loaded.png) | 已连接的导航容器；Desktops 入口在 U2 交付前显示「页面待接入」 |
| [shell-inbox-not-enabled.png](shell-inbox-not-enabled.png) | Inbox：「尚未启用：平台审批将在后续版本提供」，没有静态假数据 |
| [components-sheet.png](components-sheet.png) | StateBadge 四种色调、四级回执卡、关闭确认、AI 连接表单（字段错误）、CodeBox（有效 JSON 校验） |

## 测试

- `swift build`：退出码 0。
- `swift test`（全量）：退出码 0，398 项通过（新增 `AgentDesktopUITests` 30 项，其余是原有测试，全部通过）；跳过 1 项，是原有的真实模型用例，需要密钥，按需运行。
