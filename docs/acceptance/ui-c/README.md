# UI-C：U4 Agents 页（组件验收）

工作线 UI-C（docs/plan/11-parallel-lanes.md）。范围：Hub W01 总览、W02 配对请求、W03 Agent 详情与授权，Product Design v2.0 P09–P11 接入说明。

**验收级别：只有组件验收。** 本目录的图片都来自 `SnapshotRenderer` 离屏渲染（1440×1000，窗口从不上屏），数据来自 MockRuntime（右下角标「样例数据 · 非真实 Runtime」）。**页面验收待做**：真实 Runtime、真实窗口、交互验证（02 §2.2）都没有做，本 PR 不计页面交付。

## 怎么重新生成

```sh
swift build --build-tests
AGENTDESKTOP_UI_SNAPSHOTS=$PWD/docs/acceptance/ui-c swift test --skip-build --filter AgentsRenderTests
```

## 图片与线框图对照

| 图片 | 对照 | 结论 |
| --- | --- | --- |
| W01-agents-overview.png | Hub W01 | 统计卡、外部应用表（外部应用 / 代码身份 / 登记 / 连接 / 授权 / 允许范围 / 详情），「登记、连接、授权是三组独立状态」页脚，独立应用说明，与线框一致。差异：多了「代码身份」列（A4 后才有，按 Runtime 原样显示级别）；没有搜索框和「打开应用」按钮（Hub 不启动外部应用）；「最近连接」只能取当前打开连接的 `since`，契约里没有历史连接时间。配对请求面板放在总览上方（W02 的待确认请求）。 |
| W03-agent-detail.png | Hub W03 | 三轴卡（登记 / 连接 / 应用授权）、当前有效范围、身份与连接证据、平台运行。按任务要求增加了窗口级授权表（Observe / Act / Persist 三列分开）和「移除此应用」。差异：没有 grantId（契约没有这个字段）、没有 agentId / clientInstanceId（契约没有），也没有「模拟重连」夹具。 |
| W03-narrow-confirm.png | W03 撤权确认弹窗 | 二次确认：列出去掉的能力和缩短后的期限、生效时机、不会改变的内容。 |
| W03-revoke-client-confirm.png | W03 撤权确认弹窗 | 二次确认：凭据失效、连接切断、窗口授权结束、N 个未结束运行进入停止流程；外部应用本身继续运行。 |
| W03-after-revoke.png | HB-UI-04 | 结果显示「已受理」和 Runtime 回答里的事实（revoked、revokedAt、停止中的运行数），不显示「已生效」；横幅写明「外部应用本身可能仍在运行」「N 个平台运行停止中，等待执行端确认静止」。 |
| P09-connect-cli.png | P09 | 左侧 CLI / MCP / ACP · 可选，右侧「连接到指定 Desktop」、步骤 1 命令、步骤 2 配对、步骤 3 检查连接。差异：命令换成本仓库 CLI 实有的命令（`agents pair`、`desktop show`、`session open`、`observe`、`act click`），线框里的 `desktop observe --desktop-id` 不存在；多了步骤 2「在确认窗口里批准配对」；没有「调用方示例」下拉和「创建 Desktop」按钮。 |
| P10-connect-mcp.png | P10 | 配置是有效 JSON（CodeBox 用严格解析器检查，显示「有效 JSON」）。差异：`agentdesktop mcp --desktop-id` 尚未发布（A7），所以 Desktop 范围由先运行的 `agents pair --profile mcp --desktops <id>` 限定，页面如实写明。 |
| P11-connect-acp.png | P11 | 「ACP 是可选连接器」说明、配对命令、Zed 配置。`agentdesktop acp` 尚未实现，配置标为「拟议」。 |
| P09-P11-check-result.png | P09–P11「检查连接」 | 只读检查的可见结果：Desktop、控制者、授权列出它的应用和连接数，写明「没有开始运行，没有接管或替换控制者」。 |
| agents-empty.png | 四态 · 空 | 「还没有配对的外部应用」，唯一下一步「查看接入方式」。 |
| agents-disconnected.png | 四态 · 断开（HB-UI-02） | Runtime 未连接；下方是带同步时间的只读缓存，按钮全部禁用。 |

## 用例对照（单元测试，AgentsTests）

| 用例 | 测试 | 结果 |
| --- | --- | --- |
| UC22 CLI 示例绑定 desktopId | connectExamplesBindTheDesktopAndAreValid | 通过 |
| UC23 MCP 配置为有效 JSON | connectExamplesBindTheDesktopAndAreValid | 通过 |
| UC24 检查连接有可见结果 | theConnectionCheckReadsOnly、P09-P11-check-result.png | 通过 |
| UC25 只读检查不接管写控制者 | theConnectionCheckReadsOnly（检查期间调用的每个方法在契约里都是 mutation=false） | 通过 |
| HB-UI-01 登记、连接、授权分列 | registrationConnectionAndGrantAreThreeSeparateStates | 通过 |
| HB-UI-02 离线显示缓存、禁止变更 | offlineKeepsTheCacheAndAllowsNoChange | 通过 |
| HB-UI-03 失败不回退样例 | aFailedListKeepsTheLastAnswerAndNoSample | 通过 |
| HB-UI-04 撤权提示 | removingAnAppIsAcceptedAndSaysWhatStillRuns | 通过 |

以上都是组件级（MockRuntime），不是端到端。
