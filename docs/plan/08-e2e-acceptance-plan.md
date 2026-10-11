# 8 端到端验收计划

## 8.1 通过规则

- 只有执行过的断言、命令退出码和带证据的真机记录算通过。编译成功、样例数据、网页原型通过都不算。
- 结果分四类：passed、failed、blocked_environment、not_run。缺环境记 blocked，不记 pass。
- 零容忍计数（任何一项非零即不通过）：越权输入、同请求重复输入、unknown 自动重发、静止后迟到输入、跨 client 泄漏、误杀独立 App、执行入口不一致导致的误点。
- 真机验收在 `/tmp/adt-*` 测试副本里做，不碰用户屏幕与登录钥匙串；需要用户在宿主操作的用例（M0 正式组合）提前约时间。

## 8.2 测试入口

`scripts/verify --suite <name> --out <dir>`（A1 建立），每个 suite 输出 summary.json（用例、结果、退出码、证据路径）。

| suite | 内容 | 环境 |
| --- | --- | --- |
| contract | CT 用例，Swift 与 C# golden | macOS CI、Windows CI |
| runtime | RT、ADR 用例 | macOS CI |
| hub | HB 用例，中性 Python 客户端 | macOS CI |
| explorer | GX 用例，脚本化模型桩 | macOS CI |
| sdk | SDK 用例 | macOS CI |
| ui | UC 与 HB-UI 用例（离屏渲染 + 交互断言） | macOS CI |
| macos-e2e | E2E 场景（8.4），真实测试副本与真实应用 | 目标 Mac |
| windows-contract | Windows 契约一致性 | Windows CI |

## 8.3 用例清单

