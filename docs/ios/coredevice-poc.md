# iPhone CoreDevice 路线能力探测（W5 实验，I13）

> 状态：**实验，未接入产品**。本文只记录调研结论与一次只读探测的真实结果。I13 验收状态：**NOT_RUN**。
> 范围：评审报告《AgentDesktop iPhone Implementation Review 2026-10-08》第 5.2、5.3 节与测试矩阵 I13。
> 代码：`experiments/ios-coredevice/probe.py`（只读探测），结果 `experiments/ios-coredevice/results/probe-2026-10-08.json`。

## 1. 结论先行

- 这台 Mac（macOS 15.1，arm64，无 Xcode，有 Command Line Tools）上，pymobiledevice3 11.24.0 能装在隔离 venv 里运行；**本次没有发现任何 iPhone**：usbmuxd 可达但 0 台设备（USB / Wi-Fi 都没有），Apple 的 `remotepairingd` 应答但 0 台设备，tunneld 未运行，本机没有 pymobiledevice3 配对记录。
- 因此除宿主条件外，所有设备侧能力（iOS 版本、配对、开发者模式、DDI、隧道、截图、屏幕流、HID）都是 **unverified**，不是 supported。唯一给出确定结论的是从源码读出的限制：HID `type` 不能直接输入中文（`hid_type_direct_cjk = unsupported`）。
- iPhone Mirroring 的配对（Continuity）没有让该 iPhone 出现在 CoreDevice 的 `remotepairingd` 里；要走 CoreDevice 路线，至少需要 Kevin 做一次 USB 连接 + 信任（见第 6 节）。
- 源码层面的关键发现：pymobiledevice3 的触摸注入**依赖一个打开中的屏幕媒体流作为授权闸门**（见 3.3）。这正是 go-ios #835 版本分歧所在的那一步，所以“隧道能连上”与“触摸能生效”之间隔着一个必须单独实测的条件。

## 2. 本次探测结果原文摘要（2026-10-08 20:50 +08:00，PR #55 审查意见修复后重跑）

运行：`experiments/ios-coredevice/.venv/bin/python probe.py -o results/probe-2026-10-08.json`（默认模式：不发 mDNS、不借用 remoted 隧道）。

矩阵规则：

- **按设备出矩阵，不跨设备合并**：探测到的每台设备（usbmux 序列号 / remotepairingd / RSD 的 UDID，以及 RSD 打不开的 tunneld 隧道键）各有一张矩阵，放在 `capabilities_by_device`；顶层 `capabilities` 只是其中一个 UDID 的矩阵（`--udid` 指定；未指定时取唯一 / 第一台，并在 `target_selection` 写明）。lockdown 事实、tunneld 隧道、RSD 服务列表都按该 UDID 过滤，RSD 证据里带隧道接口名，便于按传输方式区分。tunneld 的映射键是它的 remote identifier，不保证等于硬件 UDID，所以探测逐条打开每个键下的每条隧道记录的 RSD（`rsd_services.result.entries[].tunnel_key` / `tunnel_index`，每个打开的 RSD 都会关闭，含失败和超时路径），按 RSD 报告的 UDID 把隧道归到设备上。某条隧道的 RSD 打不开时（上游 `get_tunneld_devices()` 会静默跳过它），失败原因记在 `failed_tunnels`；若这个键对不上任何已知 UDID，就以隧道键作为标识列入 `devices` 和 `tunneld_only_devices`，`tunnel_tunneld` 记为 unsupported 并保留隧道信息与 RSD 失败原因；自动选择 `capabilities` 时优先选有真实 UDID 的设备。
- **服务被公布 ≠ 操作可用**：RSD 服务是否被公布单独上报为 `service_advertised_*`；截图、屏幕流、HID、剪贴板这些操作探测脚本从不执行，所以无论服务是否被公布都保持 `unverified`，证据写 `NOT_RUN` 和公布情况。

