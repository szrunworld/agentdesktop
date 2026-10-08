# contracts/ai-gui/v1 — 只供 Windows 端，待迁移

2026-10-08 起（A2 / PR2b-2），macOS 产品已不再使用这里的文件：

- ai/1 信封（`schemaVersion`、`command`、`context.idempotencyKey`）已废止。所有调用统一走 runtime/1 的单一端点，见 `docs/architecture/runtime-api-v1-freeze.md` §9。
- AI 服务方法的 params、result 和领域类型定义迁到了 `contracts/runtime/v1/service.schema.json`，方法目录在 `contracts/runtime/v1/methods.json`（`servedBy: "ai-service"`）。

`windows/src/AgentDesktop.Contracts` 仍嵌入并测试这些文件。Windows 线迁移到 runtime/1 之后，删除本目录及 C# 的 ai/1 信封实现。在此之前请勿修改这些文件：它们不再是 macOS 的合同，改了只会让两端分叉。
