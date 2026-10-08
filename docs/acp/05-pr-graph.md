# ACP PR 依赖图与合并顺序

状态：2026-10-08 第三轮，工作线 D。**唯一集成基线是 AgentDesktop `main`**（README 第八节）。#53（`acp-skeleton`→`main`）保持草案，Kevin 未批准合并。

## 一、现状

| 位置 | 提交 | 内容 |
| --- | --- | --- |
| `main` | 134b451 | #2 合入（`ai-gui-foundation` 全部，含 A0 #47、G0 #51、AX #60、SEC-01 #69、A2 #84 与 #94） |
| `main` | 129b594 | #109：CI 删掉严格线程池一步（runner 上 SwiftPM 挂起） |
| `main` | fa2222f | #102：事件目录 `PlatformRunEvent`、回执与拒绝带原因、A6 契约部分 |
| `acp-skeleton` | 8f57c1d | 已合入 main@134b451 与 129b594；**未合入 fa2222f**。七条线第一至第六轮全部在内：#54 D、#62 S、#63 R、#65 E、#66 O、#67 T、#68 Q 及后续各轮；dev 入口已接线 |
| #111 | 未合入 | 整合剩余分支到 main：UI、MCP/SDK（#29）、实验 ACP（#53 及 23 个线分支）、契约（#102）；ACP 仍为实验，dev 入口不打包 |

## 二、总图

```
main ──134b451（#2：A0、G0、AX、SEC-01、A2）──129b594（#109）──fa2222f（#102 事件目录）──▶
  │                                                                       │
  │                                                         acp-skeleton 需合入 fa2222f
  │                                                                       ▼
  └─ acp-skeleton #53（草案，目标 main）8f57c1d
        │  已有：T 传输与 v1 · S 入站服务 · R Runtime 桥 · E 投影与三级隐私
        │        Q 用例与假编辑器 · O 出站评估 · D 文档 · dev 入口
        │
        │  P0 依赖（README 第八节）
        │  ┌──────────────────────────────────────────────────────────┐
        │  │ f1 契约增量 1：principal（R4）           ── main 未见      │
        │  │ f1 契约增量 2：Run.lastEventSequence（R10）── main 未见    │
        │  │ f1 契约增量 3：事件目录（R3，F1-01）     ── fa2222f 已落   │
        │  │ 40：unit.run（A6，#50）                  ── 未开始实现     │
        │  └──────────────────────────────────────────────────────────┘
        │              │ 契约落地后立即
        │              ▼
        ├─ R 集成：caller.verified=true、lastCursor、unit.run 提交
        ├─ E 集成：按目录分级，删除按键名推断
        │              │
        │              ▼
        ├─ Q：最小真实链路（第三节），隔离测试副本，不影响其他会话的 WindowServer
        │              │
        │              ▼  G1
        ├─ f1 R9：CLI `agentdesktop acp`（G1 之后、#53 离开草案之后）
        │
        ├─ 之后：A4（PR3）→ T07、T15、ACP-31、心跳 → G2、G3 的身份部分
        ├─ 之后：PR4 inbox → 审批、提问、场景 C 与 D → G2、G3 的审批部分
        ├─ 并行：#29 MCP 合入 + T18-02 真实点击 → G0-02
        └─ 并行：Z1 Zed 首帧（Kevin 手工）→ G0-12、G5-04

   G3 完成 → Kevin 评估是否进首版候选（K3）
   正式发布 → G4（P3 实现）、G5（分发）与 Runtime 集成验收全部通过
```

读法：箭头表示「必须先合入或先满足」。按附加约束 6，A2、A4、A6 合入前任何假实现通过都不算端到端验收；A2 已合入，A4、A6 未合入。

## 三、最小真实链路

第二次裁决定的下一阶段优先级：真实编辑器到结果返回编辑器，至少覆盖正常完成、取消、断连、审批拒绝、结果未知五类。

