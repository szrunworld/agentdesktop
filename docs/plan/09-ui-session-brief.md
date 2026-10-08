# 主窗口 UI 会话交接（U1–U9）

Kevin 2026-10-08 指派：主窗口 UI 由独立会话负责，只做界面与交互，不重新设计 Runtime，不建第二套状态模型，所有页面消费现有 runtime/1 契约。

## 先读

1. `docs/architecture/ADR-v2.2-hub-ui-run-lifetime.md`
2. `docs/plan/06-ui-mapping.md`（含 6.4 动作结果三级展示）
3. `docs/plan/02-implementation-plan.md`（U1–U9、依赖、验收）
4. `docs/architecture/runtime-api-v1-freeze.md` 与 `contracts/runtime/v1/`
5. `docs/plan/08-e2e-acceptance-plan.md`（UC01–UC54、HB-UI、ADR-02/07）
6. `docs/design/v2/`（32 张渲染图、screen-map.json、ui-checks-54.json）

## 约束

- 唯一主窗口：U1–U9 是同一窗口内的视图；导航按 06 文件 6.1。
- Runtime 是唯一执行状态来源：Run 的委托与持久、三轴状态、停止与恢复按 runtime/1；UI 不自建生命周期。
- Agent Hub 不托管外部 Agent：UI 只做连接、权限、状态与管理。
- 不把 BOSS、微信、小红书等业务写进平台 UI 或核心。
- 只复用已迁入 AgentDesktop 的代码；不重新引入旧 2ndscreen 菜单与架构（裁决 D35）。
- API 未实现时用 Mock Adapter 开发，Mock 只能实现正式契约里的方法与字段；契约缺口整理成需求交给 2ndscreen-f1，Explorer 缺口交给 2ndscreen-40；不修改它们的核心模块（AgentDesktopRuntime、Protocol、AI、GUI、Windows）。
- 正式服务失败时不回退样例数据；样例模式只能显式开启并持续标识。
- 测试不碰用户屏幕与登录钥匙串，真机在 `/tmp/adt-*` 测试副本里做。

## 阶段

1. 代码审计与页面映射：逐个对照 U1–U9，列出已有组件、缺失组件、依赖的 Runtime 方法（已实现 / frozen / reserved / 缺口）、实现优先级，形成分阶段 PR 计划。**先完成这一步再写代码。**
2. UI Shell：主窗口布局、导航、设计 token 与组件、页面容器，Loading / Empty / Error / Disconnected 状态。
3. 九个页面按 02 文件 U1–U9 实现。
4. Runtime 集成：先 Mock Adapter，再接实际 Runtime。
5. 测试与验收：九个页面导航与交互；Run 状态变化与 UI 同步；多 Desktop 多窗口；持久与委托 Run 的不同表现；Runtime 断开与重连；授权撤销后的页面状态；错误与恢复；UI 与 Runtime 一致性；主窗口关闭与 Run 生命周期（ADR-02、ADR-07）；RT-24 遮挡场景显示明确失败原因。

## 每个 PR 交付

页面实现清单、代码与组件清单、页面截图（离屏渲染 1440×1000，与 docs/design/v2 对照）、测试结果与退出码、Runtime 集成情况、未完成事项与阻塞依赖、验收报告。每个页面必须能实际运行和操作。

## 顺序

A0 核心整合 → Runtime 契约稳定 → UI 与 Runtime 完整集成 → 端到端验收。UI Shell 与不依赖真实 Runtime 的页面可以提前并行；U1 等 A0 合入后在新的基线上开分支。
