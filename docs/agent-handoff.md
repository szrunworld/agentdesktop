# 后续 Agent 交接

先读 [architecture.md](architecture.md)、[迁入记录](migration/2026-10-08-core-consolidation.md) 和 [语义接管清单](migration/runtime-semantics-to-port.md)。

1. 唯一核心仓为 `szrunworld/agentdesktop`。不得恢复外仓 pin、等待 2ndscreen tag、submodule、第二客户端或旧 Bridge。
2. 复用 `engine/` 现有原生核心、视觉、Learning/Procedure、CLI/MCP 和 Windows 后端。内部类型名不是旧版本兼容承诺。
3. 复用 [PR2](https://github.com/szrunworld/agentdesktop/pull/2) 已有 AiService、Provider、Explorer、合同、运行库和正式 CLI。PR2 尚未关闭 G0/T01，不要重复写这些模块或将替身验收当真机通过。
4. 本次原生 CLI 内部二进制为 `agentdesktop-cli`，包内公开入口为 `agentdesktop`；后续与 PR2 正式 CLI 在同一新契约下收敛，不维持两套对用户的命令。
5. 两处 Windows 目录分别是已有原生后端和新合同层，整合时保留两者有效实现与测试。
6. 原 TS Hub、run_unit、恢复、预算与流程晋级源码/测试在本仓来源提交中；按语义提取，不恢复旧运行环境。
7. 同 Desktop 有序、跨 Desktop 并发。取消受理不等于执行停止；unknown 业务效果不等于可以提前交还执行权。
8. BOSS Python、Recruiting 服务端保持业务职责；一个客户端可以托管业务进程。

源代码保全、提交到分支、合入 main、平台 CI、真机验收和公开发布分别记录。七个源 PR 的补丁是未合并资产，不能因补丁保存而声称功能已启用。