```
Zed 1.23.2（隔离 --user-data-dir）
   │ stdio，ACP v1（protocolVersion 1）
   ▼
agentdesktop-acp-dev --endpoint /tmp/adt-*/side.runtime.sock
   │  T：帧与 v1 适配 → S：会话与 prompt → R：提交
   │ 控制连接：runtime.handshake（principal）→ unit.run（requestId = acp-sub-…）
   ▼
AgentDesktop Runtime（测试副本，真实 GUI 输入已打开）
   │ unit.run → Run（agent_hub / external_client / connection_scoped）
   ▼
GUI 执行（Explorer 单元，绑定窗口，G0 复核）
   │ RunEvent：run.started、action.*、run.quiescent、run.ended（目录 fa2222f）
   ▼
R 的订阅连接：events.subscribe {runId, after}
   │
   ▼
E：投影与三级脱敏 → S → T → session/update、prompt 回复
   ▼
Zed 显示计划、动作卡片与结果
```

| 环节 | 现在是否具备 | 缺什么 |
| --- | --- | --- |
| Zed 启动 dev 入口并完成 `initialize` | 部分 | Z1 真实首帧未取得 |
| ACP v1 传输、会话、prompt | 是（L1 通过） | 无 |
| 握手拿到 principal | 否 | f1 契约增量 1 |
| `unit.run` 提交 | 否 | 40 的 A6 |
| GUI 执行与 G0 复核 | 是（main） | 测试副本打开真实 GUI 输入 |
| 事件目录 | 在 main，不在 `acp-skeleton` | 合入 fa2222f；E 对齐 |
| 恢复时区分回放与实时 | 否 | f1 契约增量 2 |
| 投影与脱敏 | 是（L1，P1/P2 裁决已通过） | 真实事件复测 |
| 五类情况 | 正常、取消、断连、结果未知要 A6；审批拒绝要 PR4 | 见 06 |

## 四、对应原文 ACP-A0～P4

| 原文编号 | 内容 | 状态 | 依赖 |
| --- | --- | --- | --- |
| A0-01～04 | 差距、契约基线、生命周期、身份 | 已交付（01、04、07） | 无 |
| A0-05 | MCP 绕过 | 单一端点已由 A2 完成；MCP 本身待 #29 | #29 |
| A0-06 | 协议版本 | 已选 v1；真实首帧待 Z1 | Z1 |
| A0-07 | 单一 CLI 入口 | 延后到 G1 之后（f1 R9） | G1 |
| A0-08 | 脱敏策略 | 已交付（08）；对齐目录待做 | fa2222f |
| P1-01 | `agentdesktop acp` | dev 入口已可用；CLI 延后 | G1 |
| P1-02～04 | 传输、协商、会话 | 已合入，L1 通过 | A4（真实身份） |
| P1-05、06 | 任务与 prompt 到 Runtime | 已合入；任务来自 `unit.run` 宣告 | A6 |
| P1-07 | 事件流 | 已合入 | 目录对齐、A6 |
| P1-08 | Run 状态查询 | 已合入，L2 只读通过 | 无 |
| P1-09 | Zed | 手册与采集工具已合入 | Z1、A6 |
| P2-01～03 | 列表、恢复、回放 | 已合入（L1） | A4、增量 2 |
| P2-04、05 | 审批、Ask/Auto | 已合入（`capability_missing` 即拒绝） | PR4 |
| P2-06、07 | 取消、unknown | 已合入；P2 裁决的明确终态 L1 通过 | A6 |
| P2-08 | 隐私 | 已合入；P1 裁决 L1 通过 | A6 |
| P2-09、10 | 长运行、编辑器兼容 | 用例已有 | A6、Z1；JetBrains 为 P2 |
| P3-01～10 | 出站 | 评估完成，不能通过；O1～O3 已裁决 | P3 实现 |
| P4 | 分发 | 未开始 | G1～G3、R9 |

## 五、合并规则

1. **不合并 #53**：Kevin 未批准。各线继续合入 `acp-skeleton`。
2. **跟随 main**：main 每次有 Runtime 或契约变更（下一项是 fa2222f），协调者把 main 合入 `acp-skeleton`，各线在其上集成。
3. **每次合入前本机严格池回归**：`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test --filter AgentDesktopACPTests` 与全包各一次，记录退出码（CI 删掉了这一步，README 第八节）。
4. **真实写操作只经 runtime/1**：ACP 不新增执行调度或 GUI 控制入口。
5. **#111 与 #53 的关系**：#111 把 `acp-skeleton` 作为实验源码收进 main 的提议由 Kevin 与 f1 决定；在决定前，ACP 的改动仍只进 `acp-skeleton`。
