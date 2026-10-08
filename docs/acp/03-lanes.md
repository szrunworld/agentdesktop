# ACP 工作线与文件所有权

七条工作线同时开工，彼此正交：每条线只写自己名下的文件，只经 [README](README.md) 第三节的冻结接口与别的线交互，测试里用自己写的假实现代替别的线。

## 一、总览

| 线 | 名称 | 交付 | 对应原文 |
| --- | --- | --- | --- |
| D | 方案与文档 | RFC 0002 修订稿、差距分析、PR 依赖图、G0～G5 清单 | 第十二节第二、五步；A0-01～A0-04、A0-07 |
| T | 传输与协议版本 | stdio JSON-RPC、帧与错误处理、v1/v2 版本适配、能力协商、版本决策 | P1-02、P1-03、A0-06；T01～T05 |
| S | 入站服务 | ACP 服务器、会话管理与持久化、命令注册、prompt / cancel / 审批 / 提问流程、Ask/Auto、开发入口 | P1-04、P1-05 的命令部分、P1-06 的编排、P2-01～P2-06；T06～T08 |
| R | Runtime 桥 | 经 RuntimeClient 实现 `ACPRuntimePort`：身份、任务发现、提交与幂等、状态、取消、事件续传、断连 | P1-05 的数据源、P1-06、P1-08、P2-02、P2-07；T09～T14 |
| E | 事件投影与隐私 | Runtime 事件到 ACP 更新的投影、三级动作结果、字段级脱敏、日志不泄露 | 第五节、6.4；P1-07、P2-08；T19～T21 |
| O | 出站隔离评估 | Claude Code / Codex / Gemini 的 ACP 适配器在进程隔离下的实测评估，原型只放 spikes | 第七节、P3 的前置研究；T22～T25 的可行性 |
| Q | 测试与验收 | T01～T28 细化用例、协议一致性的假编辑器、真机 E2E 手册与脚本 | 第九节；P1-09、P2-10、T26～T28 |

协调者负责：冻结接口、`Package.swift`、合并、与 f1 / 40 / Kevin 的沟通、`agentdesktop acp` 的 CLI 接入请求。

## 二、文件所有权

所有源码在同一个 Swift 模块 `AgentDesktopACP` 与同一个测试模块 `AgentDesktopACPTests` 里，因此类型名也按线划分，避免撞名。

| 线 | 可以写的路径 | 新类型名前缀（源码 / 测试辅助） |
| --- | --- | --- |
| D | `docs/acp/01-rfc-0002-revised.md`、`04-gap-analysis.md`、`05-pr-graph.md`、`06-gates.md` | 无代码 |
| T | `Sources/AgentDesktopACP/Transport/**`、`Wire/**`；`Tests/AgentDesktopACPTests/Transport/**`、`Wire/**`、`Fixtures/acp-schema/**`；`docs/acp/02-protocol-version.md` | `ACPStdio*`、`ACPJsonRpc*`、`ACPWire*`、`ACPFrame*` / `TTest*` |
| S | `Sources/AgentDesktopACP/Inbound/**`、`Sources/agentdesktop-acp-dev/**`；`Tests/AgentDesktopACPTests/Inbound/**` | `ACPAgentServer*`、`ACPSessionManager*`、`ACPFileSessionStore*`、`ACPCommand*`、`ACPPrompt*`、`ACPApproval*` / `STest*` |
| R | `Sources/AgentDesktopACP/RuntimeBridge/**`；`Tests/AgentDesktopACPTests/RuntimeBridge/**`；`docs/acp/07-runtime-requests.md` | `ACPBridge*`、`ACPSubmissionLog*`、`ACPTaskCatalog*` / `RTest*` |
| E | `Sources/AgentDesktopACP/Events/**`、`Privacy/**`；`Tests/AgentDesktopACPTests/Events/**`、`Privacy/**`、`Fixtures/events/**`；`docs/acp/08-event-mapping.md` | `ACPEvent*`、`ACPProjector*`、`ACPRedact*`、`ACPDataClass*` / `ETest*` |
| O | `spikes/acp-outbound/**`（不进 `Package.swift`、不进发布包）；`docs/acp/09-outbound-isolation.md` | 不限，留在 spikes 内 |
| Q | `docs/acp/tests/**`、`scripts/acp/**`；`Tests/AgentDesktopACPTests/Conformance/**` | `QTest*` |

