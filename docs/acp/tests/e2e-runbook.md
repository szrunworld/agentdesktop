# ACP 真机端到端手册（L2 真 Runtime / L3 真编辑器）

状态：2026-10-08，工作线 Q（第二轮：dev 入口已接通，见 tests/README 4.4；Zed 首帧采集见 §三.1）。本手册写给 A2、A4、A6 合入之后执行验收的人（Q 主导、协调者验收）。在那之前，这里的步骤只能做到「启动成功」与只读冒烟（ACP-L2-01～05），其余用例不能标为 PASSED（[README](README.md) §一）。

用例编号见 [cases.csv](cases.csv)；`automation` 列写着「手工（runbook §x）」的用例按本手册对应一节执行。

## 一、开始之前

| 条件 | 怎么确认 | 缺了怎么办 |
| --- | --- | --- |
| A2 单一端点已合入（f1） | 测试副本启动后 `lsof -U -a -p <宿主 pid>` 只有一个监听 socket | G0、ACP-T18-* 记 BLOCKED |
| A6 `unit.run` 已合入（40） | `agentdesktop runtime capabilities --endpoint "$AGENTDESKTOP_ENDPOINT" --json` 列出任务入口方法 | 所有「真实 Run」用例记 BLOCKED |
| A4 身份与授权已合入（f1） | 能以两个不同 clientId 连接 | ACP-T07-*、T15、ACP-31 记 BLOCKED |
| PR4 审批契约（f1） | capabilities 中出现审批方法 | T16 真实部分、T17、场景 C 记 BLOCKED |
| S 线 dev 入口可用 | `.build/debug/agentdesktop-acp-dev` 能完成 `initialize`（先跑 §五.1 的 L1 场景） | 先修 dev 入口 |
| CLI `acp` 子命令（f1） | 测试副本包里 `agentdesktop acp --help` 退出码 0 | 用 dev 入口代替；ACP-P4-01 记 BLOCKED |
| Zed 1.23.2 | `zed --version`（已于 2026-10-08 由 Homebrew 安装在 /Applications/Zed.app，CLI 在 /opt/homebrew/bin/zed） | — |
| 屏幕录制与辅助功能授权 | 测试副本 `agentdesktop doctor --endpoint …` | 让 Kevin 在系统设置里授权；不要自己点系统弹窗 |

工作目录一律 `/tmp/adt-acp`。**不使用产品 endpoint**（`~/Library/Application Support/AgentDesktop/…`），不写登录钥匙串：测试副本需要凭据时用文件凭据（docs/plan/08 SEC-03）；一旦出现钥匙串密码框，立即停止并记录。

## 二、测试副本

```sh
cd ~/orca/agentdesktop               # 被测提交；记下 git rev-parse HEAD
scripts/bundle-app.sh                # 产物 build/Agent Desktop.app
rm -rf /tmp/adt-acp && mkdir -m 700 /tmp/adt-acp
cp -R "build/Agent Desktop.app" /tmp/adt-acp/
open -n --env AGENTDESKTOP_SOCKET=/tmp/adt-acp/side.sock "/tmp/adt-acp/Agent Desktop.app"
export AGENTDESKTOP_ENDPOINT=/tmp/adt-acp/side.runtime.sock
CLI="/tmp/adt-acp/Agent Desktop.app/Contents/Resources/bin/agentdesktop"
"$CLI" runtime status --endpoint "$AGENTDESKTOP_ENDPOINT" --json
```

- 测试副本的 Runtime 端点是 `<socket>.runtime.sock`（`HostRole.runtimeEndpoint`）。A2 之后端点会改名（04-gap-analysis C-19），以 `lsof -U -a -p $(pgrep -f "/tmp/adt-acp/Agent Desktop.app")` 列出的那一个为准，并同步修改 `scripts/acp/fake-editor/profiles/agentdesktop-*.json` 的 `AGENTDESKTOP_ENDPOINT`。按监听进程判断，不按文件名。
- 记录：宿主 pid、监听 socket 列表、文件权限（`ls -la /tmp/adt-acp`；socket 与数据库应为 0600、目录 0700）。
- 收尾（每轮结束都做）：关闭会话、销毁测试 Desktop、退出计算器、`kill -TERM <宿主 pid>`、`rm -rf /tmp/adt-acp`。

