# ACP PR 依赖图与合并顺序

状态：2026-10-08 第二轮，工作线 D。基线：`acp-skeleton`@34ae2c5（draft PR #53，目标 `ai-gui-foundation`）。

## 一、已合入的状态

| PR | 线 | 内容 | 合入 `acp-skeleton` |
| --- | --- | --- | --- |
| #53 | 协调者 | 冻结接口（`Ports.swift`、`Model/`）、方案输入、分工；仍是草案，目标 `ai-gui-foundation` | 基线本身 |
| #54 | D | 01、04、05、06 第一版 | 已合入 |
| #62 | S | 入站服务：会话、prompt、取消、审批、存储、dev 入口（`--demo`） | 已合入 |
| #63 | R | Runtime 桥 `ACPBridgeRuntimePort`、提交记录、任务目录、07 | 已合入 |
| #65 | E | 事件投影、三级隐私、脱敏、08、15 份夹具 | 已合入 |
| #66 | O | 出站隔离实测（`spikes/acp-outbound/`）、09 | 已合入 |
| #67 | T | stdio JSON-RPC、v1 适配器、版本决策 02 | 已合入 |
| #68 | Q | 156 个用例、假编辑器、一致性测试、E2E 手册 | 已合入 |
| 协调者提交 | 协调者 | `ACPActionLevel.failed(code:)`（d24c1f7）；`ACPRequestId` 哈希与 `==` 一致（86a64c2）；会话列表带 `cwd`、恢复带 `replay`（34ae2c5） | 已合入 |

基线已含 `ai-gui-foundation`@b2831ca（A0 #47、G0 #51）。

## 二、总图

```
ai-gui-foundation
  b2831ca  A0 #47 + G0 #51
     │
     └─ acp-skeleton #53（草案）
          │  已合入：#54 D、#62 S、#63 R、#65 E、#66 O、#67 T、#68 Q
          │  34ae2c5
          │
          ├─ 第二轮（进行中）
          │    t2  T 线 ─┐
          │    s2  S 线 ─┼─ dev 入口接上真实 stdio + RuntimeClient 端口 + 投影器（GAP-28）
          │    r2  R 线 ─┘
          │    d2  D 线：本文、01、04、06 更新
          │
          ├─ 下一步 Q-L1：假编辑器对真 dev 入口跑场景（scripts/acp/run-real.sh）
          │
          ├─ Q-L2：/tmp/adt-* 测试副本上的真 Runtime（只读部分现在就能跑）
          │
          └─ #53 转正式 PR → f1 审核接口 → ai-gui-foundation（只含 mock 与只读）

   外部依赖（不由本组实现）                          解锁
   A2 / PR2b 单一端点（f1）──────┐
   #29 MCP 经 Runtime（f1，A7）──┼─→ G0 ─→ CLI `agentdesktop acp`（07 R9）
   SEC-01～05（f1；#69 进行中）──┘
   A6 / PR2d unit.run（40，#50）──────────→ 真实任务提交 → G1、G2 的 L2/L3
   A4 / PR3 身份、授权、心跳（f1）─────────→ T07、T15、ACP-31、HB-11
   PR4 inbox 审批与提问（f1；07 R2）────────→ T16、T17、场景 D 的真实部分
   F1-01 事件目录（f1；07 R3，08 E-1～E-10）→ E 对齐，G0-13
   AX 隔离 RT-23A/B（#60 进行中）──────────→ T28、G3-08
   Zed 真机握手（Q，前台一次）─────────────→ G0-12、G5-04
   P3 网关闸门与真实模型凭据（Kevin，O1）──→ G4
   打包、清单、Registry、JetBrains（P2）───→ G5
```

读法：箭头表示「必须先合入或先满足」。按 Kevin 裁决附加约束 6，A2、A4、A6 合入前任何假实现通过都不算端到端验收。

## 三、第二轮与下一步

| 步骤 | 内容 | 前提 | 验收 |
| --- | --- | --- | --- |
| 1 | t2、s2、r2：`ACPAgentServerDevWiring` 三处接线；各线第一轮遗留项 | 无 | `swift build`、`swift test` 退出码 0；`agentdesktop-acp-dev` 不再报「not on this build yet」 |
| 2 | d2：文档更新 | 无 | 本 PR |
| 3 | Q-L1：`scripts/acp/run-real.sh agentdesktop-dev <out>` 对真 dev 入口跑假编辑器场景 | 步骤 1 | `summary.json` 退出码；cases.csv 只改 L1 用例的状态与证据 |
| 4 | Q-L2 只读：测试副本上 `desktop.list`、`run.list`、`run.show`、`events.subscribe` | 步骤 1 | 记录到 `docs/acp/tests/evidence/` |
| 5 | Zed 真机握手：取得 `initialize` 线上帧 | Zed 已装 | 02 7.2 补上帧 |
| 6 | #53 送 f1 审核接口，合入 `ai-gui-foundation` | 步骤 1～3 | f1 审核意见 |
| 7 | A2、#29 合入且 G0 通过后：CLI 接入 `agentdesktop acp` | G0 | G0 清单 |
| 8 | A6 合入后：真实任务提交、G1 的 L2 与 L3（Zed） | A6、步骤 7 | G1 清单 |
| 9 | A4、PR4 合入后：G2、G3 | A4、PR4 | G2、G3 清单 |
| 10 | G3 完成后评估是否进首版候选（K3） | G3 | Kevin 决定 |
| 11 | G4、G5 | P3 实现、分发 | G4、G5 清单 |