每条线删除自己目录里的 `.keep.swift` 占位文件。不在表内的文件一律不改，包括 README.md、本文件、`Model/`、`Ports.swift`、`Package.swift`、Runtime / Client / Protocol / CLI 的任何源码与 `contracts/`。测试夹具用 `#filePath` 定位读取，不需要改 `Package.swift`。

## 三、依赖与时序

```
acp-skeleton（冻结接口，已建）
   ├─ D  文档 ──────────────────────────────┐
   ├─ T  传输 ─┐                             │
   ├─ S  服务 ─┼─ 协调者集成：dev 入口跑通假 Runtime ─┼─ 送 f1 审核 → ai-gui-foundation
   ├─ R  桥   ─┤                             │
   ├─ E  投影 ─┘                             │
   ├─ Q  测试（用 dev 入口与假编辑器）───────────┘
   └─ O  出站评估（独立，P3 前置）

外部依赖（不由本组实现）：
   f1：A2 单一端点（G0 前置）、A4 身份、F1-01 事件目录、审批/提问契约、CLI `acp` 子命令
   40：A6 unit.run（P1 真实端到端前置）
   Kevin：K1～K3
```

本轮各线都对着假实现完成到可合并状态。真实链路（真 Runtime + 真编辑器）在 A2、A6 合入后由 Q 主导、协调者验收。

## 四、各线的完成标准

| 线 | 本轮完成标准 |
| --- | --- |
| D | 四份文档写完，每条差距写明证据（文件与行、PR 号）；原文与 README 核对结论不一致处逐条列出 |
| T | 选定的版本能和官方 SDK 的参考客户端互通（Q 的假编辑器或官方 TypeScript SDK 示例）；T01～T05 的单元测试；版本决策文档写明证据 |
| S | 用假 `ACPConnection`、假 `ACPRuntimePort`、假投影器跑通：新建、列表、恢复、prompt、取消、审批允许 / 拒绝 / 不可用、提问、Ask/Auto、断连；dev 入口能接上 T 的 stdio 实现后启动 |
| R | 对 `RuntimeClient` 的脚本化假实现跑通全部端口方法；提交结果不明只查询不重发；断连调用 `connectionLost`；07 文档列清 runtime/1 缺什么 |
| E | 按 F1-01 目录与当前 schema 的每种事件都有投影与夹具；三级结果不混淆；脱敏覆盖标题、错误、摘要、参数；08 文档 |
| O | 至少两个外部 agent（Claude Code 与 Codex 或 Gemini）在 macOS 隔离手段下的实测结果表：环境变量、文件、网络、终端、自带工具、MCP 配置，每项通过 / 失败及证据；结论写明能否进入 P3 |
| Q | T01～T28 细化到可执行用例（含前置条件、步骤、预期、依赖的线与外部条件），状态全部为 NOT_RUN 直到真实执行；假编辑器脚本；Zed 安装与配置手册；一致性测试 |

每条线完成时：在自己的分支上提交，`swift build` 与 `swift test` 退出码为 0（O、D 除外），推送并开一个以 `acp-skeleton` 为基的 PR，PR 正文写清做了什么、测试命令与退出码、未完成项、需要协调者处理的接口请求。不自行合并。

## 五、变更规则

需要改冻结接口时，在 PR 正文里写「接口请求」：要改什么、为什么、对哪些线有影响。协调者在 `acp-skeleton` 上统一修改，各线 rebase。等待期间先做不受影响的部分。
