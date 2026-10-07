# 开发 Agent 启动说明

你要在现有 **AgentDesktop 仓库**完成 AI 服务与 GUI 模型端到端接入。此包是完整实施合同与开发辅助材料，不是已经完成的产品实现。

## 任务目标

沿用用户 FINAL v1.0 架构：AgentDesktop 单仓；macOS Swift、Windows C# 原生 Runtime；共享 AiService 管理模型连接、凭据、协议、预算、取消和用量；GuiAiProvider 只产生建议；GuiExplorer 负责有界局部循环；Runtime 是唯一真实输入执行方。BOSS Python 保留业务规划。

参考 CC Switch 的连接配置与服务层设计，但 GUI 必需截图不能被兼容转换删掉，未知动作不能被静默过滤成成功。对照主规范的固定源码 SHA，开工时重新核对实际 HEAD。

最终用户流程是：创建连接 → 模型配置 → GUI 配置 → 四层能力测试 → 为指定 Desktop 启动有明确验证条件的任务 → 查看模型尝试与实际动作 → 验证完成或处理取消/未知结果 → 查看用量和诊断。

## 先读这几项

1. `docs/implementation-spec.md`：完整设计、状态、模块、迁移、CLI、T00–T14 和来源。
2. `contracts/domain.schema.json`、`rpc.schema.json`、`operations.json` 与 `docs/contracts.md`：类型、32 操作及语义。
3. `contracts/interfaces/AiGuiContracts.swift` / `.cs`：内部接口设计，尚未编译，不是生成的 wire codec。
4. `wireframes/index.html`、`docs/wireframes.md`：8 个页面、9 种模拟状态和逐控件合同。静态图位于 `wireframes/static`。
5. `tests/cases.csv`、`docs/test-and-acceptance.md` 与验收结果模板：90 个待执行产品用例及 G0–G6。

## 立即能运行的检查

在解压目录执行：

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -r tools/requirements.txt
.venv/bin/python tools/run_handoff_checks.py
```

Windows 使用 `.venv\Scripts\python.exe`。此命令检查材料的 Schema、102 个夹具及本地 mock；它不启动原生 Runtime。原生产品的 90 个用例仍全部是 NOT_RUN。

可选离线线框检查：

```bash
node wireframes/validate-wireframes.mjs
```

真实浏览器检查要求已安装 Playwright 和浏览器，可通过 `AGENTDESKTOP_CHROMIUM_EXECUTABLE` 指定二进制；详情看 wireframes README。浏览器缺失必须报告 BLOCKED，不能当成通过。

## 第一轮工作：不要停在计划阶段

先执行 T00：读取真实仓库说明与构建命令、记录 commit、核对旧依赖和 CLI、形成逐文件迁移清单。随后实现 T01 的 G0 原生执行边界；同时可推进 T02–T04 的合同、存储与凭据。若已有同职责代码，验证后复用，不重复造并行服务。

第一条可验证纵向切片是：一个 openai_chat 连接、一个模型 profile、一个 uitars_v1 GUI profile，通过合成能力测试后，在指定中立表单中输入 Ada 并 Apply 一次，最后由新 Observation 的固定文本谓词确认成功。

真实 GUI 输入入口在对应后端 G0 通过之前保持关闭。可以先用 StubTransport/SpyExecutor 完成纯契约测试，但必须明确其证据范围。

## 开发顺序和可并行任务

| 阶段 | 任务 | 完成标志 |
|---|---|---|
| 建立底座 | T00、T01、T02 | 单仓迁移清单、原生 scope/target/receipt/unknown、版本化本地 IPC。 |
| AI 服务 | T03、T04、T05 | SQLite CAS/幂等、Keychain/DPAPI、异步 HTTP、预算/usage。 |
| GUI 运行 | T06、T07、T08 | 严格 codec/坐标、Explorer/Verifier/取消、四层能力报告。 |
| 产品操作 | T09、T10、T11 | W01–W08、CLI 和同一后台状态。 |
| macOS 验收 | T12 | G0–G5 实际执行与 clean install。 |
| Windows 对等 | T13 | 原生 C#、相同语义与 G6 独立证据。 |
| 收尾 | T14 | 删除旧路径、支持矩阵、构建/安装/验收证据与发布说明。 |

## 每个 PR 必须带什么

- 具体解决的问题、改动后的行为、目标代码落点和接口变更。
- 对应 case ID 的真正测试实现、命令、结果、证据路径和已知限制。
- 触及 contract 时同步 Schema、两端 DTO、fixture、UI/CLI 和测试。
- 触及实际输入时说明 target、generation、lease、snapshot 与 ActionReceipt 的验证点。
- 引用旧源代码时记录 source commit/目标文件，保留适用许可。

## 不允许被“实现细节”弱化的条件

模型、Parser、UI 都不能绕过 Runtime 直接输入。配置修改不改变已启动 run 的不可变绑定；取消只修改 currentGeneration 等运行状态。密钥撤销必须失效旧调用。socket 正常关闭不取消已受理任务。模型 finish 不自证完成。未知输入不能自动重发。缺失 usage 不填零。Windows 需要自己的输入与隔离证据。

默认硬上限：20 决策步、120 秒主动执行、每步 2 次/全程 30 次模型尝试、单次 1024 output tokens、5 秒 wait、5 张图、8 MiB base64 payload。超时后不得开始新工作，已提交未知输入的安全收尾不能为满足时限而提前释放。

`gui.runs.start` 必须固定 verification，V1 为 element_text_equals/static_text。中立流程目标只含 Name=Ada+Apply，精确预期是 `已保存：Ada / MAC-001-A / 提交次数 1`，不声称它验证了备注或其他控件。

## 最终提交格式

提交实际代码 commit、可安装包、真实测试命令、G0–G6 结果矩阵、证据索引、完整的页面/CLI 录制、迁移及回滚说明、已删除旧路径清单和支持矩阵。复制验收模板记录执行，不批量将 NOT_RUN 改成 PASS。

遇到环境缺失，继续完成不依赖该环境的工作，并列具体 BLOCKED 项。不能将 mock 的 23 个检查、102 个 Schema 夹具或静态线框图通过，称为 AgentDesktop 产品已经通过验收。
