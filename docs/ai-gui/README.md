# AI 服务与 GUI 模型（DEV-SPEC v1.0）

本目录归档 2026-10-08 的《AgentDesktop：AI 服务与 GUI 模型端到端实施方案 v1.0》交付包，并跟踪实施进度。原始 HTML 在 Kevin 的 Downloads 目录（AgentDesktop-AI-GUI-Implementation-Plan-v1.0.html），这里保存的是从中提取的全部附件。

| 文件 | 内容 |
| --- | --- |
| implementation-spec.md | 完整实施规格：决策 D01–D10、模块、状态机、坐标、预算、凭据、CLI、迁移单、T00–T14、G0–G6 |
| AGENT_START_HERE.md | 开发 Agent 启动说明 |
| interfaces/AiGuiContracts.swift / .cs | 内部接口声明（规格原文，未编译） |
| wireframes/index.html | W01–W08 可点击工程线框（演示数据，不是 App） |
| tests/cases.csv | 90 个产品用例，初始全部 NOT_RUN |
| tests/acceptance-result.template.json | 验收结果模板 |
| ../../contracts/ai-gui/v1/ | domain.schema.json、rpc.schema.json、operations.json（32 个操作）——合同的权威来源 |
| ../../fixtures/neutral-form.html | 中立验收表单（MAC-001-A） |

`Sources/AgentDesktopContracts/Resources` 是 contracts/ai-gui/v1 的逐字节副本，由测试保证二者一致。修改合同时先改 contracts/ai-gui/v1，再同步副本、两端 DTO、夹具和测试。

实施进度与证据见 [STATUS.md](STATUS.md)。
