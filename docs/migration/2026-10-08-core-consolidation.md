# 核心并入 AgentDesktop — 2026-10-08

用户决定：后续只维护 AgentDesktop，所有核心功能合入这个项目。原版本未发布，不设置旧版本、旧 CLI、旧 Bridge 或第二客户端的兼容义务。

## 固定来源与目标

| 项目 | 记录 |
| --- | --- |
| 目标仓基线 | `szrunworld/agentdesktop@91cfd09a9c0213baf35e8191f135319db93a29f1` |
| 源主线 | `szrunworld/2ndscreen@da5677c2be421dc2d35cdda5cdf66b7134f6a381` |
| 完整源保全提交 | [`49218be42ed0af1cdaeee424d684103551d79a31`](https://github.com/szrunworld/agentdesktop/commit/49218be42ed0af1cdaeee424d684103551d79a31) |
| 完整导入树 | `9615b6a03a0b463ae494d8439fb38c7ec849d143`，与本地逐文件构造的树一致 |
| 源文件清单 | [233 个文件的 blob、SHA-256、大小与模式](2ndscreen-import.json)，原始字节合计 3,439,095 |
| 当前处置清单 | [integration-map.json](integration-map.json)，区分活动文件、迁移路径和本仓历史保全 |
| 历史与开放分支 | [提交索引](2ndscreen-history.tsv)、[引用索引](2ndscreen-refs.json)、[七个 PR 补丁](2ndscreen-open-prs.json) |

## 保全和收敛

先把 233 个原文件完整加入本仓来源提交，再清理当前树。这样原 TS Hub、账本、run_unit、恢复、流程晋级、Bridge 的动作记录和测试都有本仓依据，但无需保留旧运行入口。

当前有 116 个源文件保留为活动核心或可选原生适配，117 个源文件只保留于导入历史；另有新产品接入代码、验证脚本和文档。这个文件数是处置口径，不是功能数量。Core、Runtime、原生视觉和学习、C# 后端、原生工具及其测试均接续复用。

```bash
# 在 agentdesktop 本仓查看需要提取的历史语义，无需拉取旧仓。
git show 49218be42ed0af1cdaeee424d684103551d79a31:engine/packages/task-runtime/src/agent-hosting.ts
git show 49218be42ed0af1cdaeee424d684103551d79a31:engine/packages/task-runtime/src/procedures.ts
git show 49218be42ed0af1cdaeee424d684103551d79a31:engine/Sources/TarsAgent/Bridge.swift
```

旧 Bridge、TS task 命令、BOSS 截图采集工具、独立旧 App 和安装脚本不出现在当前编译与发布路径。其独有语义的接管情况见 [runtime-semantics-to-port.md](runtime-semantics-to-port.md)。删除旧入口不等于已实现新的执行屏障或原生 Hub。

## 实际构建变化

- App 使用本地 `engine/` package；删除旧外仓 pin 与 checkout 守卫。
- Root App 与原生 CLI 都从本仓源码构建，默认包只有公开 `agentdesktop` 入口，内部 binary 为 `agentdesktop-cli`。
- macOS endpoint、发现、事件与资源定位使用当前产品身份；不发现旧 App。
- 模型配置读取当前变量与 `~/.config/agentdesktop/model.env`；不迁移旧用户配置。
- Android 宿主的独有源码移到 `engine/optional/mobile/macos/`，不保留第二 App target。
- Windows 原生后端继续复用 C#，当前可执行文件使用 `AgentDesktop.Host` / `agentdesktop` 身份。
- 根 CI 构建本仓 Swift 与 Windows 后端，并检查打包后 CLI/MCP 公布的实际工具。

## 已有新 AI/GUI 分支

[PR2](https://github.com/szrunworld/agentdesktop/pull/2) 的新 AiService、GuiAiProvider、GuiExplorer、合同、配置、运行库和正式 CLI 保持独立实现成果。本轮没有覆盖或复制它们，也没有把该 PR 直接合入 main。后续将当前原生桌面端口接入其受管契约；T01/G0、真实停止和 MAC/WIN 真机验收仍需直接证据。

当前 `engine/windows` 是原生桌面后端；PR2 `windows` 是新合同层。两者应在本仓组合，不互相覆盖。当前原生 CLI 和 PR2 CLI 最终对外收敛为一个 `agentdesktop`。

## 七个未合并 PR

保留 #56 ACP、#64 任务契约、#65 通用 TS 构建、#66 endpoint 所有权、#67 登录清理、#68 CI 和 #69 视觉 RFC。它们的 head 均不是本次源提交的祖先，补丁未自动应用。所有后续采用、修订和回归均在 AgentDesktop 进行。

## 验证与结束条件

见 [本次验证记录](2026-10-08-consolidation-validation.md)。代码、GitHub 分支、main、平台 CI、真机验收和公开发布分别标识。旧仓只保留历史，不再维护核心；本轮不修改旧仓归档开关或删除历史。