| 项目 | 状态 | 证据 / 原因 |
|---|---|---|
| 宿主 | — | pymobiledevice3 11.24.0，Python 3.14.7，macOS 15.1，非 root，无 Xcode（无 devicectl），有 CLT |
| 设备 | — | `devices: []`，`target_udid: null`（no device seen），`capabilities_by_device: {}` |
| discovery_usbmux_usb | unverified | usbmuxd 可达，0 台 USB 设备 |
| discovery_usbmux_network | unverified | usbmuxd 未列出任何 Wi-Fi 设备（需要先 USB 配对再开 Wi-Fi 连接） |
| discovery_remotepairingd | unverified | remotepairingd 应答，0 台设备 |
| discovery_bonjour | unverified | NOT_RUN：mDNS 可能触发终端的“本地网络”授权弹窗，默认不跑（办公室 Wi-Fi 也已知屏蔽 mDNS） |
| ios_version / pairing | unverified | 没有可达设备 |
| developer_mode / ddi_mounted | unverified | 需要已配对且可达的设备 |
| tunnel_tunneld | unverified | 127.0.0.1:49151 未运行（只检测；启动需要 sudo） |
| tunnel_userspace_no_root | unverified | `pmd_pytcp 0.3.7` 可导入，但未建隧道（需已配对的 iOS 17.4+ 设备，且建隧道会自动配对、在手机上弹“信任”） |
| tunnel_native_remoted | unverified | remotepairingd 中无设备 |
| service_advertised_screencapture / _dvt / _displayservice / _hid_universal / _hid_indigo / _pasteboard | unverified | 没有该设备的 RSD 服务列表（没有通往设备的隧道） |
| screenshot_coredevice / screenshot_dvt / screen_stream_displayservice / hid_universal_tap_drag / hid_indigo_buttons / pasteboard_service | unverified | NOT_RUN：只读探测从不执行这些操作；即使服务被公布也保持 unverified |
| hid_type_ascii | unverified | 从未执行 |
| hid_type_direct_cjk | **unsupported** | 源码 `ASCII_TO_HID` 只覆盖可打印 US-ASCII，`type` 遇到其他字符直接报错 |
| text_chinese | unverified | 候选路径（拼音 IME / 剪贴板 + 粘贴 / WDA）均未执行 |
| hid_input_exercised | unverified | NOT_RUN：探测脚本按设计不发送 HID |

汇总：unverified 26，unsupported 1，supported 0。`i13_acceptance: NOT_RUN`。

探测的副作用核对：未创建 `~/.pymobiledevice3`，未写钥匙串，未调用 `xcrun`（无 Xcode 时可能弹安装对话框），未启动 iPhone Mirroring / Agent Desktop 实例，未出现任何系统授权弹窗。

## 3. pymobiledevice3 当前版本中的 CoreDevice 命令语义

以下依据 pymobiledevice3 **11.24.0** 的已安装源码（`pymobiledevice3/cli/developer/core_device.py`、`remote/core_device/hid_service.py`、`display_service.py`、`screen_capture_service.py`、`cli/cli_common.py`、`doctor.py`）以及官方文档。命令前缀均为 `pymobiledevice3 developer core-device`。

### 3.1 共同前提

| 前提 | 说明 |
|---|---|
| iOS 17+ RSD 隧道 | `core-device` 命令都要求 RemoteServiceDiscovery（RSD）。不传参数时默认建立**用户态隧道**（纯 Python 网络栈 `pmd-pytcp`，**不需要 root**），要求 iOS 17.4+（有 CoreDeviceProxy）；iOS 17.0–17.3 在 macOS 上回退到 `--native`。 |
| 隧道来源 | `--userspace`（默认，无 root）、`--native`（macOS：借用 Apple `remoted` 的隧道，无 root、无 Xcode，但设备只保留一条 RSD 连接，会与 `remoted` 互相挤掉，见上游 #1994）、`--tunnel UDID`（连一个正在运行的 `tunneld`）、`--rsd HOST PORT`。`remote tunneld` / `remote start-tunnel` 的内核 utun 隧道需要 **sudo**。 |
| 配对 | 建隧道使用 `autopair=True`：未配对时会在手机上弹“信任此电脑”。 |
| Developer Mode | iOS 16+ 所有 developer 服务的前提；`amfi enable-developer-mode` 会让设备重启。 |
| DDI | HID / 显示 / 截图服务由开发者磁盘镜像里的守护进程（如 `dtuhidd`）提供。官方 recipes：iOS < 17 用 DeveloperDiskImage；17.0–26.x 用 PersonalizedDMG；27.0+ 走 cryptexd 的 Cryptex1 DDI。`mounter auto-mount` 会下载并挂载。 |
| 相机/麦克风冲突 | 前台 App 占用相机或麦克风时，`displayservice` 拒绝开始镜像流（CoreDevice 错误码 9022）。触摸依赖该流，因此这类场景下触摸也会失败——这正是 I13 要求覆盖的“相机与麦克风场景”。 |

### 3.2 截图

