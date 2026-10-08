# AgentDesktop Architecture — 单仓实现基线

FINAL v1.3 · 2026-10-08。用户已决定只维护 `szrunworld/agentdesktop`；所有核心功能的源码、测试、缺陷修复与发布归这个项目。架构定稿不等于全部实现已通过验收。

## 1. 物理归属

根 App 通过 `.package(path: "engine")` 使用仓内原生核心；无 submodule、外仓 pin、双仓发布或第二客户端。现有 Swift/C# 内部模块标识可逐步整理，不用为旧调用方保留别名、旧数据目录或协议分支。旧版本未发布，本轮不设置旧用户升级、存量任务或数据兼容前置条件。

原仓 233 个主线文件完整进入本仓的一次来源提交。当前代码保留原生核心与必要测试；旧 TS 宿主、Bridge、业务示例、旧 App 和安装器退出当前代码。其独有语义和测试仍能从本仓 Git 历史直接提取，不再依赖维护旧仓。来源映射与未合并补丁见 [迁入记录](migration/2026-10-08-core-consolidation.md)。

## 2. 最终模块关系

| 模块 | 责任 |
| --- | --- |
| 原生 Runtime | Desktop 资源、观察、目标校验、控制权、动作顺序、执行回执与停止 |
| GuiAiProvider | 模型请求与响应、坐标与动作建议；不直接投递系统输入 |
| GuiExplorer | 有界局部 GUI 目标、已有流程选择、恢复、探索与后置验证 |
| Learning / Procedure | 通用 GUI 学习、流程版本、验证与零模型回放 |
| Agent Hub | 业务包配置、托管进程、状态和结果；用户只安装一个客户端 |
| BOSS / 业务 Agent | 账号与岗位策略、业务额度、去重、业务目标和业务验收 |
| Recruiting 服务端 | 邮箱收件、附件关联去重、解析、存储与业务结果 |

Agent 可直接调用 observe/act/wait/cancel，也可委托有边界的 GUI 单元目标。直接动作无需经过模型；Provider 仅产出建议。CLI、MCP、BOSS、Explorer 和回放最终必须共享同一受管执行边界。SDK/transport 是薄接入工具，不是另一套探索 Runtime。

## 3. 已有实现与接续工作

| 能力 | 本次合仓状态 | 仍需完成 |
| --- | --- | --- |
| 显示、窗口、AX、截图、原生输入 | Core 与 Runtime 已迁入本地 package | 每 Desktop 写控制、动作前目标重验、停止屏障 |
| 原生视觉与学习 | Swift/C# 算法和测试保留 | 用真实回执与新观察接入统一执行器 |
| CLI/MCP | 新唯一入口，仅公布当前原生工具 | 与新 Runtime/AI CLI 的合同和退出码统一 |
| GuiAiProvider / GuiExplorer / AiService | [PR2 固定分支](https://github.com/szrunworld/agentdesktop/tree/5f043797c4be479851e1f659b06ea885d796d060) 已有实现，尚未合入 main | 复用该实现、注入真实桌面端口、通过 G0；不能再说这些类从未实现 |
| TS Hub / run_unit / 恢复 / 晋级 | 全部源与测试在本仓导入提交历史中保全 | 从职责出发提取语义、由原生模块接管；不启动旧 TS 宿主 |
| Windows | `engine/windows` 保留原生后端；PR2 的 `windows/` 是新合同层 | 对齐二者合同，保留后端算法；不互相覆盖 |
| 手机 | 独有适配源码保全，原旧 App 删除 | 需要时装配到当前 App，单独验证 |
| BOSS / Recruiting | 业务职责保持独立 | 单客户端托管 Python，受管 API 与业务结果验收 |

PR2 报告 228 Swift / 87 C# 测试通过，但明确真实桌面为替身、G0 未过，MAC/WIN 真机用例未运行。上述分支结果不能替代本次迁入提交或真实 GUI 验收。

## 4. 执行与结果语义

同一 Desktop 内动作有序，不同 Desktop 独立并发；不能加一把全机 GUI 锁来代替隔离。动作需绑定 observation/target revision；显示布局变化、窗口搬移和销毁后必须在投递前重新核实目标。

| 状态 | 含义 | 后续动作 |
| --- | --- | --- |
| 停止已请求 | Runtime 已收到取消意图 | 拒绝新输入，处理在途执行 |
| 执行已停止 | 执行器与已投递输入有明确停止证据 | 才能交还控制权 |
| 停止无法确认 | 不能证明底层已停止 | 隔离会话，不分配给下一执行者 |

业务效果 unknown 与执行是否停止是两个独立字段。模型说 finished、输入函数返回、GUI 后置条件通过、附件收到和简历入库也不是同一个成功结果。BOSS 主链保持“客户端请求简历 → 平台邮箱 → Recruiting 收件、去重、解析与入库”。

当前 Swift detached 输入、Windows CLI 输入、模型取消和流程存储并发尚有明确接缝。本次不改写这些算法为已完成的新 Runtime；详见 [需要接管的语义](migration/runtime-semantics-to-port.md)。

## 5. 后续实现顺序

1. 合入本次核心迁移，核心修复与产品装配今后在同仓提交。
2. 完成 T01：每 Desktop 控制权、顺序、目标重验、停止及真实回执，验收宿主同时使用。
3. 复用 PR2 新 AI/GUI 模块与当前 Learning/Procedure，接入受管执行端口，统一正式 CLI。
4. 复用历史 Hub/run_unit/恢复测试语义，完成最小原生 Hub 和 Python BOSS 闭环。
5. 依据目标系统和实际分发包完成签名、权限、安装与发布验收。

历史复盘与会话纪要保留原话。当前架构、源码与验收证据优先于旧路线中的 TS、Bridge、两仓维护和全局队列假设。
