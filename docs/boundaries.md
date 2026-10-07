# 组件与维护边界

2026-10-08 起，AgentDesktop 是唯一核心仓库。产品和 Core/Runtime/GUI/CLI/MCP/Windows 的关联修改在同一个 PR 构建验证。核心源位于本仓 `engine/`；新 AI/GUI 模块继续使用其已开发的仓内目录，不另造副本。

- 平台后端处理系统显示、窗口、观察和输入。
- Runtime 管理 Desktop 控制权、顺序、目标和执行回执；GUI 探索与学习归 Runtime。
- Provider 负责模型建议；不调用桌面执行器。
- Hub 管理 Agent 配置、进程、状态与结果。
- BOSS/Recruiting 保留业务规则、限额、去重、邮箱、解析和入库。

当前产品只有 AgentDesktop 和新 `agentdesktop` 命令。原内部模块标识不构成旧兼容 API。旧 TS/Bridge/独立 App 从活动树移除，必要算法及测试在本仓来源提交中保全。当前状态以 [architecture.md](architecture.md) 为准；旧路线与旧验收只作为历史证据。