- `screen-capture screenshot OUT.png [--display-unique-id ID]`：`com.apple.coredevice.screencaptureservice`，feature `capturescreenshot`，设备目前只支持 PNG。
- `developer dvt screenshot OUT.png`：走 Instruments `dtservicehub`。
- 老的 lockdown 服务 `com.apple.mobile.screenshotr` 同样依赖 DDI。
- 截图是一次性请求，**返回值不含采集时间戳**；“截图年龄”需要由宿主在请求前后打点估计。

### 3.3 屏幕流

- `display get-media-support-info` / `get-media-stream-server-status`：只读查询。
- `display start-video-stream OUT.rtp --duration S`：把设备发来的 RTP/HEVC 原始包写入文件。
- `display serve-web` / `serve-vnc`：解包 HEVC（RFC 7798）后通过浏览器 WebCodecs 或 VNC 展示；无密码时任何能访问端口的人都能观看**并控制**设备，只应绑定 loopback 或设密码。
- 上游自己记录的已知问题（`remote/core_device/MOTION_TEAR_FINDINGS.md`）：剧烈运动画面下会出现拖影，而 Xcode Device Hub 同一设备不出现；原因定位在 Apple 自家解码进程一侧，尚未解决。帧率/码率数字未经本项目复现，不引用。

### 3.4 HID（与评审报告提醒的陷阱逐条对应）

服务：`com.apple.coredevice.hid.universalhidservice`（触摸、虚拟键盘）与 `com.apple.coredevice.hid.indigo`（硬件按键）。

| 命令 | 准确语义 |
|---|---|
| `universal-hid-service tap X Y` | 向 mainTouchscreen（`_ServiceID 257`）发一次 CONTACT + 50 ms 后 RELEASE。坐标是 0..65535 的**归一化值**，与像素分辨率无关。 |
| `universal-hid-service drag X1 Y1 X2 Y2 [--steps 30 --duration 0.6]` | **接触式**划动：一串 CONTACT 报告推进坐标，最后一个 RELEASE。滚动列表、翻页、边缘手势都应映射到 `drag`。 |
| `universal-hid-service swipe ...` | **无接触的指针移动**（gesture 面板 `_ServiceID 1281`，19 字节报告），只移动镜像里的光标，**不是**手指划动。不要把它当 swipe 手势用。 |
| `universal-hid-service session` | 在**一个**媒体流内批量执行 `tap/drag/swipe/move/sleep`，避免每个动作都重开流。 |
| `universal-hid-service type TEXT` | 注册一个宿主侧虚拟 HID 键盘，再逐字符发键位报告；只接受可打印 US-ASCII（按 US 布局映射），其他字符报 `unsupported character`。中文 / emoji 不能直接输入。 |
| `hid button home|power|volume-up ... press` | Indigo 按键事件。 |
| `universal-hid-service list-connected` | 只读枚举设备侧已注册的 HID 面板。 |
| `copy` / `paste` | `pasteboardservice` 写 / 读设备剪贴板（UTF-8）。这是中文输入的候选路径之一，但写剪贴板之后如何触发粘贴（虚拟键盘 Cmd-V 或长按菜单）未验证。 |

**授权闸门（最关键）**：`hid_service.py` 的注释写明，没有活动的媒体流时，`dtuhidd` 把宿主注册的 HID 面板标记为 `authenticated: NO; eventSource: externalAccessory`，`backboardd` 静默丢弃所有触摸事件；只有在 `displayservice` 的媒体流（`start_video_stream`）打开期间，事件才会作为真实触摸送到 UIKit。所以 `tap/drag/type` 都会先自动开一路屏幕流（`touch_session`），并且有 10 秒超时。推论：

1. 发送 HID 报告的 RemoteXPC 调用返回成功，**不代表**触摸生效；必须用画面变化确认。
2. 凡是会让媒体流起不来的条件（版本门槛、相机/麦克风占用、守护进程卡死）都会让输入一起失效。
3. 观察（流）与输入（HID）天然是同一个后端会话，这与评审 5.3 节“一个 backend 自己负责观察与输入，不混用 Mirroring 画面 + 其他通道输入”的要求一致。

## 4. go-ios #835 的版本分歧

