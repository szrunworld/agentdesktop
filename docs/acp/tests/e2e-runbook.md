# ACP 真机端到端手册（L2 真 Runtime / L3 真编辑器）

状态：2026-10-08，工作线 Q（第四轮：Zed 首帧采集改为 §三.1 的两条脚本）。本手册写给 A2、A4、A6 合入之后执行验收的人（Q 主导、协调者验收）。在那之前，这里的步骤只能做到「启动成功」与只读冒烟（ACP-L2-01～05），其余用例不能标为 PASSED（[README](README.md) §一）。

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

工作目录一律 `/tmp/adt-acp`。**不使用产品 endpoint**（`~/Library/Application Support/AgentDesktop/…`），不写登录钥匙串：测试副本的凭据放在临时钥匙串里（§三；A4 之后凭据不写文件）；一旦出现钥匙串密码框或授权框，立即停止并记录。

## 二、测试副本

```sh
cd ~/orca/agentdesktop               # 被测提交；记下 git rev-parse HEAD
scripts/bundle-app.sh                # 产物 build/Agent Desktop.app
rm -rf /tmp/adt-acp && mkdir -m 700 /tmp/adt-acp
cp -R "build/Agent Desktop.app" /tmp/adt-acp/
open -n --env AGENTDESKTOP_SOCKET=/tmp/adt-acp/side.sock --env AGENTDESKTOP_GUI_EXECUTION=1 "/tmp/adt-acp/Agent Desktop.app"
export AGENTDESKTOP_ENDPOINT=/tmp/adt-acp/side.runtime.sock
CLI="/tmp/adt-acp/Agent Desktop.app/Contents/Resources/bin/agentdesktop"
"$CLI" runtime status --endpoint "$AGENTDESKTOP_ENDPOINT" --json
```

- **`unit.run` 的前提（A6）**：
  - 测试副本要带 `AGENTDESKTOP_GUI_EXECUTION=1`（`HostRole.guiExecutionEnabled`），否则 Runtime 不宣告 `unit.run`，桥的任务列表为空。
  - 执行器在受理时会检查 GUI profile、它的模型和凭据，以及这个 GUI profile 是否已经和这一版模型 profile 一起通过 GUI 契约测试（`UnitRunService.admit`）。在测试副本的主窗口里配置好默认 GUI profile 和模型，填入 Kevin 提供的专用测试凭据（O1：存钥匙串或受控存储，不进 Git 和日志），再跑一次 `ai.tests.start` 并通过。缺任何一项，`unit.run` 都会在 Run 创建之前被拒绝。
- 测试副本的 Runtime 端点是 `<socket>.runtime.sock`（`HostRole.runtimeEndpoint`）。A2 之后端点会改名（04-gap-analysis C-19），以 `lsof -U -a -p $(pgrep -f "/tmp/adt-acp/Agent Desktop.app")` 列出的那一个为准，并同步修改 `scripts/acp/fake-editor/profiles/agentdesktop-*.json` 的 `AGENTDESKTOP_ENDPOINT`。按监听进程判断，不按文件名。
- 记录：宿主 pid、监听 socket 列表、文件权限（`ls -la /tmp/adt-acp`；socket 与数据库应为 0600、目录 0700）。
- 收尾（每轮结束都做）：关闭会话、销毁测试 Desktop、退出计算器、`kill -TERM <宿主 pid>`、`rm -rf /tmp/adt-acp`。

## 三、Zed 配置（L3）

Zed 1.23.2 支持自定义 ACP agent（`agent_servers`，`"type": "custom"`）。在 Zed 的用户设置（`zed: open settings`，即 `~/.config/zed/settings.json`）里加一项，**测试结束后删除**。本线没有改动 Zed 的任何设置。

**先配对（A4 之后必需，2026-10-10）。** A4（#137）合入后，Runtime 只对已配对的客户端提供服务。ACP 桥用钥匙串里 profile 为 `acp` 的凭据连接，没有凭据时只会得到 `pairing_required`：启动时 stderr 会提示 `not paired with …`，每次提交都是确定拒绝。