## 三、Zed 配置（L3）

Zed 1.23.2 支持自定义 ACP agent（`agent_servers`，`"type": "custom"`）。在 Zed 的用户设置（`zed: open settings`，即 `~/.config/zed/settings.json`）里加一项，**测试结束后删除**。本线没有改动 Zed 的任何设置。

dev 入口（S 线合入后、CLI `acp` 之前）：

```json
{
  "agent_servers": {
    "AgentDesktop (test /tmp/adt-acp)": {
      "type": "custom",
      "command": "/Users/kevinshi/orca/agentdesktop/.build/debug/agentdesktop-acp-dev",
      "args": [],
      "env": { "AGENTDESKTOP_ENDPOINT": "/tmp/adt-acp/side.runtime.sock" }
    }
  }
}
```

发布形态（CLI `acp` 合入后，ACP-P4-01、ACP-T26-* 的最终一轮用它）：

```json
{
  "agent_servers": {
    "AgentDesktop (test /tmp/adt-acp)": {
      "type": "custom",
      "command": "/tmp/adt-acp/Agent Desktop.app/Contents/Resources/bin/agentdesktop",
      "args": ["acp"],
      "env": { "AGENTDESKTOP_ENDPOINT": "/tmp/adt-acp/side.runtime.sock" }
    }
  }
}
```

- `env` 必须显式写：Zed 启动 agent 时不会带上终端里的 `export`。
- 打开 Agent 面板 → 新建线程 → 选「AgentDesktop (test /tmp/adt-acp)」。
- ACP 日志：命令面板执行 `dev: open acp logs`，测试期间保持打开；导出前按 §八 检查脱敏。
- 录屏：`screencapture -v -C /tmp/adt-acp/evidence/<case>.mov`（或 QuickTime），录 Zed 窗口；测试 Desktop 的画面用 `observe --image-output` 取，不录用户主屏上的其他内容。

### 三.1 给 Kevin：采集 Zed 的真实 initialize 帧（约 5 分钟，ACP-T26-01 的首份证据）

只需要 Zed，不需要测试副本，不会产生任何 GUI 输入（用 dev 入口的 `--demo`）。

1. 在仓库根目录构建一次：`swift build --product agentdesktop-acp-dev`（看退出码为 0）。
2. Zed 命令面板 → `zed: open settings`，在顶层加入下面这一项并保存（路径按你的 checkout 改）：

   ```json
   "agent_servers": {
     "AgentDesktop dev (demo)": {
       "type": "custom",
       "command": "/Users/kevinshi/orca/agentdesktop/.build/debug/agentdesktop-acp-dev",
       "args": ["--demo"],
       "env": {}
     }
   }
   ```
3. 命令面板 → `dev: open acp logs`，保持这个窗口开着。
4. 打开 Agent 面板 → 「New Thread」→ 选「AgentDesktop dev (demo)」。
5. 线程打开后输入 `/help` 回车，再输入任意一句话（演示任务约 2 秒结束）。
6. 在 ACP 日志里找到第一条 `initialize` 请求（Zed → agent）与它的回复，以及 `session/new`，复制成文本存为 `zed-initialize-<日期>.txt`，交给 Q；有报错就截图。
7. 删除第 2 步加的设置项。

Q 收到后核对：Zed 请求的 `protocolVersion`、`clientCapabilities`（fs、terminal、elicitation 等）、是否在 initialize 回复前就发 `session/new`（流水线，见 ACP-T01-06），并把结果写进 ACP-T26-01 的证据和 02-protocol-version。此步只证明 Zed 能启动 dev 入口，不算 P1 验收。

## 四、P1 端到端：计算器中立样本（ACP-T26-*、ACP-P1-*）

计算器只是通用 GUI 能力的验收载体，**只出现在测试数据、本手册与测试 profile 里，不进入产品源码**（原文 §8）。样本任务由 A6 的任务目录或测试夹具登记为一个中立的「registered procedure」，例如「在一个新 Desktop 上启动计算器，依次按 7、+、8、=，读取显示值」。任务名与参数在 A6 合入后填进 `profiles/agentdesktop-*.json` 的 `PROMPT_*` 变量和下表。

