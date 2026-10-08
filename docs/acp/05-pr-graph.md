# ACP PR 依赖图与合并顺序

状态：2026-10-08，工作线 D。基线：`acp-skeleton`@2837bd4（draft PR #53，目标 `ai-gui-foundation`）。

## 一、总图

```
ai-gui-foundation
  6c18480  A0 #47（引擎单仓；宿主不再开旧 control.sock）
  b2831ca  #51 G0 窗口一致性（RT-24）  ← acp-skeleton 尚未包含
     │
     └─ acp-skeleton #53（2837bd4，冻结接口：Ports.swift、Model/）
          │
          ├─ D  acp-lane-d   01 / 04 / 05 / 06 文档 ─────────────────────┐
          ├─ T  传输与版本   Transport/、Wire/、02 ─┐                     │
          ├─ E  投影与隐私   Events/、Privacy/、08 ─┤                     │
          ├─ R  Runtime 桥   RuntimeBridge/、07 ────┤                     │
          ├─ S  入站服务     Inbound/、acp-dev ─────┴─ INT ─┐             │
          │                                   协调者集成：         │             │
          │                                   dev 入口 + 假 Runtime │             │
          ├─ Q  测试与验收   Conformance/、tests/、scripts/acp ─────┴─ (M) ─────┴─ f1 审核
          └─ O  出站评估     spikes/acp-outbound/、09（独立，不进 Package.swift）      │
                                                                                     ▼
                                                                   #53 并入 ai-gui-foundation
                                                                  （只含 mock 可验证的部分）
                                                                                     │
   外部依赖（不由本组实现）                                                         │
   A2 / PR2b 单一端点（f1）──────────┐                                              │
   #29 MCP 经 Runtime（f1，A7）──────┼──→ G0 ──────────────────────────────────────┤
   SEC-01～05（f1，A3）──────────────┘                                              │
   A6 / PR2d unit.run（40，#50）─────────→ P1 真实提交 ──→ G1 ─────────────────────┤
   CLI `agentdesktop acp`（f1）─────────→ P1-01 ─────────↗                         │
   Zed 安装（Kevin，K2）────────────────→ T26 ───────────↗                          │
   F1-01 事件目录（f1）─────────────────→ E 对齐 ────────↗                          │
   A4 / PR3 身份与授权（f1）────────────→ T07、T15 ──→ G2 ─────────────────────────┤
   PR4 inbox 审批与提问契约（f1）───────→ P2-04 真实 ──↗                            │
   AX 隔离 RT-23A/B（f1 / 40）──────────→ T28 ──→ G3 ──────────────────────────────┤
   K1（Kevin）──────────────────────────→ T13 ──↗                                   │
   O 的评估结论 + P3 实现（Kevin 批准）─→ G4                                        │
   打包、清单、Registry（协调者、f1）+ JetBrains（K2）→ G5 ─────────────────────────┘
```

读法：箭头表示「必须先合入或先满足」。`INT` 是协调者把 T、E、R、S 接起来跑通假 Runtime 的集成提交；`(M)` 是 Q 的一致性测试在集成之后跑。

## 二、线内依赖

| 线 | 先决条件 | 可以独立完成的部分 |
| --- | --- | --- |
| D | 无 | 全部 |
| T | 无 | 帧、JSON-RPC、版本适配，用 Q 的假编辑器或官方 SDK 示例互通 |
| E | 无（按 04 的 GAP-08 事件写夹具） | 投影、三级结果、脱敏 |
| R | 无（对脚本化假 `RuntimeClient`） | 全部端口方法；`submit` 在 A6 前对假实现验证 |
| S | T、R、E 的接口（已冻结），用假实现 | 全部流程 |
| Q | INT 之后跑一致性；用例细化不依赖任何线 | T01～T28 用例文本、假编辑器、Zed 手册 |
| O | 无 | 实测表与结论 |

接口要改时，由协调者在 `acp-skeleton` 上改，各线 rebase（03-lanes.md 第五节）。

## 三、对应原文 ACP-A0～P4

