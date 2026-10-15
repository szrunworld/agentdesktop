# 发布冒烟验收记录（2026-10-11，CLI 方案 v1.2 · PR6）

构建：分支 `cli-pr6-release` 提交 `0411ee4`（基于 main `f15510c`），干净工作区上 `scripts/bundle-app.sh` 退出码 0，产出 `Agent Desktop-0.1.0-dev.zip` 与清单（归档 SHA-256 `dd057380…33ff`，5 个文件）。机器：macOS 15.1.0，arm64。

运行方式：`scripts/release-smoke.sh` 把归档解压到新建的 `/tmp/adt-rel-XXXXXX`（0700），用该目录里的测试副本端点和一个新建的空钥匙串文件（`AGENTDESKTOP_KEYCHAIN`）。未触碰产品端点 `~/Library/Application Support/AgentDesktop/runtime.sock`、登录钥匙串和用户屏幕上的窗口；没有创建 Desktop，没有任何输入。结束时 SIGTERM，进程退出后才删除目录（两次运行后 `/tmp/adt-rel-*` 均不存在）。

## 结果

| 检查 | 默认 | `--gui-execution` |
| --- | --- | --- |
| 归档与清单一致（`verify-archive.sh`） | 通过 | 通过 |
| 解压后签名 `codesign --verify --strict`（App 与 CLI） | 通过 | 通过 |
| 签名级别 | 本地自签，无 Team ID，flags 0x0，Gatekeeper 拒绝（如实报告；开发包预期如此） | 同左 |
| 架构 / 最低系统 | arm64 / macOS 14.0 | 同左 |
| 命令面（`verify-command-surface.py`） | 18 个关键命令在、旧入口拒绝、包内无第二个命令行 | 同左 |
| 来源：清单 = CLI `version` = Runtime 握手 | 均为 `0411ee4…` | 同左 |
| 握手 pid = 启动的测试副本 | 是 | 是 |
| 契约 implemented 方法 / Runtime 实际提供 | 96 / 95，只缺 `unit.run`（需开启 GUI 执行器） | 96 / 96 |
| Runtime 提供契约外方法 | 无 | 无 |
| `doctor` | 退出 0；`authentication` warn（未配对，预期）、`runs` skip；两项系统权限 ok（本机已授予同证书） | 同左 |
| 未配对：`runtime status` / `desktop list` / `desktop create` | 均 `pairing_required`，退出码 4，未创建任何东西 | 同左 |
| 结果 | **passed** | **passed** |

完整输出：[default.json](release-smoke-2026-10-11/default.json)、[gui-execution.json](release-smoke-2026-10-11/gui-execution.json)。

## 本轮发现

1. **来源不一致（已修）**：`bundle-app.sh` 写清单用构建开始时的源码版本，写 `build.json` 时重新计算。首轮构建期间工作区新增了文件，清单是 `f15510c…`，CLI `version` 报 `f15510c…-dirty`。改为两处共用 `SOURCE_REVISION`。
2. **`unit run` 默认不可用**：公开 help 列出 `unit run`，但产品默认不开 GUI 执行器，Runtime 如实不提供 `unit.run`，调用得到 `capability_missing`。这是设计上的开关（`HostRole.guiExecutionEnabled`），已写进支持矩阵、安装与故障文档；冒烟把它列为可选，并用 `--gui-execution` 验证开启后提供。
3. **CLI 说明的典型流程缺配对**：新用户照着第一条 `desktop create` 就会得到 `pairing_required`。已在 `docs/cli/README.md` 补上 `agents pair`。

## 未覆盖

- Developer ID 签名、公证、`verified` 握手（S4，缺证书；PR #300）。
- 干净用户账户上的首次权限授予、带隔离属性的下载、配对确认窗口：需要人操作。
- Desktop 创建、真实输入与并发（E2E-09 等，属于门禁 G 的其他套件）。

## 复验（2026-10-15，Codex 9ce4735 三条 P2 修复后）

分支合入 main `2bafe60` 后，在 `92f5591` 干净工作区重新打包（退出码 0）。

| 检查 | 结果 |
| --- | --- |
| 默认模式 | passed：95/96，`notServed = [unit.run]`，来源 `92f5591…` 四处一致 |
| `--gui-execution` | passed：96/96 |
| 反向：默认模式下让宿主开着 GUI 执行器（脚本临时副本） | 如预期失败，退出码 1：`served although the GUI executor is off: ['unit.run']`；失败路径照常停掉测试副本并删除目录 |
| 清理 | 三次运行后没有残留的 `/tmp/adt-rel-*` 目录或进程；宿主经 `scripts/lib/process-identity.sh` 按启动时记录的身份停止 |

架构检查：宿主与 CLI 必须都是 arm64 且一致，否则失败（本机构建为 arm64，正向通过；没有 Intel 构建可做反向实测）。
