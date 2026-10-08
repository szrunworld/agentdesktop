# 组件边界

依据：单仓通用平台增量开发总计划（2026-10-08，DEV-00「单仓迁入与规则更新」与第 6.4 节「每个迁入提交的验收记录」）。它取代了路线文档（docs/roadmap/2026-10-07-agent-desktop-roadmap-v3.md）第七、十节里「产品仓按版本依赖引擎、不携带引擎代码」的规则。

## 规则

- **单仓。** 原生引擎、Runtime、CLI、AI/GUI、产品宿主与界面都在本仓开发、评审、测试和发布。
- **不依赖旧引擎仓。** `Package.swift` 没有外部包依赖，也没有 `Package.resolved`；构建不拉取 [szrunworld/2ndscreen](https://github.com/szrunworld/2ndscreen)。CI 和 `scripts/bundle-app.sh` 都会检查这一点。
- **迁入必有来源。** 从其他仓迁入的每个文件在 [docs/migration/source-map.csv](migration/source-map.csv) 有一行：`targetPath, sourceRepo, sourceTag, sourceCommit, sourcePath, blob, sha256, decision, semanticChanges, tests, license`。`decision=copied` 表示字节与来源一致；改动后改为 `modified`，并在 `semanticChanges` 写明原因。`scripts/verify-engine-source-map.sh` 复算 sha256 与 git blob，并拒绝 `Sources/Engine`、`Tests/Engine` 下不在清单里的文件；CI 与打包脚本都会运行它。
- **第三方声明随代码走。** 迁入代码参照或包含的第三方作品，其许可声明放在 [docs/engine/THIRD_PARTY_NOTICES.md](engine/THIRD_PARTY_NOTICES.md)，并随产品包附带。
- **旧仓不再承接新产品主线任务。** 2ndscreen 之后的修复按需逐文件补迁并更新来源行，不整树覆盖本仓。

## 本仓包含

| 路径 | 内容 |
| --- | --- |
| `Sources/Engine/CGVirtualDisplayPrivate` | CoreGraphics 私有虚拟显示类的声明（C/ObjC shim） |
| `Sources/Engine/SecondScreenCore` | 平台原语：虚拟显示与预览、显示配置与睡眠、窗口搬移与包含、后台输入、AX、焦点保护、截图、本地视觉、控制协议类型 |
| `Sources/Engine/SecondScreenRuntime` | Agent 屏幕、屏幕上应用的输入、Agent 光标、引擎控制 socket |
| `Tests/Engine/*` | 上述两个模块的原有单元测试（不需要真实显示或授权） |
| `Sources/AgentDesktop` | 宿主装配（角色与 endpoint、状态栏菜单、主虚拟显示、预览、窗口搬移、Agent 屏幕菜单、测试副本）；来源是引擎仓 `Sources/SecondScreen` 在 7a96154 的版本，去掉 Android 后裁剪而来，文件头记录了来源 |
| `Sources/AgentDesktopRuntime` 等 | Runtime、Protocol、Client、CLI、Contracts、AI、GUI、Service、AIUI |
| `scripts/` | 打包、签名、产物清单、来源清单校验 |

引擎模块暂时沿用 `SecondScreenCore` / `SecondScreenRuntime` 的名字，使迁入这一步不改产品代码；改名（例如 AgentDesktopCore）是后续单独的一步。

模块依赖方向：`AgentDesktop`（宿主）与 `AgentDesktopRuntime` → `SecondScreenRuntime` → `SecondScreenCore` → `CGVirtualDisplayPrivate`。CLI、Client、Protocol、Contracts、AI、GUI 不导入引擎模块。

## 本仓不包含

| 内容 | 原因 | 放在哪里 |
| --- | --- | --- |
| 2ndscreen 的 ScreenCLI（`2ndscreen` 命令）、vdisplay、2ndscreen.app 宿主、TarsAgent | 产品的正式命令行是 `agentdesktop`；TarsAgent 按总计划第 6 节拆分迁入 AI/GUI，不整模块搬 | 2ndscreen 仓的 Git 历史 |
| 任务状态机、租约、审批、预算、产物校验的旧 TS 实现 | 由本仓 Runtime 原生实现 | 2ndscreen 的 packages/task-runtime（仅作参照） |
| Android 镜像的宿主界面、配对、adb 与 scrcpy 下载 | 首发不带；按总计划第 17A 节另行迁入 | 2ndscreen 仓；`SecondScreenCore/ADB.swift`、`JitterBuffer.swift` 已随模块迁入，但产品宿主不调用 |
| BOSS 等业务的页面识别、候选人模型、简历清单、采集 runner | 业务 Agent | 各业务仓 |
| 开发用路径（Python 虚拟环境、本机目录） | 不进产品 | 开发者本机 |

## 产品宿主与引擎开发宿主

旧的引擎开发宿主 2ndscreen.app 仍可能装在同一台机器上，两者身份互不相同：

| 项目 | Agent Desktop | 2ndscreen.app |
| --- | --- | --- |
| Bundle ID | com.agentdesktop.app（CLI 签名 ID 加 `.agentdesktop`） | io.github.szrunworld.2ndscreen |
| 控制 endpoint | `~/Library/Application Support/AgentDesktop/control.sock` | `~/Library/Application Support/2ndscreen/control.sock` |
| 主虚拟显示序列号 | 5 | 1（vdisplay 命令用 2） |
| Agent 屏幕序列号起点 | 500；测试副本 950 | 100；测试副本 900 |
| 签名 keychain | agentdesktop-signing | 2ndscreen-signing |
| 用户偏好域 | com.agentdesktop.app | io.github.szrunworld.2ndscreen |

两者可以同机运行，各自管理自己创建的屏幕。它们之间没有资源仲裁，共享协调者（路线 C02）落地前不要让两者同时操作同一个目标应用。

## 后续工作

| 需要 | 对应工作项 | 目前的处理 |
| --- | --- | --- |
| 引擎模块改名、按 Core/Native 重组 | DEV-00 之后的独立 PR | 保留原模块名 |
| endpoint 所有权与版本握手、跨产品仲裁 | C02 / DEV-02 | Runtime endpoint 有 flock 单实例；引擎 control.sock 仍是「有人监听就退出」 |
| 引擎 control.sock 可绕过 Runtime | 收口到 Runtime | 宿主仍开着该 socket |
| ControlServer 对无请求连接的 SIGPIPE 处理 | 2ndscreen 已修（#62，v0.2.0 之后），待补迁 | 宿主进程忽略 SIGPIPE |
