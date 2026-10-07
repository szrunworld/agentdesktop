# 阶段 0 验收记录：宿主骨架

日期：2026-10-07。机器：开发者的 MacBook Pro（Apple silicon，macOS 15，Swift 6.0.3，Command Line Tools，无 Xcode）。
产品构建：0.1.0-dev，引擎 2ndscreen 0.2.0（7a9615406b4bbc2fcf09224a30667404b4765ecb）。

## 出口条件对照

路线文档阶段 0 出口：干净 checkout 可构建；真实新 App 响应 create/list/destroy 和截图；包无 Android 默认依赖与开发路径。

| 条件 | 结果 | 证据 |
| --- | --- | --- |
| 干净 checkout 可构建 | 通过 | `swift build -c release` 与 `swift build -c release --product 2ndscreen` 均成功；引擎 CLI 可直接从依赖图构建，不必进 checkout |
| 新 App 响应 create/list/destroy | 通过 | 测试副本与产品宿主两种角色各跑一轮，见下 |
| 新 App 响应截图 | 通过（2026-10-07 21:47 补验） | 用户通过菜单 Show Preview 触发系统提示并授权屏幕录制，重开 App 后：请求经 `bin/agentdesktop` 发到产品 endpoint，`screen list` 的主屏名为 Agent Desktop，确认响应者是新宿主；`screen create verify 1280x800` → `screenshot` 返回 ok，PNG 可解码，2560×1600 即 1280×800 HiDPI，画面是该工作屏自己的桌面与菜单栏；`screen destroy` 后列表为空。21:49 用户授予辅助功能后补做：`app launch --bundle com.apple.calculator` 把计算器放到工作屏 verify3，截图里左上角是计算器窗口，背景是该屏桌面；`window release` 把窗口交还主显示器，`window move` 再放回工作屏，`app quit` 退出计算器，`screen destroy` 后列表为空 |
| 包无 Android 默认依赖 | 通过 | 包内文件只有宿主、`bin/2ndscreen`、`bin/agentdesktop`、`build.json`、Info.plist、签名；脚本对 adb/scrcpy/android 目录/boss skills 做了拒绝检查 |
| 包无开发路径 | 通过 | 没有 Python 路径、没有 task runtime 目录；`android.list` 等命令返回「not supported by Agent Desktop」 |

## 测试副本（SECONDSCREEN_SOCKET 指向独立测试 endpoint）

```
open -n --env SECONDSCREEN_SOCKET=~/Library/Caches/agentdesktop/stage0-test.sock "build/Agent Desktop.app"
2ndscreen screen list                      → ok, 0 screens
2ndscreen screen create --name stage0 --size 1280x800
                                           → ok, displayID 4, 1280x800 HiDPI, frame x=1920
2ndscreen screen list                      → 1 screen, kind agent
2ndscreen screenshot --screen stage0 …     → 拒绝：需要屏幕录制权限
2ndscreen android devices                  → 拒绝：android.list is not supported by Agent Desktop
2ndscreen screen destroy stage0            → ok；list 为空
kill -TERM 宿主                             → 进程退出；socket 文件残留（非正常退出路径不走 stop）
```

进程是 `build/Agent Desktop.app/Contents/MacOS/Agent Desktop`，不是 2ndscreen.app。

## 产品宿主（默认 endpoint）

为了不改动用户的显示排列，测试前把偏好 `enabled` 设为 false，测试后删除偏好域。

```
open -n "build/Agent Desktop.app"
bin/agentdesktop screen list               → ok（包装脚本把 SECONDSCREEN_SOCKET 指到产品 endpoint）
裸 connect + close 产品 endpoint             → 宿主仍存活（见下方缺陷）
open -n 第二次                               → 第二份立即退出，只剩一个宿主进程
bin/agentdesktop screen create/list/destroy → ok
osascript quit                              → 进程退出，socket 文件被清理
```

2ndscreen.app 当时没有运行；它的 endpoint 目录不受影响。

## 发现的缺陷

| 缺陷 | 处理 |
| --- | --- |
| 引擎 ControlServer 对「只连接不发请求」的客户端写错误响应，宿主被 SIGPIPE 结束（退出码 141）；引擎自己的单实例预检查就是这种连接，所以第二次启动会杀掉第一份 | 宿主入口 `signal(SIGPIPE, SIG_IGN)`；引擎 issue [szrunworld/2ndscreen#61](https://github.com/szrunworld/2ndscreen/issues/61) |
| 单实例检查不是原子所有权；两份同时启动可能都通过 | 保持现状，等 C02 共享协调者 |
| 非正常退出后 socket 文件残留 | CLI 对无人监听的 socket 会报「not running」，不误判；C02 处理所有权清理 |

## 未做的事

- 没有用拟发布签名（Developer ID）和 helper 启动模式，没有公证试包。这是阶段 1 的内容。
- 没有在目标机逐项回归菜单功能（预览、窗口搬移、热键）。
- 单元测试改用 swift-testing 后本机可跑；真机操作项仍需手工。

## 补丁记录（2026-10-07 晚，评审后）

评审指出三项问题，均已在本仓修正：

| 问题 | 修正 | 验证 |
| --- | --- | --- |
| 产品 CLI 可能借用运行中 2ndscreen.app 的 runtime（引擎 `TaskRuntime.locate` 按旧 bundle id 兜底） | 引擎二进制移到 `libexec/`；`bin/2ndscreen` 与 `bin/agentdesktop` 是同一个入口脚本，固定 `SECONDSCREEN_TASK_RUNTIME` 为产品包内路径；MCP 子进程继承同一环境 | 在本机给 2ndscreen.app 测试副本临时挂上 `build/task-runtime` 并运行后：`bin/agentdesktop task status`、`bin/2ndscreen task status`、MCP `task_status` 均返回 `capability_missing` 且消息指向产品路径；裸 `libexec/2ndscreen` 则借用了旧 runtime（返回 `not_found`），所以它不是受支持入口。CI 固定检查入口在无 runtime 时拒绝 |
| 依赖改动检查只看工作区 | `scripts/check-engine-checkout.sh` 在编译前核对提交并用 `git status --porcelain --untracked-files=all` | `scripts/test-check-engine-checkout.sh` 六个用例：干净、工作区改动、暂存改动、未跟踪文件、新目录内未跟踪文件、另一提交；CI 运行 |
| `build.json` 的哈希是签名前的，与包内文件不符 | 字段改名为 `inputs` 并注明语义；签名后在包外生成 zip 归档与分发清单，含每个文件和归档的 SHA-256 以及符号链接 | `scripts/verify-archive.sh` 解包后逐文件比对；CI 运行并上传归档与清单 |

截图、放置内容、窗口交还与搬回均已在目标机通过（见出口条件表）。阶段 0 出口条件全部满足，阶段 0 关闭。

未在本记录内的项：菜单里的 Show Preview 和 ⌃⌥⌘M 热键需要用户在自己屏幕上操作，不由执行 agent 代做；单实例检查仍非原子（C02）。