## 四、对应原文 ACP-A0～P4

| 原文编号 | 内容 | 落在 | 状态 | 外部依赖 |
| --- | --- | --- | --- | --- |
| A0-01 | CLI v1.2 与代码差异 | D：04 | 已交付 | 无 |
| A0-02 | Runtime/1 接口基线 | D：04；R：07 | 已交付 | 无 |
| A0-03 | ADR v2.2 生命周期映射 | D：01 第七节 | 已交付，K1 已裁决 | 无 |
| A0-04 | Hub 身份、授权、撤销 | D：04 GAP-05、06；R：07 R4、R5 | 已交付（文档） | A4 |
| A0-05 | MCP 绕过修复 | 外部 | 未开始 | A2、#29 |
| A0-06 | 协议版本与 SDK | T：02 | 已交付：v1 | 无 |
| A0-07 | 单一 CLI 入口 | 协调者提请 f1（07 R9） | 未开始 | f1 |
| A0-08 | 事件脱敏策略 | E：08 | 已交付 | F1-01 对齐 |
| P1-01 | `agentdesktop acp` | dev 入口（S）；CLI 由 f1 | dev 入口接线在第二轮 | f1、G0 |
| P1-02 | stdio JSON-RPC | T | 已合入 | 无 |
| P1-03 | 初始化与能力协商 | T | 已合入 | 无 |
| P1-04 | ACP Session 创建 | S | 已合入（mock） | A4 |
| P1-05 | 任务映射 | R `ACPTaskCatalog`、S `ACPCommandCatalog` | 已合入（无 `unit.run` 时列表为空） | A6、R6 |
| P1-06 | prompt 到 Runtime | S、R | 已合入（mock） | A6 |
| P1-07 | `session/update` 事件流 | E | 已合入（mock） | F1-01 |
| P1-08 | Run 状态查询 | R | 已合入，可读真 Runtime | 无 |
| P1-09 | Zed 兼容 | Q | 用例与手册已合入 | A6、CLI |
| P2-01 | Session List | S | 已合入（mock） | A4 |
| P2-02 | Session Resume | S、R | 已合入（load 与 resume，34ae2c5） | 无 |
| P2-03 | Event Replay | R、E | 已合入（mock） | F1-01 |
| P2-04 | Approval | S | 已合入（Runtime 侧 `capability_missing` 即拒绝） | PR4 |
| P2-05 | Ask / Auto | S | 已合入（mock） | PR4 |
| P2-06 | Cancel | S、R | 已合入 | 无 |
| P2-07 | Unknown | E、S | 已合入 | 无 |
| P2-08 | Privacy Filter | E | 已合入 | 无 |
| P2-09 | 长运行与断连 | R、Q | 用例已合入 | A6 |
| P2-10 | Zed、JetBrains 兼容 | Q | JetBrains 延后（K2） | A6 |
| P3-01～P3-10 | 出站执行体 | O 评估 | 已交付：现在不能通过 | Kevin（O1、O2）、P3 实现 |
| P4 | 打包、清单、Registry、文档 | 协调者、f1 | 未开始 | G0～G3 |

## 五、A2、A6 之前能合什么

**可以合入 `acp-skeleton`，并随 #53 送 f1 审核：**

- **文档**：01～09、`docs/acp/tests/**`。
- **协议、投影、桥、服务器**：已合入的 T、E、R、S 代码与第二轮的接线。
- **开发入口**：`agentdesktop-acp-dev`，不进 `bundle-app.sh` 的发布包。
- **只读真机**：测试副本上的只读调用。

**不能在 A2、A6 之前合入或启用：**

- **发布物里的 `agentdesktop acp`**：要等 G0。
- **真实任务提交**：`unit.run` 不存在；桥对真 Runtime 只能返回 `capability_missing`。
- **任何真实写操作由 ACP 自己驱动**：ACP 不是执行器，永远不做。
- **真实审批裁决**：PR4 之前不存在。
- **出站代码**：只在 `spikes/`，G4 之前不进 `Package.swift`。
