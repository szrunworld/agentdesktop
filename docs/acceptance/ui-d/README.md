# UI-D：U6 设置——组件验收记录（2026-10-11）

范围：主窗口「设置」下的 P21 通用、P02 / P22 权限、P23–P26 AI 连接 / 添加连接 / GUI 配置 / 能力测试、P30 用量。「核实」（U9）保持「尚未启用」。

**这一份只是组件验收。** 页面数据来自 Mock Runtime（`MockRuntime+Settings.swift`，每次调用都按 runtime/1 与 service.schema.json 校验参数和结果）。真实 Runtime、真实窗口、交互验证这一级（02 §2.2 的页面验收）**尚未做**。

## 怎么做的

- 页面都在 `Sources/AgentDesktopUI/Pages/Settings*.swift`，通过主窗口自己的 `RuntimePort` 调用 runtime/1 的 `ai.*` 方法；不再使用 AgentDesktopAIUI 的 contract v1 客户端（W01–W04、W08 的逻辑按原规则移植过来）。
- AI 相关条目只在 `runtime.capabilities` 列出 `ai.*` 时显示，否则显示「AI 服务未运行」。设置页每次切换条目都会重新读一次 capabilities（AI 服务比 Store 首次握手晚注册）。
- 权限状态只来自 `runtime.capabilities.backend.permissions`；「前往授权」只打开系统设置，不自动申请。
- 写操作都带读到的版本号（`expectedRevision` / `expectedDefaultRevision` / `expectedProfileRevision`）；冲突时保留草稿，显示服务器当前版本，可「读取服务器版本（保留我的修改）」。
- 删除与停用都先弹确认框；确认框写明会发生什么、不会改变什么。
- 密钥只在密码框里，提交时读一次后立即清空；连接只显示「已设置」和「轮换密钥」。

## 离屏渲染（SnapshotRenderer，1440 × 1000，不上屏）

命令：`AGENTDESKTOP_UI_SNAPSHOTS=$PWD/docs/acceptance/ui-d swift test --skip-build --filter SettingsRenderTests`

| 渲染图 | 线框图 | 对照结论 |
| --- | --- | --- |
| `P21-general.png` | P21 | 一致：三个开关、默认尺寸、界面语言、保存偏好。差异：「关闭主窗口后继续运行」固定开启（产品行为 ADR-02），「登录时启动」标为尚未提供，两者禁用；离屏渲染里开关不显示主题色（窗口不在前台），真实窗口为绿色 |
| `P22-permissions-missing.png` | P22 | 一致：两项权限卡、已授权徽标、「前往授权」、重新检查。另加了「以 runtime.capabilities 为准、不自动申请」的说明 |
| `P02-first-use.png` | P02 | 一致：左侧欢迎、右侧两项权限、「完成并创建 Desktop」在两项都授权前禁用。是组件；宿主何时显示它要改公共文件（见 PR「需要协调」） |
| `P23-ai-connections.png` | P23 | 一致：连接 / 模型 / 能力证据 / 状态 / 操作五列，两张说明卡。差异：线框图里 AI 与 GUI 是一级入口加标签页，这里按现有导航放在设置的二级列表中；行内多了删除按钮和「密钥：已设置」 |
| `P23-confirm-delete.png` | — | 删除确认框 |
| `P24-add-connection.png` | P24 | 一致：右侧抽屉，名称、协议、Base URL、API 密钥、模型 ID、超时，底部取消 / 保存连接。编辑模式下「获取模型示例」可用，密钥区只显示「已设置」和轮换 |
| `P25-gui-profiles.png` | P25 | 一致：左侧配置卡（默认徽标、测试配置），右侧模型与输出协议表单、有界运行限制（只读）、「只建议，不直接输入」、开始诊断 / 查看模型连接。「保存配置」放在表单内，不在页头 |
| `P26-capability-test.png` | P26 | 一致：四层测试与状态、本次测试、能力证据的范围、「使用此配置进行诊断」 |
| `P30-usage.png` | P30 | 三个指标卡一致；「内置 GUI 运行」按运行的表格需要 F40-04（`ai.usage.summary` 按 runId），现在显示「按运行汇总尚未提供」；「导出诊断」禁用（U9） |
| `U9-verification-not-enabled.png` | — | 「核实」保持尚未启用 |

## 自动化测试

`Tests/AgentDesktopUITests/SettingsTests.swift`（`Settings (U6)` 与 `Settings renders` 两个 suite）。测试结果和退出码见 PR 描述。

| 规则 | 测试 |
| --- | --- |
| 27 个 `ai.*` 模拟都符合契约 | `everyAIMethodAnswersWithinContract` |
| 旧版本号被拒（conflict + currentRevision），被引用时不能删（in_use） | `staleRevisionsAndReferencesAreRefusedInRuntimeTerms` |
| 密钥只发一次、任何状态里都找不到；第二次点击不重复创建 | `createSendsTheKeyOnceAndKeepsItNowhere` |
| 非本机 HTTP 在发请求前被拒，密钥被清空（UC36） | `badEndpointIsRefusedBeforeAnyCallAndTheKeyIsCleared` |
| 冲突保留草稿，显示服务器版本，读取后可保存 | `editConflictKeepsTheDraftAndShowsTheServerRevision` |
| 轮换带版本号，密钥不留存 | `rotateWritesANewCredentialWithTheRevision` |
| 删除 / 停用要确认，带版本号，被引用时如实显示 | `disableAndDeleteWaitForConfirmationAndCarryTheRevision` |
| GUI 配置保存出新版本；停用的连接不能用 | `profileSaveMakesAModelProfileAndANewRevision` |
| 设为默认带两个版本号；停用默认配置后默认清空 | `setDefaultUsesBothRevisions` |
| 能力测试四层分开、轮询到结束、不发输入；失败层之后跳过；取消以操作的结果为准 | `capabilityTestPollsUntilTheOperationEnds`、`aFailedLevelSkipsTheRest`、`cancelEndsOnlyWhenTheOperationSaysSo` |
| 未报告的用量显示「未知」，费用不按 0 显示 | `unreportedUsageStaysUnknown` |
| 偏好只在「保存偏好」时写入并持久 | `preferencesSaveOnlyOnRequestAndPersist` |
| 权限来自 capabilities，不自动打开系统设置；没有 capabilities 时为未知 | `permissionsComeFromCapabilitiesAndNothingIsRequested`、`permissionsUnknownWithoutCapabilities` |
| AI 条目跟随 capabilities | `aiEntriesFollowRuntimeCapabilities` |

## 待做（页面验收）

- 测试副本（`/tmp/adt-ui-d/`）上的真实 Runtime + 真实 AI 服务（`InMemoryCredentialStore` 或文件凭据，不写登录钥匙串），走一遍添加连接、GUI 配置、能力测试（脚本化上游，不调用真实模型）。
- 真实窗口里的交互验证由 Kevin 安排。
