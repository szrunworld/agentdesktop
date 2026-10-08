# 引擎迁入单仓验收记录（2026-10-08）

对应：单仓通用平台增量开发总计划 DEV-00「单仓迁入与规则更新」（CLI 方案里程碑 PR5 之前的引擎迁移步骤）。基座 `ai-gui-foundation` c8833c4。

## 迁入了什么

来源：`szrunworld/2ndscreen` tag `v0.2.0`，提交 `7a9615406b4bbc2fcf09224a30667404b4765ecb`，即此前 `Package.swift` `exact: 0.2.0` 锁定、`Package.resolved` 记录的同一提交。文件取自该 tag 的 git 树（`git archive v0.2.0`），不是任何工作区。

范围：`SecondScreenCore`、`SecondScreenRuntime` 两个产品及其传递依赖，外加两个模块原有的单元测试。

| 目标目录 | 来源目录 | 文件数 | 行数 |
| --- | --- | --- | --- |
| `Sources/Engine/CGVirtualDisplayPrivate` | `Sources/CGVirtualDisplayPrivate`（C/ObjC shim：头文件 + shim.m） | 2 | |
| `Sources/Engine/SecondScreenCore` | `Sources/SecondScreenCore` | 20 | |
| `Sources/Engine/SecondScreenRuntime` | `Sources/SecondScreenRuntime` | 5 | |
| 源码小计 | | 27 | 5906 |
| `Tests/Engine/SecondScreenCoreTests` | `Tests/SecondScreenCoreTests` | 7 | |
| `Tests/Engine/SecondScreenRuntimeTests` | `Tests/SecondScreenRuntimeTests` | 1 | |
| 测试小计 | | 8 | 1311 |
| **合计** | | **35** | **7217** |

35 个文件全部字节一致（`decision=copied`，`semanticChanges=none`），没有任何文件被修改。两个模块在 v0.2.0 没有资源文件。

没有迁入：ScreenCLI（`2ndscreen` 命令）、vdisplay、SecondScreen（2ndscreen.app 宿主）、TarsAgent 及其测试、windows/android/agents/packages/skills、2ndscreen 的脚本。

## 构建与包结构的变化

- `Package.swift`：去掉 `https://github.com/szrunworld/2ndscreen.git` 依赖；新增 `CGVirtualDisplayPrivate`、`SecondScreenCore`、`SecondScreenRuntime` 三个 target（`path: Sources/Engine/...`）和两个测试 target（`path: Tests/Engine/...`）；`AgentDesktop`、`AgentDesktopRuntime` 改为依赖本仓 target。模块名不变，所以产品代码（`AppController.swift`、`HostRole.swift`、`main.swift`、`EnginePlatform.swift` 的 import）一行未改。改名是后续单独一步。
- 删除 `Package.resolved`；`swift package resolve` 不再生成它，`.build/checkouts` 为空。
- 删除 `scripts/check-engine-checkout.sh` 与 `scripts/test-check-engine-checkout.sh`（它们检查的 `.build/checkouts/2ndscreen` 已不存在）。
- `scripts/bundle-app.sh`：编译前运行来源清单校验，拒绝 `Package.resolved`/`Packages/`；不再构建和打包引擎的 `2ndscreen` 命令行（`bin/2ndscreen`、`libexec/2ndscreen`），产品包里出现名为 `2ndscreen` 的文件即拒绝；`build.json` 与分发清单的 `engine` 改为记录「本仓、迁自 2ndscreen v0.2.0 7a96154、35 个文件、0 个修改」；包内新增 `Contents/Resources/THIRD_PARTY_NOTICES.md`。
- CI（`.github/workflows/macos.yml`）：「依赖按锁定解析」换成「没有外部包」检查；新增来源清单校验及其回归用例；原「bundled 2ndscreen task 返回 capability_missing」一步换成「包内没有旧引擎命令行、带有第三方声明、build.json 的 engine 指向本仓 v0.2.0」。

## 来源清单

`docs/migration/source-map.csv`（位置与列按总计划 6.4 节：`targetPath, sourceRepo, sourceTag, sourceCommit, sourcePath, blob, sha256, decision, semanticChanges, tests, license`），一行一个迁入文件，共 35 行。

`scripts/verify-engine-source-map.sh`：对 `copied` 行复算 sha256 和 git blob id；`modified` 行必须写明原因；`Sources/Engine`、`Tests/Engine` 下每个文件都必须在清单里。生成清单时同时核对了每个文件的 git blob 与 v0.2.0 树里的 blob 一致。