步骤：

1. §二 起测试副本；记录 `"$CLI" run list --endpoint "$AGENTDESKTOP_ENDPOINT" --json > before.json`。
2. Zed 新建线程（ACP-T26-01）。确认线程打开、ACP 日志有 `initialize` 与 `session/new`。
3. 输入 `/`，确认命令列表只含已授权任务（ACP-T26-02、ACP-T15-01）。
4. 执行计算器样本（ACP-T26-03）。全程录屏。
5. 结束后 `run list --json > after.json`；`run show <runId> --json`；`run events <runId> --json`；对每个动作 `request show <requestId> --json`。
6. 用 `observe --session … --image-output result.png` 取测试 Desktop 截图，确认显示 15。
7. 以未授权身份重复第 4 步（ACP-T15-02，需 A4）。
8. 再跑一次，执行到一半时 `kill -9` ACP 进程（`pgrep -f agentdesktop-acp-dev`）（ACP-T03-05）。

### P1 通过标准（原文 §8，逐条可判定）

| # | 标准 | 用例 | 判定 |
| --- | --- | --- | --- |
| 1 | Zed 能启动 ACP Adapter | ACP-P1-01 ← ACP-T26-01 | Zed 线程打开无错误；ACP 日志有成功的 `initialize` 回复，协议版本属于 02 的支持集合 |
| 2 | 能发现至少一个已授权任务 | ACP-P1-02 ← ACP-T26-02、ACP-T15-01 | `available_commands_update` 至少一项；每一项都能在 Runtime 的任务目录里找到；没有未授权任务 |
| 3 | 可以发起实际 Runtime Run | ACP-P1-03 ← ACP-T09-01 | `after.json` 比 `before.json` 恰好多一条 Run；`origin=agent_hub`、`lifetime=connection_scoped`（以 A6 的最终字段名为准） |
| 4 | 能看到动作卡片和执行结果 | ACP-P1-04 ← ACP-T26-03 | 录屏中每个动作一张卡片；已受理 / 已执行 / 已验证分开显示，未验证的不显示为成功；result.png 显示 15；卡片里没有截图、窗口标题原文或输入原文 |
| 5 | 未授权任务不可执行 | ACP-P1-05 ← ACP-T15-02 | 拒绝可解释；该身份的 `request show` 无派发记录（dispatch 0） |
| 6 | 不产生第二套运行记录 | ACP-P1-06 ← ACP-T09-01、ACP-T09-03 | Run 只在 Runtime；`/tmp/adt-acp` 下 ACP 的文件只有会话绑定，不含 Run 状态；代码审查 G0-09 通过 |
| 7 | 关闭客户端后按 Run 类型处理生命周期 | ACP-P1-07 ← ACP-29-01、ACP-T14-03 | 见 §六 ACP-29 的判定 |
| 8 | stdio 中断不导致 GUI 执行器崩溃 | ACP-P1-08 ← ACP-T03-05 | kill 前后宿主 pid 不变；`runtime status` 正常；该 Run `ended`、`closingReason=owner_lost`；kill 之后 dispatch 0 |

八条全部 PASSED 且证据齐全，G1-11 才能标 PASSED。

## 五、L2 真 Runtime 用例

### 5.1 先跑 L1 场景

```sh
export AGENTDESKTOP_ENDPOINT=/tmp/adt-acp/side.runtime.sock
scripts/acp/run-real.sh agentdesktop-dev /tmp/adt-acp/evidence/fake-editor
```

脚本拒绝 `/tmp/adt-*` 以外的端点。profile 的 `features` 没打开的场景记 BLOCKED。结果 `summary.json` 与 transcript 是这些用例的证据。

### 5.2 手工用例