| 编号 | 用例 | 预期 |
| --- | --- | --- |
| CT-01 | 合法与非法信封各一组 fixture | 合法通过，非法按指定错误码拒绝 |
| CT-02 | ai/1 旧信封 | 不被解码 |
| CT-03 | 方法重复注册 | 启动与测试失败 |
| CT-04 | Swift 与 C# 对同一 golden 编码 | 规范化 JSON 逐字节一致 |
| CT-05 | requestId 同义重放 | 返回原回执，动作 0 次新增 |
| CT-06 | requestId 异义 | idempotency_conflict，动作 0 |
| CT-07 | 10 个并发相同 requestId 的 run.start | 只有一个 Run |
| CT-08 | 错误不含密钥、键入正文、参数值 | 扫描通过 |
| RT-01 | 宿主端点 | 只有一个 runtime endpoint |
| RT-02 | 所有 ai.* 方法经 runtime/1 | 结果与迁移前一致 |
| RT-03 | 两个 Desktop 并发动作、同一 Desktop 连续动作 | 跨 Desktop 时间重叠；同 Desktop 严格有序 |
| RT-04 | 观察后销毁相邻 Desktop，再按旧观察点击 | target_moved，dispatch=0（M0 预演复现） |
| RT-05 | 观察早于动作派发栅栏 | 不能作为该动作的成功证据 |
| RT-06 | 在每个 await 边界取消 | 未派发动作为 not_sent，不误报成功 |
| RT-07 | 已派发但回执丢失 | delivery=unknown；静止后释放租约；自动重发 0 |
| RT-08 | 审计写失败 | audit_unavailable，不再接受新输入 |
| RT-09 | 停止时有在途动作 | 先 stopping/pending，在途结束后 ended/confirmed |
| RT-10 | 模型请求进行中取消 | 迟到建议丢弃，dispatch=0 |
| RT-11 | 后端不支持后台拖动 | unsupported_backend，不抢前台 |
| RT-12 | 输入到回执唯一 | 每次投递一个动作 ID 一个终态 |
| RT-13 | desktop.stop A | A ended，B 动作继续有回执 |
| RT-14 | takeover 时外部 Agent 继续发动作 | 被拒；Desktop.control=manual |
| RT-15 | handback | 重新观察；旧队列不重放；等新连接 |
| RT-16 | closePlan 与 destroy | 只结束本 Desktop 启动的进程，宿主共享应用存活 |
| RT-17 | desktop.create 带 launch | creating → ready；失败保留错误 |
| RT-18 | request.list 筛选与分页、export | 内容与 request.show 一致；导出 JSON 可读 |
| RT-19 | run.reconcile | 只追加；原 outcome 仍为 unknown |
| RT-20 | events.subscribe 游标重连 | 不丢不重；过期返回 events_cursor_expired |
| RT-21 | hover、drag、press | press 有回执；macOS 上 hover 与 drag 在派发前返回 `unsupported_backend`（`background_hover_activates` / `background_drag_unsupported`），dispatch=0，不以按键事件或前台方式代替（#263 选 B；drag 另行设计） |
| RT-22 | businessResult | 所有回执为 not_evaluated |
| RT-23A | 请求超时语义：大型网页（Safari 中立表单）上 observe | 在规定时间内返回成功、降级结果（元素标 partial）或明确错误；不挂起（MAC-001） |
| RT-23B | 故障隔离与恢复：同一 Desktop 连续制造 20 次 AX 超时 | 期间其他 Desktop 的 observe 与 act、`runtime.status`、该 Desktop 的纯截图都在各自 deadline 内完成；后台 AX 遍历线程数与内存有上限且超时停止后回落；主线程采样无 AX 调用 |
| RT-24 | 观察与输入同一目标：同一 Desktop 上让另一窗口盖住绑定窗口（MAC-001 的 Safari 叠窗） | observe 的截图、元素、坐标都来自绑定窗口，或返回遮挡错误；act 不向与截图不同的窗口投递，dispatch=0；GUI 运行不会出现「回执 confirmed、目标无变化」 |
| SEC-01 | 干净实例上的文件权限 | 新建实例后 `ai.sqlite`、`runs.sqlite`、`requests.sqlite`、socket 均 0600，目录 0700（不只检查已有文件） |
| SEC-02 | 凭据存放 | 数据库只含凭据引用；明文密钥只在系统安全存储；导出与日志无密钥 |
| SEC-03 | 测试副本隔离 | 测试副本的配置、数据库、socket、凭据与产品实例互不覆盖；测试副本用文件凭据，不读写登录钥匙串 |
| SEC-04 | 其他本机用户 | 以另一用户身份无法读取配置库、账本与 socket |
| SEC-05 | 产品与测试副本同时运行 | 两者各自正常；关闭其一不影响另一个 |
| HB-01 | 未配对调用 act | pairing_required |
| HB-02 | 配对：短码、一次确认、只授所请求 | 签发 clientId；未请求的能力不能勾选 |
| HB-03 | 配对窗口过期 | 请求被拒 |
| HB-04 | 用 A 的凭据在另一连接冒充 | 认证失败 |
| HB-05 | 撤销授权时有活跃 Run | 后续动作 grant_missing；Run 进入停止；App 不被结束（HUB-B01） |
| HB-06 | disable 客户端时有活跃动作 | 执行登记保留到静止（HUB-B02） |
| HB-07 | unknown 跨 Run、重连、重启 | 持久化，不自动重放（HUB-B03） |
| HB-08 | 意图先落盘 | 在 session.act 前写入；崩溃窗口恢复为 unknown（HUB-B04） |
| HB-09 | 外部 task id 冒充 runId 取消 | not_found；平台 stop 不被业务 cancel 冒充（HUB-B05） |
| HB-10 | 等待审批时客户端退出 | 挂起请求失效，不挂死（HUB-B06） |
| HB-11 | 心跳超时 | heartbeat_stale 暂停新输入 |
| HB-12 | client A 读 client B 的 Run、截图、用量 | not_found |
| HB-13 | 授权收窄到另一 Desktop | 原 Desktop 的下一个动作被拒 |
| HB-14 | 移除登记 | 软删除；账本保留 |
| ADR-01…ADR-10 | ADR v2.2 第五节 | 按 ADR 预期；ADR-02、ADR-07 的界面部分在 U3、U5 |
| GX-01 | 一次 GUI 运行 | 建议、回执、新观察、三值验证同一时间线 |
| GX-02 | 推理尝试 | AiService 只记一次，Explorer 只引用 |
| GX-03 | 模型 finish 但新观察未达标 | 不判成功 |
| GX-04 | 非法动作脚本 | 解析拒绝，dispatch=0 |
| GX-05 | 必需图像被剥离 | 明确失败，dispatch=0 |
| GX-06 | 回退模型协议不兼容 | capability_mismatch |
| GX-07 | 回退模型同协议且首个 503 | 预算内切换，动作至多一次 |
| GX-08 | 改默认 GUI 配置时 A 在运行 | A 用旧 revision，新 Run 用新 revision |
| GX-09 | 关闭 Explorer 页面 | Durable Run 继续（ADR-06） |
| GX-10 | 外部 Agent 发起 unit.run | Delegated Run，断连按 ADR 停止 |
| GX-11 | RunRecorder 写失败 | audit_unavailable |
| GX-12 | 两个 Desktop 同时运行 GUI 单元 | 历史与预算各自独立；A 取消 B 继续 |
| GX-13…GX-16 | 三值谓词：完整、不完整观察、歧义控件、动态文字 | inconclusive 不当成功；歧义 dispatch=0 |
| GX-17…GX-20 | 进展检测：重复状态、A-B-A 小环、长期无进展、预算统一计数 | 有界结束并说明原因 |
| GX-21 | 同一 `unit.run` 在不同主体下的所有权 | 主窗口进程内发起 → platform / platform_durable；本机 owner 的线连接、配对 App 发起 → external_client / connection_scoped；任何主体在参数里带 `origin=gui_explorer`、`lifetime=platform_durable` 或 `ownership=platform` → ownership_escalation_denied 且不建 Run |
| SDK-01…SDK-06 | Python 与 TS SDK：配对、动作、断开、重连、撤权、MCP `--desktop-id` 限定 | 与 CLI 结果一致；越界 Desktop 被拒 |
| UC01…UC54 | 设计源码包 54 项交互检查（原生重做） | 见 06 文件 6.4 |
| HB-UI-01…08 | Hub 页面：登记、连接、授权分列；离线缓存禁变更；不回退样例；撤权提示；停止两步；核实只追加；诊断导出无密钥 | Hub v1 第 3.3 节 |