`scripts/test-verify-engine-source-map.sh` 的 7 个回归用例：原样接受；改了 copied 文件拒绝；改后标 modified 并写原因接受；标 modified 但没写原因拒绝；多出未登记文件拒绝；登记的文件缺失拒绝；缺 sha256 列拒绝。

## 许可

2ndscreen 在 v0.2.0 没有 LICENSE 文件，也没有逐文件第三方版权头。但它的提交历史记录了参照：`BackgroundInput.swift`、`SkyLight.swift` 的事件投递配方参照 cua-driver（trycua/cua，MIT），焦点记录参照 yabai（MIT）——相关注释在 2ndscreen 09bfe6f 被删掉；`CGVirtualDisplayPrivate.h` 的声明形状参照 DeskPad（MIT）和 BetterDisplay。为稳妥，本仓在 `docs/engine/THIRD_PARTY_NOTICES.md` 保留三个 MIT 项目的版权与许可全文，并随产品包附带；清单的 `license` 列对这三个文件指向该声明。是否构成「实质性部分」需要法务判断，这里按保守处理。

## 验证结果（均直接检查退出码，不经管道）

| 项目 | 结果 |
| --- | --- |
| `swift build` | 退出码 0；没有生成 `Package.resolved`，没有拉取 2ndscreen |
| `swift test` | 退出码 0；410 个测试通过（原 349 + 引擎 61），2 个按设计跳过（Live model 需真实凭据） |
| `swift test --filter SecondScreen` | 61 个引擎测试全部通过，均不需要真实显示或授权 |
| `swift package resolve` | 退出码 0；无 `Package.resolved`，`.build/checkouts` 为空 |
| `scripts/verify-engine-source-map.sh` | 退出码 0：35 行，35 个字节一致，0 个修改 |
| `scripts/test-verify-engine-source-map.sh` | 7 个用例全部 ok，退出码 0 |
| `scripts/bundle-app.sh` | 退出码 0；包内 6 个文件：`MacOS/Agent Desktop`、`bin/agentdesktop`、`build.json`、`Info.plist`、`THIRD_PARTY_NOTICES.md`、`CodeResources`；`codesign --verify --strict` 通过 |
| `scripts/verify-archive.sh` | 「verified 6 files and 0 links」，退出码 0 |
| `agentdesktop version --format json` | ok，构建来源非 unknown |
| `agentdesktop runtime status --endpoint /nonexistent/...` | 退出码 3，`runtime_offline` |

## 测试副本冒烟（未触碰产品 endpoint）

测试副本：`open -n --env SECONDSCREEN_SOCKET=/tmp/adt-eng-smoke/side.sock`，Runtime endpoint `/tmp/adt-eng-smoke/side.runtime.sock`；凭据走测试副本的文件存储，不写登录钥匙串。

| 操作 | 结果 |
| --- | --- |
| `runtime status` | running，pid 与构建提交一致 |
| `doctor` | 6 项 ok（含屏幕录制、辅助功能） |
| `desktop create --size 1280x800` | ready，displayId 10，1280x800 HiDPI——由迁入的引擎创建虚拟屏 |
| `desktop destroy` | destroyed |
| 收尾 | SIGTERM 结束测试副本进程，删除 `/tmp/adt-eng-smoke` |

## 已知事项 / 后续

- 引擎模块仍叫 `SecondScreenCore` / `SecondScreenRuntime`，改名（例如 AgentDesktopCore）与按 Core/Native 重组另开 PR。
- 产品包不再带 `bin/2ndscreen`。写操作已由 `agentdesktop`（PR2）提供；宿主进程里的引擎 `control.sock` 仍在，收口到 Runtime 是后续工作。
- 产品代码里的少量注释仍提到 2ndscreen 依赖或 `2ndscreen` 命令（如 `HostRole.swift` 文件头），本 PR 不动产品代码，留到改名时一并清理。
- 2ndscreen 在 v0.2.0 之后的修复（如 #62 ControlServer SIGPIPE、#63 C01a）没有迁入；需要时逐文件补迁并把清单行改为新提交。
- 2ndscreen 原来只有 Windows CI，这 61 个引擎测试此前没有在 macOS CI 上跑过；本 PR 起在 macOS CI 上运行。
