# 实施进度

状态词：DONE（有测试证据）、PARTIAL（部分完成，缺口写明）、NOT_STARTED。产品用例状态以 tests/cases.csv 的 ID 记录；只有实际执行断言的测试才算 PASS，契约层测试不代表对应用例的服务端或真机部分已通过。

| 任务 | 状态 | 说明 |
| --- | --- | --- |
| T00 基线与迁移清单 | NOT_STARTED（本分支） | 单仓迁移由 `codex/merge-desktop-core-20261008` 那条线负责；本分支不动引擎依赖与旧两仓规则 |
| T01 原生执行边界 G0 | NOT_STARTED | 同上；真实 GUI 输入入口保持关闭 |
| T02 合同、版本化解码、32 操作、CLI rpc | PARTIAL | AgentDesktopContracts：严格 JSON、Schema 子集校验器（加载合同文件做权威校验）、信封与分帧、错误码、操作目录、路由器（结果按合同自检）。尚缺：接入 ControlServer 的旧/新双解码、CLI rpc、C# DTO |
| T06 UI-TARS codec、坐标、Proposal | PARTIAL | 分支 gui-codec：GUI 领域类型（Contracts/Domain/Gui*.swift）、`CoordinateMapper`（显式协议、crop/resize/letterbox、负原点、不夹紧）、`UITarsCodec`（uitars_v1 严格单动作文法）、`FixtureJsonCodec`（仅测试模式）、`GuiCodecRegistry`、`ProposalFactory`（身份字段只取自 Observation，输出过合同校验）。尚缺：GuiAiProvider（依赖 T05 AiService）、完整 prompt 组装与历史截图裁剪、C# 端 |
| T03–T05、T07–T14 | NOT_STARTED（本分支） | |

## 契约层测试覆盖（swift test --filter AgentDesktopContractsTests）

| 用例 | 覆盖的部分 | 未覆盖 |
| --- | --- | --- |
| RPC-001 | 信封、requestId 关联、单行、ok/result 与 ok/error 互斥 | 真实 socket 上的 application service |
| RPC-002 | 新旧版本分流、未知版本、op 替代 command | 旧 ControlRequest 解码器接入 |
| RPC-003 | 畸形 JSON、重复键、无效 UUID、未知命令、多余字段、缺 verification、模型脚本、缺幂等键；拒绝后合法请求成功；处理器调用 0 次 | provider/executor 计数（需 Runtime） |
| RPC-004 | 1 MiB 帧边界（恰好与 +1）、内联截图字段拒绝 | 读取过程中的提前终止已由 FrameReader 实现，未在真实 socket 上压测 |
| SEC-005 | 端点规则（Schema 部分） | 实际连接地址是否为 loopback 的运行时检查 |
| CFG-007 | GUI 限额上限（Schema 部分） | 服务端 LIMIT_EXCEEDED 路径 |
| COO-001..008 | 全部纯数学断言（误差 ≤1e-6）；COO-007 固定 seed 100 点、非对角矩阵、奇异矩阵 | 无（纯数学用例） |
| GUI-001 | codec 侧：恶意字段（execute/shell/screenshot/approval/raw event）一律 INVALID_ACTION；codec 只持有 provenance；Proposal 键集合等于合同键集合 | executor/capture 计数（T07 Runtime） |
| GUI-002 | 12 组 golden、28 组拒绝（未知/多动作/drag/重复参数/越界等）、type 文本脱敏 | 普通日志/events 落盘后的脱敏扫描（T07/T10） |
| GUI-004 | codec 侧：stamp/screenshotId 只取自 Observation，模型文本不能改写；非本次观察的截图 STALE_OBSERVATION；按所选截图自身的变换映射 | Runtime 输入前的 generation/target/lease 复核（T07） |
| 规格示例 | 规格 HTML 中 35 个请求、32 个成功响应、1 个错误响应全部通过校验 | |