**ACP 桥自己配对**（`docs/security/a4-identity.md`：ACP 桥是外部 App，必须自己配对、自己保管凭据）。配对和服务必须是**同一个程序**：确认窗口显示的才是 ACP 桥本身的代码身份；钥匙串条目只信任创建它的程序，换一个程序读取会弹出钥匙串授权框（按 §一，出现就中止测试）。所以 dev 入口用 `agentdesktop-acp-dev pair`，不用 `agentdesktop agents pair`。

**先在主窗口准备 Desktop（#246）。** 桥不创建 Desktop、不启动 App、不绑定窗口，只能用你明确授予的 Desktop 和窗口。配对之前，由 Kevin 在测试副本的 Agent Desktop 主窗口里创建一个 Desktop，在上面启动计算器并绑定它的窗口，记下 Desktop id（例如 `desk_…`），下面记为 `$DESK`。

测试副本要用临时钥匙串，**不要写登录钥匙串**：

```sh
export AGENTDESKTOP_ENDPOINT=/tmp/adt-acp/side.runtime.sock
security create-keychain -p "$(uuidgen)" /tmp/adt-acp/test.keychain-db
security set-keychain-settings /tmp/adt-acp/test.keychain-db       # 测试期间不自动锁
# create-keychain 可能把它加进搜索列表；如果加了，按原样恢复（见 scripts/a4-touchid-acceptance.sh）
export AGENTDESKTOP_KEYCHAIN=/tmp/adt-acp/test.keychain-db
ACP_DEV="$(git rev-parse --show-toplevel)/.build/debug/agentdesktop-acp-dev"   # 在仓库里执行；echo "$ACP_DEV"，下面 Zed 配置的 command 填这个绝对路径
"$ACP_DEV" pair --endpoint "$AGENTDESKTOP_ENDPOINT" --desktops "$DESK" --name ACP --apps com.apple.calculator --duration 8h --wait-timeout 180
# 窗口授权（方案 A）：显式申请，Kevin 在确认窗口里核对是计算器那个窗口，再用 Touch ID 批准
"$ACP_DEV" request-window --endpoint "$AGENTDESKTOP_ENDPOINT" --desktop "$DESK" --bundle-id com.apple.calculator --duration 8h
```

- **配对申请的授权**：
  - 能力固定为 `observe,act,unit.run,run`。`unit.run` 用于提交任务；`run` 用于 `run.show`、`run.cancel` 和事件订阅；`observe`、`act` 也需要，因为 A6 的执行器以桥的身份执行，Run 里的每一次 observe 和 act 都按桥的授权检查（见 `RuntimeService+Auth.swift` 的 `capabilityOf` 和 `RuntimeService.swift` 的 `init(actingFor:)`）。不再申请 `desktop.manage`。
  - Desktop 范围由 `--desktops` 指定，**必填**，只接受具体 id，不接受 `created`：桥从不创建 Desktop，`created` 对它来说等于没有任何 Desktop。
  - App 范围由 `--apps` 指定，含义是「可以申请窗口授权的 App」：`hub.windows.request` 只接受授权里列出的 App 的窗口。没有 `desktop.manage`，桥不能用它启动 App，`apps` 本身也不授予任何窗口。期限用 `--duration`：不写时是 Runtime 默认的 1 小时，到期后每次提交都是 `grant_expired`；本手册有 ≥30 分钟的长样本（ACP-P209），整轮测试按 8 小时申请，最长 7 天。
- **窗口授权（`request-window`）**：
  - `unit.run` 要求桥对 Desktop 当前绑定的窗口持有 observe 和 act 的窗口授权（`RuntimeService+Unit.swift` 的 `windowUse`）。`request-window` 用桥自己的凭据，通过 `hub.windows.request` 只申请 `observe`、`act`，由 Kevin 在确认窗口里核对窗口（App、标题、pid、位置）后用 Touch ID 批准。
  - 申请之前，桥看不到 Desktop 上绑定的是哪个窗口（`desktop.show` 会隐去绑定），所以按 `--bundle-id` 申请；这个 App 有多个窗口时，用 `--window-id` 指定。批准之后命令会再调一次 `desktop.show` 核对：授予的不是绑定的那个窗口（或者 Desktop 上没有绑定窗口）时，明确报错退出（退出码 2）。这种授权 `unit.run` 用不了，在主窗口撤销即可。命令**不会**自动撤销，也不会重试。
  - 用户拒绝、App 不在 `--apps` 里、没有配对、授权已撤销，都会原样报出 Runtime 的错误，不重试。桥在提交任务的过程中**不会**自己申请窗口授权（裁决：不采用方案 B）。