| 原文编号 | 内容 | 落在 | 外部依赖 | 合并类别 |
| --- | --- | --- | --- | --- |
| A0-01 | CLI v1.2 与代码差异 | D：04 | 无 | 文档 |
| A0-02 | Runtime/1 接口基线 | D：04、01 第八至十三节 | 无 | 文档 |
| A0-03 | ADR v2.2 生命周期映射 | D：01 第七节 | K1 | 文档 |
| A0-04 | Hub 身份、授权、撤销 | D：04 GAP-05、GAP-06 | A4 | 文档 |
| A0-05 | MCP 绕过修复 | 外部：A2、#29 | A2、#29 | 不在 ACP 内 |
| A0-06 | 协议版本与 SDK | T：02 | 无 | mock |
| A0-07 | 单一 CLI 入口 | D：04 GAP-09；协调者提请 | f1 接 CLI | 真实 |
| A0-08 | 事件脱敏策略 | E：08 | F1-01 | mock |
| P1-01 | `agentdesktop acp` | S 的 dev 入口；CLI 接入由 f1 | f1 | 真实（发布物） |
| P1-02 | stdio JSON-RPC | T | 无 | mock |
| P1-03 | 初始化与能力协商 | T | 无 | mock |
| P1-04 | ACP Session 创建 | S | A4（真实身份） | mock |
| P1-05 | 任务映射 | R（数据源）、S（命令） | A6、任务目录契约 | mock，真实需 A6 |
| P1-06 | prompt 到 Runtime | S 编排、R 提交 | A6 | mock，真实需 A6 |
| P1-07 | `session/update` 事件流 | E | F1-01 | mock |
| P1-08 | Run 状态查询 | R | 无（`run.show` 已有） | mock，可读真 Runtime |
| P1-09 | Zed 兼容 | Q | Zed（K2）、A6、CLI | 真实 |
| P2-01 | Session List | S | A4（按身份过滤才有意义） | mock |
| P2-02 | Session Resume | S、R | 无 | mock |
| P2-03 | Event Replay | R、E | F1-01 | mock |
| P2-04 | Approval | S | PR4 审批契约 | mock（Runtime 侧为 `capability_missing`） |
| P2-05 | Ask / Auto | S | PR4 | mock |
| P2-06 | Cancel | S、R | 无（`run.cancel` 已有） | mock |
| P2-07 | Unknown | E、S | 无 | mock |
| P2-08 | Privacy Filter | E | 无 | mock |
| P2-09 | 长运行与断连 | R、Q | A6 | 真实 |
| P2-10 | Zed、JetBrains 兼容 | Q | K2 | 真实 |
| P3-01～P3-10 | 出站执行体 | O 只做评估 | Kevin 批准、G4 | 本轮不合入代码 |
| P4 | 打包、清单、Registry、文档 | 协调者、f1 | G0～G3 | 真实 |

## 四、A2、A6 之前能合什么

**可以合入 `acp-skeleton`，并随 #53 送 f1 审核（mock-only）：**

- **文档**：01、02、04～09，以及 `docs/acp/tests/**`。
- **协议与投影**：T 的传输与 Wire；E 的投影与脱敏。它们不连 Runtime。
- **桥**：R 的 `ACPRuntimePort` 实现，测试只对脚本化假 `RuntimeClient`。
- **服务器**：S 的会话、命令、流程，测试只用假端口。
- **开发入口**：`agentdesktop-acp-dev`，不进 `bundle-app.sh` 的发布包。
- **一致性测试**：Q 的假编辑器与 `Tests/AgentDesktopACPTests/Conformance/**`。
- **只读真机冒烟**：在 `/tmp/adt-*` 测试副本上用 dev 入口读 `desktop.list`、`run.list`、`run.show`、`events.subscribe`。只读，不改任何状态。

**不能在 A2、A6 之前合入或启用：**

- **发布物里的 `agentdesktop acp`**：CLI 子命令要等 G0（A2 合入、T18 通过）。
- **真实任务提交**：`unit.run` 不存在，桥的 `submit` 对真 Runtime 只能返回 `capability_missing`。
- **任何真实写操作**：`act`、`run.start` 后由 ACP 自己驱动动作。ACP 不是执行器，永远不做。
- **真实审批裁决**：PR4 之前不存在。
- **出站代码**：只在 `spikes/`，G4 之前不进 `Package.swift`。

## 五、合并顺序

1. 协调者把 `acp-skeleton` rebase 到 `ai-gui-foundation` 最新（至少 b2831ca，纳入 #51）。
2. D、T、E、R、O 的 PR 各自合入 `acp-skeleton`，顺序不限。
3. S 合入（依赖 T、R、E 的接口已冻结，测试只用假实现，可与第 2 步并行，但在它们之后合入，便于协调者集成）。
4. 协调者集成提交 INT：dev 入口接上 T 的 stdio、R 的桥与 E 的投影，对假 Runtime 跑通。
5. Q 合入，一致性测试跑在 INT 上。
6. #53 转为正式 PR，送 f1 审核，合入 `ai-gui-foundation`。
7. A2、#29 合入且 G0 通过后，f1 接入 `agentdesktop acp`。
8. A6 合入后，Q 跑 P1 真实链路（G1）。A4、PR4 合入后跑 G2、G3。
9. G4、G5 按各自条件另行安排。