## 8.4 跨模块端到端场景（macos-e2e）

每个场景记录：提交、OS、后端、目标应用版本、模型与 profile 版本、runId、requests/attempts/actions/verification 关联、连续录屏、结果 JSON。

| 编号 | 场景 | 步骤 | 通过标准 |
| --- | --- | --- | --- |
| E2E-01 | 独立使用 | 不装任何外部 Agent、不配模型：创建 Desktop、启动计算器、CLI 观察与动作、停止、关闭 | 全程可用；无模型提示不阻断 |
| E2E-02 | 授权与执行 | 中性 Python 客户端配对，授权 Desktop A，执行 10 个动作 | 每个动作一个回执；越权 0 |
| E2E-03 | 取消 | 动作进行中用户在 UI 点停止 | 停止中 → 已停止；之后 dispatch=0 |
| E2E-04 | 连接中断 | 动作进行中 `kill -9` 客户端 | Run ended(owner_lost)；在途动作有终态或 unknown；App 不被平台结束 |
| E2E-05 | 重连 | 客户端重启后重连 | clientId 不变、connectionId 变；旧 Run 不恢复；新 Run 正常 |
| E2E-06 | 撤权 | 运行中在 Agents 页撤销授权 | 下一个动作被拒；Run 停止；客户端仍在线 |
| E2E-07 | 宿主进程重启 | Durable GUI 运行中 `kill -9` 宿主再启动 | 账本恢复；不能证明安全的动作为 unknown；不重做 |
| E2E-08 | unknown 恢复 | 制造回执丢失 → 静止 → 核实为已执行 | 原 outcome 保持 unknown；核实记录可见；新动作需新 requestId |
| E2E-09 | 双 Desktop 并发与宿主可用 | A：外部客户端驱动；B：Explorer 运行；用户同时在宿主编辑器打字 | 时间轴三路重叠；宿主输入完整；焦点、修饰键、剪贴板未被污染 |
| E2E-10 | 全局停止 | 两类 Run 同时运行时点「停止所有输入」 | 全部关准入，逐项回执；enableInput 后旧 Run 不恢复 |
| E2E-11 | 接管与交还 | 外部 Agent 运行中用户接管，点几下，交还 | 接管前 stopping；交还后重新观察；旧队列不重放 |
| E2E-12 | UI 重载 | Explorer 运行中关闭主窗口再打开 | 同一 runId、历史与进度 |
| E2E-13 | 正式 M0 组合 | Desktop A：BOSS 原生客户端（BOSS App 经 SDK）；Desktop B：原生微信（第二个客户端）；用户在宿主打字 | 同 E2E-09，另记点击、中文输入、滚动、快捷键、菜单、弹窗逐项结果 |

## 8.5 发布门禁

在同一提交上：

1. contract、runtime、hub、explorer、sdk、ui 全部 passed；SEC-01…SEC-05 passed。
2. **M0 基础执行能力必须通过**：虚拟 Desktop 与宿主输入隔离。E2E-09（中立应用双 Desktop 并发、宿主同时打字）是首发必过项，没有豁免。
3. macos-e2e 的 E2E-01…E2E-12 passed。
4. E2E-13（正式 BOSS + 原生微信 + 宿主组合）单独安排正式验收。若因环境或外部应用暂缓，只能记为 not_run 或 blocked_environment，并写明原因与限制范围，**不得标为 passed**；不能用 E2E-09 的通过代替 E2E-13，也不能用编译或模拟测试证明正式应用的隔离能力。
5. ADR-01…10 passed；07 文件中 P0 迁移项全部完成；零容忍计数全为 0。