- **任务列表与默认 profile**：Runtime 同时宣告 `unit.run` 和 `ai.profiles.list` 时，桥会先读 profile 列表。`ai.*` 只有 owner 能调，配对的桥会被拒（`permission_denied`；S4 之前的 `same_user` 级别为 `unverified_identity`）。遇到这两种确定拒绝，桥只提供一个 `unit.run` 任务，使用 Runtime 的默认 profile；其他错误照常报出，编辑器提示「暂时无法读取可用任务」。
- **配对之后不要重新编译 dev 入口。** 开发版是 ad-hoc 签名，钥匙串按程序的代码摘要识别它；重新编译后就成了「另一个程序」，读取凭据会弹授权框。重新编译过就删掉临时钥匙串，从建钥匙串那一步重来。

- 配对请求出现在测试副本的 Agent Desktop 窗口里，由 Kevin 本人核对后点「批准」并用 Touch ID 确认。自动化不能代替。
- 下面 Zed 配置的 `env` 里要同时带上 `AGENTDESKTOP_ENDPOINT` 和 `AGENTDESKTOP_KEYCHAIN`。
- 测试结束后执行 `security delete-keychain /tmp/adt-acp/test.keychain-db`。
- S4 之前，开发版 ACP 桥是 `same_user` 身份：能按授权使用 Desktop，但不能执行任何敏感管理操作（R1）。

dev 入口（S 线合入后、CLI `acp` 之前）：

```json
{
  "agent_servers": {
    "AgentDesktop (test /tmp/adt-acp)": {
      "type": "custom",
      "command": "<仓库绝对路径>/.build/debug/agentdesktop-acp-dev",
      "args": [],
      "env": { "AGENTDESKTOP_ENDPOINT": "/tmp/adt-acp/side.runtime.sock", "AGENTDESKTOP_KEYCHAIN": "/tmp/adt-acp/test.keychain-db" }
    }
  }
}
```

发布形态（**`agentdesktop acp` 子命令尚未实现**，按 R9 在 G1 之后接入；合入后 ACP-P4-01、ACP-T26-* 的最终一轮用它）。`agentdesktop acp` 与 `agentdesktop agents pair` 是同一个程序，所以发布形态用 CLI 配对：

```sh
"/tmp/adt-acp/Agent Desktop.app/Contents/Resources/bin/agentdesktop" agents pair --name ACP --profile acp \
  --capabilities observe,act,unit.run,run --desktops "$DESK" --apps com.apple.calculator --duration 8h --wait-timeout 180
```

发布形态的窗口授权同样要由这个程序自己申请；`agentdesktop acp` 接入时补上对应的命令，在那之前只走 dev 入口。

Zed 配置：

```json
{
  "agent_servers": {
    "AgentDesktop (test /tmp/adt-acp)": {
      "type": "custom",
      "command": "/tmp/adt-acp/Agent Desktop.app/Contents/Resources/bin/agentdesktop",
      "args": ["acp"],
      "env": { "AGENTDESKTOP_ENDPOINT": "/tmp/adt-acp/side.runtime.sock", "AGENTDESKTOP_KEYCHAIN": "/tmp/adt-acp/test.keychain-db" }
    }
  }
}
```

- `env` 必须显式写：Zed 启动 agent 时不会带上终端里的 `export`。
- 打开 Agent 面板 → 新建线程 → 选「AgentDesktop (test /tmp/adt-acp)」。
- ACP 日志：命令面板执行 `dev: open acp logs`，测试期间保持打开；导出前按 §八 检查脱敏。
- 录屏：`screencapture -v -C /tmp/adt-acp/evidence/<case>.mov`（或 QuickTime），录 Zed 窗口；测试 Desktop 的画面用 `observe --image-output` 取，不录用户主屏上的其他内容。

