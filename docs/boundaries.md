# 组件边界

依据路线文档第七节和第十节（docs/roadmap/2026-10-07-agent-desktop-roadmap-v3.md）。

## 归属

| 仓库或包 | 归属 | 验收 |
| --- | --- | --- |
| [2ndscreen](https://github.com/szrunworld/2ndscreen) | 原生引擎、通用 Runtime、协议、CLI/MCP、底层 SDK；以 tag 发布 | 无 BOSS 生产依赖时可构建运行；保留原生测试 |
| agentdesktop（本仓） | 产品 App、品牌、UI、安装更新、官网与发布材料 | 按版本依赖引擎，不 fork；可单独发布 |
| 业务 Agent 仓 | 每个业务一个仓：Agent Core、独立 App Shell、插件声明 | 两种入口共用一个业务核心；更新不重发 Desktop |

依赖方向只有一个：agentdesktop → 2ndscreen。引擎仓不得依赖或引用本仓。

## 本仓包含

- `Sources/AgentDesktop`：宿主装配（角色与 endpoint、状态栏菜单、主虚拟显示、预览、窗口搬移、Agent 屏幕菜单、测试副本）。来源是引擎仓 `Sources/SecondScreen` 在 7a96154 的版本，去掉 Android 后裁剪而来，文件头记录了来源。
- `scripts/bundle-app.sh`：产品包装配、签名、产物清单。
- 产品文档、路线与验收记录。

## 本仓不包含

| 内容 | 原因 | 放在哪里 |
| --- | --- | --- |
| 虚拟显示、输入、截图、AX、Agent 屏幕、控制 socket 的实现 | 引擎 | 2ndscreen 的 SecondScreenCore / SecondScreenRuntime |
| 任务状态机、租约、审批、预算、产物校验 | 共享 Runtime | 2ndscreen 的 packages/task-runtime；界面通过薄 TaskClient 读结构化 JSON，不在产品仓另写一套调度或预算器 |
| Android 镜像、配对、adb 与 scrcpy 下载 | 首发不带（路线决定 4） | 引擎的开发宿主 2ndscreen.app；后续作为可选适配 |
| BOSS 等业务的页面识别、候选人模型、简历清单、采集 runner | 业务 Agent | 各业务仓 |
| 开发用路径（Python 虚拟环境、本机目录） | 不进产品 | 开发者本机 |

## 产品宿主与引擎开发宿主

| 项目 | Agent Desktop | 2ndscreen.app |
| --- | --- | --- |
| Bundle ID | com.agentdesktop.app（CLI 签名 ID 加 `.cli`） | io.github.szrunworld.2ndscreen |
| 控制 endpoint | `~/Library/Application Support/AgentDesktop/control.sock` | `~/Library/Application Support/2ndscreen/control.sock` |
| 主虚拟显示序列号 | 5 | 1（vdisplay 命令用 2） |
| Agent 屏幕序列号起点 | 500；测试副本 950 | 100；测试副本 900 |
| 签名 keychain | agentdesktop-signing | 2ndscreen-signing |
| 用户偏好域 | com.agentdesktop.app | io.github.szrunworld.2ndscreen |

两者可以同机运行，各自管理自己创建的屏幕。它们之间没有资源仲裁，共享协调者（路线 C02）落地前不要让两者同时操作同一个目标应用。

## 版本与依赖

- `Package.swift` 用 `exact` 固定引擎版本，`Package.resolved` 一起提交；打包脚本在编译前核对 checkout 在锁定提交上，且工作区、暂存区和未跟踪文件都干净，否则拒绝。
- 引擎改动的路径：在 2ndscreen 合并 → 发布新 tag → 本仓改依赖版本 → 重新打包验收。
- 不改旧 tag；不在 `.build/checkouts` 里改代码；`swift package edit` 只用于本机试验，CI 与发布构建拒绝。

## 待引擎提供的能力

| 需要 | 对应路线工作项 | 本仓目前的处理 |
| --- | --- | --- |
| 不带业务 skills 的 task runtime 安装选项 | C01 | 产品包不装 task runtime；入口脚本把 runtime 绑定到产品包内路径，`task` 与 MCP 的 task 工具返回 `capability_missing`，不借用运行中 2ndscreen.app 的 runtime |
| CLI 的宿主绑定与 runtime 发现策略（不再按旧 bundle id 兜底） | 上游后续版本 | 产品只支持 `bin/` 下的入口脚本；`libexec` 二进制不作为入口 |
| endpoint 所有权与版本握手、跨产品仲裁 | C02 | 单实例检查只看是否有人监听 |
| 统一任务读模型与按任务控制 | C03 | 未开始任务界面 |
| ControlServer 对无请求连接的 SIGPIPE 处理 | 已提 issue | 宿主进程忽略 SIGPIPE |