| 用例 | 做法 | 判定 |
| --- | --- | --- |
| ACP-T03-03 | `mkfifo` 接 dev 入口的 stdout，读几帧后关掉读端，再触发更新 | 进程不因 SIGPIPE 崩溃（退出信号不是 SIGPIPE/SIGSEGV/SIGABRT）；无 GUI 输入 |
| ACP-T03-05 | §四 第 8 步 | 见 P1 #8 |
| ACP-T03-06 | 对 Zed（或假编辑器）`kill -STOP`，让 ACP 写阻塞；等心跳超时 | Runtime 暂停新输入（HB-11）；`kill -CONT` 后不补发输入 |
| ACP-T06-05 | 发起 Run，断开，重连加载 | 会话绑定的 runIds 与 `run list` 一致 |
| ACP-T07-04 | 身份 B 用 A 的 runId 查看与取消 | not_found；A 的 Run 不变 |
| ACP-T08-02 | 两个 ACP 进程（两个假编辑器或两个 Zed 线程）同时跑样本 | 各自的事件只到各自会话；两个 Run 都正确结束 |
| ACP-T09-01 | §四 第 1、5 步 | 见 P1 #3 |
| ACP-T10-01、05 | 假编辑器同一 prompt 重发；另用 CLI 先占一个 requestId | 同一 runId；ACP 的 key 有自己的前缀，不与 CLI 撞 |
| ACP-T11-02 | 用 Runtime 的故障注入（RT-07 的做法）让一次已派发动作丢回执 | 动作 unknown，Zed 显示「待核实」；`request show` 无重发 |
| ACP-T12-04 | Zed 中点停止 | 先显示正在停止；`run show` 先 `stopping` 后 `ended`；之后 dispatch 0 |
| ACP-T14-03、04 | 执行中关闭 ACP 进程 | `run show`：`ended`、`closingReason=owner_lost`；在途动作为 confirmed 或 unknown，不是 failed |
| ACP-T15-01、02 | 受限身份连接 | 见 P1 #2、#5 |
| ACP-T16-05、07 | Zed 中 Deny；另以无该能力的身份 Allow | 都不执行；审计有记录 |
| ACP-T18-01 | `lsof -U -a -p <宿主 pid>` | 只有一个监听 socket；`/tmp/adt-acp` 下没有 `*.ai.sock` |
| ACP-T18-02 | `swift build --package-path engine` 编出旧引擎 CLI，指向 `/tmp/adt-acp/side.sock` 发点击 | 连接失败或被拒；测试 Desktop 截图无变化 |
| ACP-T18-03 | 向 `/tmp/adt-acp/side.ai.sock`（若存在）发 GUI 动作 | 不存在或被拒 |
| ACP-T18-04 | `agentdesktop mcp`（#29）发一次 act | Runtime 账本有该 requestId |
| ACP-T19-03 | 跑完全部用例后扫描 | `grep -rE 'iVBOR|/9j/' /tmp/adt-acp ~/Library/Logs/DiagnosticReports/*agentdesktop*` 无结果（只扫本轮产生的文件） |

## 六、P2 场景与新增场景