### 三.1 给 Kevin：采集 Zed 的真实 initialize 帧（约 2 分钟；Z1，协议验收的一部分）

用 dev 入口的 `--demo`：不需要测试副本，不会产生任何 GUI 输入，也不改你自己的 Zed 设置。`setup.sh` 用 `zed --user-data-dir` 打开一个独立的 Zed：Zed 1.23.2 会把数据目录和配置目录（`<dir>/config/settings.json`）一起换掉，所以 `~/.config/zed` 和 `~/Library/Application Support/Zed` 都不会被读写。每一帧都由 `scripts/acp/zed-capture/capture-agent.mjs` 原样转发，并逐字节记录到 `/tmp/adt-zed-capture-<时间>/`。

在仓库根目录（`~/orca/agentdesktop`，先 `git pull` 到含本节的提交）执行：

1. 先退出 Zed（Cmd-Q）。macOS 上同一用户只能运行一个 Zed，不管用哪个数据目录。
2. `scripts/acp/zed-capture/setup.sh`：构建 dev 入口，并打开独立的 Zed 窗口。
3. 在这个 Zed 窗口里打开 Agent 面板（Cmd-? 或 View → Agent Panel）→ New Thread（＋）→ 选「AgentDesktop (dev demo)」。
4. 输入 `/help` 回车，等回复出现。
5. 退出 Zed（Cmd-Q）。
6. `scripts/acp/zed-capture/collect.sh`：屏幕上会打印 Zed 请求和应答的协议版本、clientInfo，以及有没有在 initialize 回复前就发出请求。

`collect.sh` 只在 `/tmp/adt-zed-capture-<时间>/redacted/` 下生成脱敏副本，内容包括：

- `initialize.json`：真实的 initialize 请求与应答；
- `summary.json`：协议版本、clientInfo、clientCapabilities、方法顺序，以及原始字节的大小与 SHA-256；
- 每次启动的 `frames.redacted.jsonl`：带时间戳的逐帧记录；
- `zed-log-excerpt.redacted.txt`：Zed 日志中与 agent 相关的行。

脱敏会替换路径、用户名和主机名；有残留时命令失败、不产出证据。原始 `.bin` 留在 /tmp，不进仓库。

之后由协调者执行：

- `scripts/acp/zed-capture/collect.sh --to-evidence`：复制到 `docs/acp/tests/evidence/zed-initialize-<日期>/`；
- `scripts/acp/zed-capture/collect.sh --cleanup`：删除 /tmp 下的采集目录。

协调者核对 Zed 请求的 `protocolVersion`、`clientCapabilities`（fs、terminal、elicitation 等），以及 initialize 回复前有没有流水线请求，然后写入 02-protocol-version 与 ACP-T26-01 的证据。**取得这些真实帧之前，02 的版本结论不得据模拟结果填写，ACP-T26-01 也不得标记通过。** 这一步只证明 Zed 能启动并与 dev 入口握手，不算 P1 验收。

不想让脚本启动 Zed 时：`scripts/acp/zed-capture/setup.sh --print` 只打印 `agent_servers` 片段，不写任何文件；只应放进独立的 Zed 配置，不要放进你自己的设置。

本线已在不启动 Zed 的情况下验证过采集包装（`scripts/acp/zed-capture/selftest.sh`，证据见 [evidence/zed-capture-selftest-2026-10-08](evidence/zed-capture-selftest-2026-10-08/)）：

- 2 MiB 多字节输入分 33 块穿过包装后，stdout 和两份 `.bin` 都与输入逐字节相同；
- 假编辑器经包装驱动 dev 入口，包装记下的 11 + 24 帧与假编辑器自己的记录逐条一致；
- 脱敏后没有残留。

## 四、P1 端到端：计算器中立样本（ACP-T26-*、ACP-P1-*）