来源：[danielpaulus/go-ios PR #835](https://github.com/danielpaulus/go-ios/pull/835)（截至 2026-10-08 仍为 Open，未合并）。

- PR 内容：新增 `ios hid` 命令族，经 DDI 的 `dtuhidd` 用原始 HID 报告实现不依赖 WDA / XCUITest 的触摸，思路与 pymobiledevice3 相同。
- 作者实测：设备 iOS 26.5、DDI `27A5194q`。`startmediastream` 到达守护进程但被系统拒绝，错误 9021：“Remote control requires iOS 27.0 or later on this device.” 不经媒体流授权的原始 tap 没有任何可观察效果。作者结论：原生无代理触摸被 Apple 限制在 iOS 27.0+。
- 协作者 @shamanec 反驳：原始 HID 事件在 iOS 18、26.5、27 上都能工作（iOS 17 未测），但其实现未公开。

对本项目的含义：两种说法都没有被我们复现。注意 9021 的文案带有“on this device”，门槛可能与机型 / DDI 版本 / 传输方式有关，而不只与 iOS 主版本有关。因此 I13 必须按“**具体设备 + iOS 版本 + DDI 版本 + 传输（USB / Wi-Fi，userspace / native / tunneld）+ 服务路径**”逐组合记录，不能从 iOS 版本推断。Kevin 的 iPhone 15 的 iOS 版本本次无法读取，需第 6 节第 1 步之后由探测脚本补上。

## 5. MirrorUE 可借鉴之处

来源：[KamilBourouiba/MirrorUE](https://github.com/KamilBourouiba/MirrorUE)（只读 README；其版本要求与性能数字均未经本项目验证，不作为依据）。

- **采集与控制分层**：README 中的模块为 `MediaKit/`（CoreMediaIO 采集）、`DeviceKit/`（usbmux 发现、CoreDevice 桥接）、`ControlKit/`（HID client、键盘转换）、`MirrorUEApp/`（AppKit 窗口、Metal 视图）。画面走 “USB → CoreMediaIO（iPhone 屏幕 DAL 设备）→ Metal（IOSurface 零拷贝）”；控制走 “Wi-Fi / 网络 → CoreDevice 隧道 → UniversalHID（触摸、按键、键盘）”。
- **值得借鉴**：
  1. 采集与输入是两个可独立替换的模块，接口落在“帧”和“动作”上。对应评审第 6 节的 `AgentDesktopIOS/CoreDeviceBackend`，可拆成 `capture`（CoreMediaIO 或 displayservice 流）与 `control`（UniversalHID）两个子组件，由同一个设备会话持有。
  2. CoreMediaIO 采集是 macOS 公开框架（与 QuickTime 录屏同源），只要 USB 接线就能拿到画面，不依赖 DDI，适合与现有 Swift / ScreenCaptureKit / Metal 栈复用。
  3. README 注明 CoreMediaIO 采集会重新配置 USB，HID 因此改走网络 usbmux 对端——说明“USB 采集 + 网络控制”需要先 Wi-Fi 配对，也是一个要实测的组合。
- **需要警惕**：若画面来自 CoreMediaIO、输入走 UniversalHID，pymobiledevice3 记录的“输入需要 displayservice 媒体流开着”这一闸门依然存在，等于同时跑两路画面；这一点 MirrorUE README 没有说明，需要实测。它的本地 HTTP API（`127.0.0.1:8090`，`/v1/control/...`）只作为接口形态参考，不引入产品。

## 6. 需要 Kevin 授权 / 操作的步骤清单

按顺序执行，每一步之后重跑 `probe.py` 并保存 JSON。任何一步都可以在此停止。

| # | 步骤 | 谁来做 | 影响 |
|---|---|---|---|
| 1 | 用数据线把 iPhone 15 接到这台 Mac，解锁，在手机上点“信任此电脑” | Kevin | 新建 lockdown 配对记录（系统 `/var/db/lockdown`）。之后 probe 能读到 iOS 版本、配对、开发者模式、DDI 状态。 |
| 2 | （可选）是否允许 Wi-Fi 连接：`pymobiledevice3 lockdown wifi-connections on`，或 `remote pair` 做 CoreDevice 无线配对（手机上需确认） | Kevin 决定 | 手机会在局域网广播；办公室 Wi-Fi 屏蔽 mDNS，可能无法发现 |
| 3 | 是否允许 probe 发 mDNS（`--allow-mdns`） | Kevin 决定 | 可能弹 macOS“本地网络”授权，由 Kevin 自己点 |
| 4 | 开启开发者模式：手机 设置 → 隐私与安全性 → 开发者模式 | Kevin | 手机重启，需解锁确认；有安全含义 |
| 5 | 挂载 DDI：`pymobiledevice3 mounter auto-mount` | Kevin 授权后执行 | 从 Apple 下载个人化镜像并挂载到手机（重启后失效） |
| 6 | 建立隧道，任选其一：(a) 无 root 用户态隧道，probe 内由命令自动建立；(b) `--allow-native-tunnel`（借 remoted，无 root）；(c) Kevin 在自己的终端运行 `sudo experiments/ios-coredevice/.venv/bin/pymobiledevice3 remote tunneld` | Kevin 授权；(c) 必须 Kevin 本人执行 | (c) 需要管理员密码；我们不运行 sudo |
| 7 | 只读服务验证：RSD 服务列表、`display get-media-support-info`、`universal-hid-service list-connected` | 授权后执行 | 只读 |
| 8 | 截图 1 张 / 开 5 秒屏幕流 | Kevin 授权 | 会读取手机屏幕内容；Kevin 先把手机切到无隐私的界面 |
| 9 | 是否允许在手机上做**无害 HID 测试**：在 Kevin 指定的空白界面（如备忘录新建页）做 1 次 tap、1 次 drag、`type "abc"`；不在主屏幕划动（历史上曾把图标拖进文件夹） | Kevin 明确同意 + 手机解锁并放在指定界面 | 真实输入到手机 |

## 7. 与 WDA 基线对比用的统一指标

CoreDevice 与 WDA（以及现有 Mirroring 后端）使用同一组用例、同一台手机、同一界面、固定样本量，并报告 p50 / p95：

| 指标 | 定义 | 采集方法 |
|---|---|---|
| 输入回执延时 | 发起动作 → 后端返回“已投递” | 宿主单调时钟打点；回执里带 `deliveredAt` |
| 画面变化时间 | 发起动作 → 首帧可见变化 | 连续帧/截图比对目标区域像素差，阈值固定；回执“已投递”不等于成功 |
| 截图年龄 | 截图返回时刻 − 画面实际采集时刻 | 无时间戳的服务用“请求前后中点”估计并标注；流式取帧用帧时间戳 |
| 中文能力 | 中文、英文、emoji、多行分别能否正确落字 | 逐类公布；HID `type` 已知只支持 ASCII，需测剪贴板 / IME 路径 |
| 手势能力 | tap、long press、drag（列表滚动、翻页、边缘返回）、按键（Home/音量） | 以画面变化确认；`swipe` 不计入接触手势 |
| 附加记录 | 设备型号、iOS、DDI 版本、传输方式、pymobiledevice3 版本、相机/麦克风占用时的行为、资源占用 | 每次运行写入结果 JSON |

## 8. I13 验收步骤（状态：NOT_RUN）

前置：第 6 节第 1、4、5、6 步完成，第 9 步获得书面同意。

1. 运行 `probe.py`，记录组合：设备型号 / iOS / DDI 版本 / 传输（USB+userspace、USB+native、USB+tunneld，若授权则 Wi-Fi）/ pymobiledevice3 版本。
2. 对每个组合：读 RSD 服务列表，确认 `screencaptureservice`、`displayservice`、`hid.universalhidservice`、`hid.indigo` 是否存在（对应 `service_advertised_*`；这只是前提，不是操作可用的证据）。
3. 截图 1 张，记录截图年龄。
4. 开屏幕流 5 秒，记录是否成功；若失败，原样记录错误码（特别是 9021 / 9022）。
5. 在 Kevin 指定界面：tap 1 次、drag 1 次、`type "abc"` 1 次，每次以前后截图的画面变化判定成功，**不以 RPC 返回成功判定**。
6. 相机 / 麦克风场景：Kevin 在手机前台打开相机后重复第 4、5 步，预期记录 9022 或等价拒绝。
7. 中文：测试“剪贴板写入 + 粘贴”路径，记录是否落字与是否有系统粘贴许可弹窗。
8. 每一项写 supported / unsupported / unverified + 证据；任何组合都不得从“隧道已连上”推断输入可用。

验收通过标准：上述每个组合都有完整记录（成功或明确的限制），且第 7 节指标至少各有 10 次样本。当前状态：**NOT_RUN**。

## 9. 来源

- pymobiledevice3 仓库：<https://github.com/doronz88/pymobiledevice3>（本文以 PyPI 11.24.0 已安装源码为准）
- pymobiledevice3 CLI recipes：<https://doronz88.github.io/pymobiledevice3/guides/cli-recipes/>
- pymobiledevice3 developer CLI 参考：<https://doronz88.github.io/pymobiledevice3/cli/developer/>
- go-ios PR #835：<https://github.com/danielpaulus/go-ios/pull/835>
- MirrorUE：<https://github.com/KamilBourouiba/MirrorUE>
- Apple WWDC26 “Get the most out of Device Hub”（评审报告所引，作为官方能力参照）：<https://developer.apple.com/videos/play/wwdc2026/260/>
