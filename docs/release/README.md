# 首发交付（CLI 方案 v1.2 · PR6）

依据：《AgentDesktop CLI 通用首发代码方案 v1.2》§10 PR6「首发包与端到端验收」——安装包、签名、运行环境、支持矩阵、使用文档和故障场景；验收标准：**干净机器可用；制品来源明确；公开命令对应真实能力**。

范围以当前规划为准（`docs/plan/`，ADR v2.2 优先）：Agent Hub 完整界面与学习不在首发；发布门禁 G 见 `docs/plan/08-e2e-acceptance-plan.md` §8.5。

## 文档

| 文档 | 内容 |
| --- | --- |
| [支持矩阵](support-matrix.md) | 平台、架构、入口、Runtime 能力（默认 / 开关 / 不支持）、签名现状 |
| [安装与首次使用](install.md) | 核对、安装、权限、PATH、配对、MCP、升级、卸载与数据目录 |
| [故障场景](troubleshooting.md) | 按退出码和错误码给出原因与处理 |
| [S4 签名门禁](a4-release-gate.md) | Developer ID、hardened runtime、公证、`verified` 身份、Data Protection 钥匙串 |
| [CLI / MCP / SDK](../cli/README.md) | 命令、输出、退出码、典型流程 |

## PR6 交付项与现状

| 交付项 | 现状 | 证据 / 缺口 |
| --- | --- | --- |
| 安装包 | 有：保留 `.app` 结构的 zip + 分发清单 | `scripts/bundle-app.sh`；CI 上传 `Agent-Desktop-archive`。没有 DMG / pkg（zip 即分发格式） |
| 签名与公证 | **阻断**：开发包为本地自签名，Gatekeeper 拒绝 | 正式签名、公证流程在 PR #300（未合入）；缺 Developer ID 证书与两个 provisioning profile |
| 运行环境 | 明确 | macOS 14+、仅 arm64，见支持矩阵 |
| 支持矩阵 | 有 | [support-matrix.md](support-matrix.md) |
| 使用文档 | 有 | [install.md](install.md)、[CLI 说明](../cli/README.md) |
| 故障场景 | 有 | [troubleshooting.md](troubleshooting.md) |
| 制品来源明确 | 有，并自动检查 | 清单的 `engine.source`、包内 `build.json`、CLI `version` 的 `build.source`、Runtime 握手的 `build.source` 四处一致（`release-smoke.sh`）。本 PR 修正 `bundle-app.sh`：`build.json` 与清单此前分两次计算源码版本，构建期间工作区一变就会不一致 |
| 公开命令对应真实能力 | 有，并自动检查 | `verify-command-surface.py`（命令面）+ `release-smoke.sh`（打包后的 Runtime 实际提供契约中全部方法；`unit.run` 仅在开启 GUI 执行器时提供，`--gui-execution` 模式验证 96/96） |
| 干净机器可用 | **部分** | `release-smoke.sh` 模拟新用户：从归档解压到全新目录、空钥匙串、测试副本端点，验证握手、能力、`doctor`、未配对时一律 `pairing_required` 且不创建任何东西。**未做**：新账户上首次授予两项系统权限、下载后带隔离属性的 Gatekeeper 流程、配对确认窗口——这三项需要人在一台干净的机器或新用户账户上操作 |

## 发布候选版步骤

在同一个提交上：

1. `AGENTDESKTOP_RELEASE=1 … scripts/bundle-app.sh`（变量见 `a4-release-gate.md`，PR #300 合入后可用）；开发包则直接 `scripts/bundle-app.sh`。
2. `scripts/release-smoke.sh "build/Agent Desktop-<build>.zip" "build/Agent Desktop-<build>.manifest.json" --release --report <记录>.json`，再加 `--gui-execution` 跑一次。`--release` 会额外运行 `verify-release-signing.sh`。
3. S4 七项中的人工项（`verified` 握手、Data Protection 钥匙串隔离、第三方 Agent 签名分发）按 `a4-release-gate.md` 核对。
4. 发布门禁 G（08 §8.5）：contract / runtime / hub / explorer / sdk / ui 套件、SEC-01…05、E2E-01…12；**E2E-09（双 Desktop 并发 + 宿主同时打字）首发必过**；E2E-13 未运行只能记 not_run / blocked_environment。
5. 在干净的 macOS 用户账户上走一遍 [安装与首次使用](install.md) 1–6 节，记录到 `docs/acceptance/`。
6. 分发 zip 与 manifest，同时公布归档的 SHA-256。

## 当前不能发布的原因（截至 2026-10-11）

1. **S4**：没有 Developer ID 证书与 provisioning profile，开发包不得作为正式版本分发（Kevin 2026-10-09 裁决）。
2. **门禁 G** 尚未在同一提交上整体跑过；E2E-09 首发必过。
3. **干净机器**的人工部分（上表）未做。

## 需要决定的事

- **Intel**：首发是否只支持 Apple 芯片。若要支持 Intel，`bundle-app.sh` 需改为 universal 构建并在 Intel 机器上验收。
- **构建号**：`CFBundleVersion` 固定为 `1`，`CFBundleShortVersionString` 固定为 `0.1.0`。正式发布前需要定版本号规则（每次发布递增构建号）。
- **SDK 分发**：Python / TypeScript SDK 是否上架 PyPI / npm，还是只随仓库提供。