计算器只是通用 GUI 能力的验收载体，**只出现在测试数据、本手册与测试 profile 里，不进入产品源码**（原文 §8）。样本任务由 A6 的任务目录或测试夹具登记为一个中立的「registered procedure」，例如「在一个新 Desktop 上启动计算器，依次按 7、+、8、=，读取显示值」。任务名与参数在 A6 合入后填进 `profiles/agentdesktop-*.json` 的 `PROMPT_*` 变量和下表。

### 四.0 #246 验收表（Kevin 2026-10-11 裁决）

真机，测试副本，Kevin 本人批准。每一行都记录命令、退出码、Runtime 的错误码和审计条目。

| # | 场景 | 预期 |
|---|---|---|
| W1 | `pair --desktops "$DESK"` | 确认窗口显示 ACP 桥自己的代码身份；批准后配对成功 |
| W2 | `pair` 不带 `--desktops`，或 `--desktops created` | 命令直接拒绝（退出码 2），没有发出任何请求 |
| W3 | 配对后在 Zed 里 `/help` | 列出 `unit.run`；若 Runtime 宣告了 `ai.profiles.list`，它被拒绝，但任务列表仍正常 |
| W4 | 未获得窗口授权时提交 `unit.run` | 拒绝（`grant_missing`，reason `window_grant_missing`） |
| W5 | `request-window` | 出现确认窗口，列出计算器窗口和 observe、act |
| W6 | W5 里点「拒绝」 | 报错 `user_denied`，不重试；随后 `unit.run` 仍被拒 |
| W7 | Touch ID 批准 | 输出「window grant … for the window bound on $DESK」；`unit.run` 能执行 |
| W8 | 对未授权的 Desktop 提交 `unit.run` | `not_found`（授权外的 Desktop 对桥不存在） |
| W9 | 对同一 App 的另一个窗口申请或使用 | 申请时核对不通过（`notTheBoundWindow`）；使用时被拒 |
| W10 | 在主窗口撤销窗口授权后再执行 | `grant_missing`（`window_grant_ended`），observe、act 都被拒 |
| W11 | 主窗口把 Desktop 改绑到另一个窗口 | 原授权不延续到新窗口：`unit.run` 被拒，需要重新申请 |
| W12 | 正常提交、查询、订阅、取消 Run | 全部正常（ACP-T26-*、ACP-P1-*） |
| W13 | `same_user` 身份 | 能发起申请，但必须由 Kevin 在确认窗口批准；授权只属于桥自己的 clientId（`agentdesktop` 主窗口或审计里核对） |
| W14 | W5 的确认窗口出现后等 30 秒以上再批准 | 命令一直等到作答，正常输出授权（回复超时 150 秒，长于 Runtime 的 120 秒确认时限）；不得先报 `connection_lost` |
| W15 | `request-window --bundle-id` 用不在 `--apps` 里的 App | `grant_missing`（reason `window_not_grantable`），不弹确认窗口 |

另外，至少完整跑一次 Zed → 桥 → Runtime → Desktop → GUI 执行 → 结果回到 Zed 的真机链路（下面的步骤）。

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
| ACP-T18-04a | `scripts/acp/mcp-readonly-probe.py <cli> <endpoint> <out>`（只读） | 同一 instanceId 作答、MCP 进程唯一 socket 的对端是 Runtime 端点、无人监听时全部失败 |
| ACP-T18-04b | `agentdesktop mcp`（#29）发一次 act（需真实 GUI 动作） | Runtime 账本有该 requestId |
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

- 现在：按 §三.1 做一次 Zed 首帧采集（约 2 分钟：退出 Zed → setup.sh → New Thread → `/help` → 退出 Zed → collect.sh）。
- P1 验收那天：Zed 用 §三 的配置，同样放在独立的 `--user-data-dir` 里，不改你自己的设置；需要时授予测试副本屏幕录制与辅助功能权限。
- JetBrains（P2）：安装一个 JetBrains IDE 并登录 JetBrains AI，见 §七。P1 不需要。
- A4 之后需要两个测试身份（clientId）用于 ACP-T07、T15、ACP-31，由 Hub 的配对流程签发，验收时请 Kevin 在测试副本上确认配对。