| 用例 | 步骤 | 通过标准 |
| --- | --- | --- |
| ACP-T13-01、02、ACP-P2A-01（K1 改写的场景 A） | 主窗口发起一个 Durable Run；按授权让 Zed 会话观察；关闭 Zed；等 2 分钟；重开 Zed 并加载该会话 | Run 一直在跑，runId 不变；Zed 只读（没有停止、批准、输入入口，或点了被拒）；重开后看到当前进度；事件回放不重复（transcript 中同一 Runtime 游标只出现一次） |
| ACP-P2A-02、ACP-T13-03 | 从 ACP 以参数、重连或内部字段要求 Durable | 全部拒绝；Run 为 connection_scoped |
| ACP-P2B-03（场景 B） | connection_scoped Run 执行中断开 ACP | 停止新输入；按 ADR v2.2 收尾；不能证实的结果为 unknown；重连不继续 |
| ACP-T17-01、ACP-P2C-01、02（场景 C） | 审批弹出后，用另一个窗口盖住目标（或退出目标、移到别的 Desktop），再点 Allow Once | Runtime 复核失败：`stale_observation`、`notSent`；测试 Desktop 截图无变化；Zed 显示可解释的拒绝且不含窗口标题原文 |
| ACP-P2D-01～03（场景 D） | 假编辑器 `permission=none` 跑 scene-d；Runtime 没有审批方法时再跑一次 | 动作不执行；拒绝可解释；绝不因客户端能力不足而批准 |
| ACP-29-01 | 计算器长样本执行到中途，Cmd-Q 退出 Zed | `run show`：`ended`、`closingReason=owner_lost`；退出时刻之后测试 Desktop 无新输入（`request` 记录的派发时间都早于退出时刻）；未确认的动作为 unknown，不是 failed |
| ACP-29-02 | 同上，改为 `kill -9 <Zed pid>` | 同上；ACP 进程随 stdin EOF 退出，没有孤儿进程 |
| ACP-29-03 | 在动作派发后立即退出 | 该动作 confirmed 或 unknown，不记 failed，不重发 |
| ACP-30-01、02 | ACP-29-01 之后重开 Zed 并加载会话；再发同一任务 | 历史与最终状态可读且与 `run show` 一致；不自动恢复旧 Run；新提交得到新 runId，旧 Run 仍为 ended |
| ACP-31-01～04 | CLI 或主窗口发起 Durable Run；ACP 以未授权身份按 sessionId、runId 请求观察；再授予观察权 | 授权前一律 not_found，不泄露任何字段；授权后只读、已脱敏，不能取消、批准、输入 |
| ACP-P209-01、02 | 计算器长样本循环 ≥30 分钟；其中一步等待 10 分钟 | Zed 持续显示或加载后看到最新状态；无错误生命周期；ACP 进程不因空闲退出 |

## 七、JetBrains（P2，不阻塞 P1）与分发

本机没有 JetBrains IDE。需要时由 Kevin 安装：

1. `brew install --cask intellij-idea-ce`（或用 JetBrains Toolbox 安装任一 2025.3 以后的 IDE），登录 JetBrains AI（需要 Kevin 的账号，Q 不代为登录）。
2. 按 JetBrains 当时的 ACP 文档添加自定义 agent（通常是 `~/.jetbrains/acp.json` 的 `agent_servers` 项），command / args / env 与 §三 相同。
3. 执行 ACP-T27-01、02：同 §四 第 4 步与 Deny。

ACP-P4-01（安装、卸载、重装）在干净的测试账户上做，需要 CLI `acp` 与正式包；ACP-P4-02 对照隐私说明与 `ACPPrivacyPolicy` 默认值（一致性测试已钉住默认值）。

## 八、证据与记录

每轮在 `/tmp/adt-acp/evidence/` 收集，结束后把**不含个人数据**的部分写进 `docs/acceptance/acp-<阶段>-<日期>.md`（沿用现有验收记录格式），并更新 `cases.csv` 的 `status` 与 `evidence` 列：

| 证据 | 来源 |
| --- | --- |
| 被测提交 SHA、构建命令与退出码 | `git rev-parse HEAD`；`scripts/bundle-app.sh`、`swift build` 的退出码（不经管道） |
| 假编辑器 `summary.json` 与 transcript | §五.1 |
| Zed 录屏与 ACP 日志 | §三 |
| Runtime 记录 | `run list/show/events`、`request show` 的 JSON |
| 测试 Desktop 截图 | `observe --image-output` |
| 进程与 socket | `lsof -U`、`pgrep`、宿主 pid 前后对比 |
| 脱敏检查 | 对 ACP 日志、stderr、`/tmp/adt-acp` 做 `grep`，用测试夹具里的敏感串与 `iVBOR`、`/9j/` |

记录前检查：录屏与日志里不能有 Kevin 的个人窗口、通知或账号信息；有就重录。

## 九、要 Kevin 做的事

- Zed：已安装（1.23.2），无需再装。验收那天允许在 Zed 设置里临时加入 §三 的 `agent_servers` 项（结束后删除），并在需要时授予测试副本屏幕录制与辅助功能权限。
- JetBrains（P2）：安装一个 JetBrains IDE 并登录 JetBrains AI，见 §七。P1 不需要。
- A4 之后需要两个测试身份（clientId）用于 ACP-T07、T15、ACP-31，由 Hub 的配对流程签发，验收时请 Kevin 在测试副本上确认配对。
