# AgentDesktop 实施规划（遵循 ADR v2.2）

日期：2026-10-08。状态：Kevin 已于 2026-10-08 审核确认（四项裁决、负责人、四项补充约束）。本目录是唯一的实施规划；不另维护第二套设计规范。

## 权威顺序

新 ADR > 已冻结的公共契约 > 本实施规划 > 历史设计方案。

| 层级 | 文件 |
| --- | --- |
| 架构决定 | [`docs/architecture/ADR-v2.2-hub-ui-run-lifetime.md`](../architecture/ADR-v2.2-hub-ui-run-lifetime.md)，以及 Kevin 2026-10-08 的最终裁决（Hub Core 现在做、完整 UI 分阶段；Explorer 基础现在做、学习层下一阶段） |
| 公共契约 | [`docs/architecture/runtime-api-v1-freeze.md`](../architecture/runtime-api-v1-freeze.md) 与 `contracts/runtime/v1/`（#34 已冻结目录），由集成负责人 2ndscreen-5c 维护 |
| 实施规划 | 本目录 |
| 历史方案 | Downloads 中 2026-10-08 的设计文档；架构 FINAL v1.3、单仓合并方案 FINAL v1.3 已由 ADR v2.2 宣布过期 |

## 交付物

| 编号 | 文件 | 内容 |
| --- | --- | --- |
| 1 | [01-architecture-decision-matrix.md](01-architecture-decision-matrix.md) | 全部冲突的最终裁决与依据 |
| 2 | [02-implementation-plan.md](02-implementation-plan.md) | 阶段、依赖、PR 顺序、负责人；每个 PR 的输入、范围、测试、验收 |
| 3 | [03-runtime-contract.md](03-runtime-contract.md) | 接口、对象模型、状态机、错误码 |
| 4 | [04-agent-hub-integration.md](04-agent-hub-integration.md) | 配对、授权、连接、Run 管理如何接入 |
| 5 | [05-gui-explorer-roadmap.md](05-gui-explorer-roadmap.md) | 基础运行能力与学习能力分开 |
| 6 | [06-ui-mapping.md](06-ui-mapping.md) | Design v2.0 页面、Hub 八页、Explorer 八页与主窗口导航的对应 |
| 7 | [07-legacy-feature-gap-list.md](07-legacy-feature-gap-list.md) | 历史功能对照，防止迁移遗漏 |
| 8 | [08-e2e-acceptance-plan.md](08-e2e-acceptance-plan.md) | 跨模块测试用例、验收步骤与通过标准 |

视觉与交互验收基准：[`docs/design/v2/`](../design/v2/)，含 32 张渲染图、`screen-map.json`（页面用途、交互、规则）、`ui-checks-54.json`（设计源码包的 54 项交互检查）和四个合成应用夹具。

## 三个目标

1. AgentDesktop 能独立使用：不装任何第三方 Agent，也能使用 Desktop、AI GUI 和基础自动化。
2. 开放的 Agent 接入：第三方 Agent 通过公开 SDK / CLI / Runtime API 接入，不改平台源码；平台不依赖任何具体业务 Agent。
3. GUI Explorer 逐步形成可积累、可验证、可复用的操作经验。

## 通用规则

- 每个 PR 写明输入、修改范围、测试用例、验收条件，以及「采用的已有文件 / 新代码 / 删除的平行路径 / 契约与夹具更新 / 真机状态」。
- 只以执行过的断言和带证据的真机记录判定通过；编译成功不算验收；缺环境记 blocked，不记 pass。
- 测试命令看退出码，不经管道截断。真机验收只在 `/tmp/adt-*` 测试副本里做，不碰用户屏幕与登录钥匙串。
