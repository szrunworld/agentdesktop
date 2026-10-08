# ACP 协议版本决策与兼容矩阵（工作线 T）

状态：P1 决策稿，2026-10-08；第二轮（`acp-lane-t2`）补 v1 `session/resume` 与 cwd。负责：工作线 T。所有事实均用 `gh api`、`npm view`、crates.io API 或本机二进制核对过，带提交 SHA 与日期；没核对到的标「未核实」。

## 一、结论

1. **P1 线协议版本：ACP `protocolVersion: 1`**，以官方稳定 schema `schema-v1.24.1`（2026-09-30）为准，只用稳定面，不读写 `schema.unstable.json` 里的任何方法或字段。
2. **不做 v2 适配器。** v2 在官方仓库里是草案（`schema-v2.0.0-alpha.7`），官方 Rust、TypeScript、Kotlin SDK 都把它放在显式开关后面，默认/最新版本仍是 1；我们核对的所有真实客户端（含本机已装的 Zed 1.23.2）发送的都是 `protocolVersion: 1`。按「真实客户端说过才能宣称支持」的规则，`ACPWireNegotiation.supported == [.v1]`，`ACPWire.adapter(for: .v2)` 返回 nil。
3. **版本差异只在 `Wire/` 里。** 内部版本中立模型（`ACPModel.swift`）不为多版本加字段；以后真有客户端说 v2，再加一个 `ACPWireV2`，Runtime 与其它工作线不变。
4. 原文 4.1 关于 v2 的五条描述**属实，但描述的是 v2 草案**；其中「list / resume / close / 配置选项」在 **v1 稳定版里已经有了**（见第三节），P1 用 v1 就能得到这些能力，不需要 v2。

## 二、证据：谁在说哪个版本

### 2.1 规范与官方 SDK

| 名称 | 版本 / 标签 | 日期 | SHA / 位置 | 默认 / 最新协议版本 | 证据 |
| --- | --- | --- | --- | --- | --- |
| 规范仓库 agentclientprotocol/agent-client-protocol | `main` | 2026-10-08 | `1c2b84c785c923ed283a4e7ea3badb2422596418` | v1 稳定，v2 草案 | `schema/v1/schema.json`、`schema/v2/schema.json`；`docs/protocol/v2/migration.mdx`：「The v2 protocol surface as a whole is still labeled draft」 |
| 稳定 schema | `schema-v1.24.1` | 2026-09-30 | 同上 | 1 | `schema/v1/meta.json` `"version": 1` |
| 草案 schema | `schema-v2.0.0-alpha.7` | 2026-09-30 | 同上 | 2（草案） | `schema/v2/CHANGELOG.md` |
| Rust schema crate `agent-client-protocol-schema` | 1.10.2 | 2026-10-01 | 规范仓库 `agent-client-protocol-schema/src/version.rs` | `LATEST = V1`；`V2` 只在 `unstable_protocol_v2` feature 下存在 | 同文件注释：「V2 … unstable draft … must be selected explicitly」 |
| Rust SDK crate `agent-client-protocol` | 3.1.0 | 2026-10-07 | github.com/agentclientprotocol/rust-sdk `v3.1.0` | 依赖上面的 schema crate | crates.io API |
| TypeScript SDK `@agentclientprotocol/sdk` | 1.7.0（latest） | 2026-10-02 | npm 包 `dist/schema/index.js:49` | `PROTOCOL_VERSION = 1`；v2 只在子路径 `./experimental/v2` | `npm view`；`dist/protocol-router.js` 的 `AgentProtocolRouter`：低于最低支持版本时回 `invalidRequest`「unsupported ACP protocol version」 |
| Kotlin SDK agentclientprotocol/kotlin-sdk | v0.32.0（最新 release）；HEAD `3af219ae81f413024a385f8390540bf648f63938` | 2026-09-01 / 2026-10-06 | `acp-model/.../Types.kt:20-33` | `LATEST_PROTOCOL_VERSION = PROTOCOL_VERSION_V1`；v2「deliberately absent from SUPPORTED_PROTOCOL_VERSIONS」 | gh api |
| 旧 TS 包 `@zed-industries/agent-client-protocol` | 0.4.5 | 2025-10-10 | — | 已停更，被 `@agentclientprotocol/sdk` 取代 | `npm view` |

### 2.2 编辑器（客户端）

| 客户端 | 版本 / 提交 | 日期 | 发送的 `protocolVersion` | 证据 |
| --- | --- | --- | --- | --- |
| **Zed（本机已装）** | 1.23.2（tag `v1.23.2` = `c0199504b9cce79bc27524950022ed701bc3ebd5`） | 2026-10-07 | **1** | `crates/agent_servers/src/acp.rs:796` `acp::InitializeRequest::new(ProtocolVersion::V1)`，`:535` `MINIMUM_SUPPORTED_VERSION = V1`；本机 `/Applications/Zed.app/Contents/MacOS/zed` 内嵌 `agent-client-protocol-2.2.0` 与 `agent-client-protocol-schema-1.9.1`（`strings` 核对） |
| Zed main | `dc3fb21676457b84d2233ac4c6bec5cebc698ec3` | 2026-10-08 | 1 | 同文件 `:864`；`Cargo.toml:530` 依赖 `agent-client-protocol =2.2.0`，开了 `unstable`、`unstable_protocol_v2` 两个 feature，但握手仍显式发 V1 |
| JetBrains IDE（AI Assistant 的 ACP） | 闭源 | — | 未核实（本机无 JetBrains IDE） | 规范仓库 `docs/get-started/clients.mdx` 列出 JetBrains；JetBrains 维护的 Kotlin SDK 最新版本为 1 |
| Neovim codecompanion.nvim | `3dd1ef7fa8d6aeb27020023e40293bac588de714` | 2026-10-02 | 1 | `lua/codecompanion/adapters/acp/codex.lua:29` `protocolVersion = 1`（其它 ACP 适配器同） |
| Neovim agentic.nvim（carlos-algms） | `e280deec82cfe642bba2c0d0157d320b706c094a` | 2026-10-04 | 1 | `lua/agentic/acp/acp_client.lua:92` `protocol_version = 1`，`:783` 发送 |
| Emacs agent-shell（xenodium） | `9a52907d7c6c00e06e570d2d37a50c1a0174fa47` | 2026-10-07 | 1 | `agent-shell.el:7064` `:protocol-version 1`（经 acp.el `242cef63…` `acp.el:568` 发出） |

### 2.3 适配器（Agent 端，供 O 线参考）

| 适配器 | 版本 | 日期 | 依赖 SDK | 回答的版本与能力 |
| --- | --- | --- | --- | --- |
| `@agentclientprotocol/claude-agent-acp` | 0.87.0 | 2026-10-07 | `@agentclientprotocol/sdk` 1.7.0 | `dist/acp-agent.js:1342` `protocolVersion: 1`；`loadSession: true`，`sessionCapabilities` 有 `list`、`resume`、`close` |
| `@agentclientprotocol/codex-acp` | 2.1.1（`4583cb3978276c2b7ea87fcfa5ae66e1e9817f13`） | 2026-10-01 | `@agentclientprotocol/sdk ^1.5.0` | `src/CodexAcpServer.ts:438` `protocolVersion: acp.PROTOCOL_VERSION`（=1） |

结论：截至 2026-10-08，没有找到任何正式发布的客户端在握手里发送 2。

## 三、核对原文 4.1 对 v2 的五条描述

| 原文说法 | 核对结果（v2 = `docs/protocol/v2/migration.mdx`） | 对 P1 的意义 |
| --- | --- | --- |
| v2 用 `session/resume` 取代 `session/load` | **属实（草案）**：v2 删除 `session/load`，改用 `session/resume` + `replayFrom: {type:"start"}`。但 **v1 稳定版同时有 `session/load`（重放历史）和 `session/resume`（不重放，`sessionCapabilities.resume`）** | P1 可在 v1 里做恢复 |
| `session/prompt` 的响应表示已受理，进度经 `session/update` | **属实（草案）**：v2 里响应只表示受理，结束原因走 `state_update`。**v1 里 prompt 响应就是本轮结束**（`PromptResponse.stopReason`） | v1 适配器把 `ACPReply.promptFinished` 编成 prompt 响应；`ACPSessionUpdate.turnEnded` 在 v1 不发 |
| 列表、恢复、关闭、取消是声明 Session 能力后的基础接口 | **属实（草案）**：v2 声明 `capabilities.session` 即必须实现 new/list/resume/close/prompt/cancel/update。v1 里 `list`、`resume`、`close` 各有独立能力标记，按需声明 | v1 按 `ACPAgentCapabilities` 逐项声明，没实现的不声明 |
| 模式切换用配置选项，不用 `session/set_mode` | **属实（草案）**：v2 删除 `session/set_mode`。**v1 稳定版已有 `session/set_config_option` 与 `configOptions`**（v1.16～1.18 稳定 category 与 boolean） | P1 只用配置选项；从不返回 `modes`，`session/set_mode` 为「方法不存在」 |
| 计划、工具调用、权限请求结构有更新 | **属实（草案）**：v2 去掉 `tool_call`（首个 `tool_call_update` 即创建）、`plan` 改为 `plan_update`、权限请求必须带 `title` | 只影响将来的 v2 适配器 |

## 四、传输与帧（已实现）

- 规范：v1 `docs/protocol/v1/transports.mdx`「stdio」：UTF-8；**一行一条 JSON-RPC 消息，以 `\n` 分隔，消息内不得有换行**；agent 的 stdout 只能写合法 ACP 消息，日志写 stderr。
- `ACPFrameSplitter`：按 `\n` 切帧，容忍 `\r\n`，跳过空行；**单帧上限默认 16 MiB**（`ACPStdioConnectionOptions.maxFrameBytes`；官方 TS SDK 默认 32 MiB）。超长行一越线就报一次，后续字节直接丢弃，内存始终有界。
- 编码：`JSONValue.encoded()` 转义所有行终止符（含 U+2028/2029），每帧恰好一行。
- 解析：复用 `AgentDesktopContracts.StrictJSON`（拒绝重复键、深度 > 64、非法 UTF-8、尾随数据）。
- JSON-RPC 2.0：不支持批量（数组回 -32600）；请求 id 只接受整数或字符串（`null`、小数回 -32600）；`params` 必须是对象。
- 错误处理：

| 情况 | 处理 |
| --- | --- |
| 无法解析的帧 | 回 -32700（id null），继续；累计超过 16 帧（可配）则断开，`.closed("too_many_malformed_frames")` |
| 结构不合法的请求 | 回 -32600，能读到 id 就带 id |
| 未知方法、未声明能力的方法 | 回 -32601 |
| 参数不合法（含 cwd 不是绝对路径、未声明的内容类型） | 回 -32602 |
| `initialize` 之前的请求、重复 `initialize`、重复 id | 回 -32600 |
| 超长帧 | 回 -32600（id null）后断开，`.closed("frame_too_large")` |
| stdin 关闭 | `.closed("input_closed")`；半帧时 `.closed("input_closed_mid_frame")` |
| stdout 写失败 | `.closed("output_closed")`；输出描述符设了 `F_SETNOSIGPIPE`，不会被 SIGPIPE 杀掉 |
| 未知通知（含 `$/cancel_request`） | 忽略，不回 |
| 对不存在 id 的响应 | 忽略 |

**流水线（pipelining）规则**：JSON-RPC 允许不等回复连续发送。连接按到达顺序处理一切：`initialize` 被接受（协商成功）后、它的回复写出之前，后续到达的请求与通知全部暂存；回复写出后按原顺序处理暂存项（服务器接受了 `initialize` 就照常交给服务器，服务器拒绝了就逐个回 -32600「connection not initialized」），处理完暂存项之前新到的消息继续排队，任何消息都不会越过更早的消息。只有在**任何 `initialize` 之前**到达的请求才会被拒绝（-32600），守序的客户端不会遇到。注意 stdin 关闭即视为编辑器断开（ADR v2.2），之后不再写回复，所以用 `printf … | agentdesktop-acp-dev --demo` 复现时要让 stdin 保持打开（如 `(printf …; sleep 2) | …`）。

被拒绝的帧一律不交给服务器；`.closed` 只发一次，之后事件流结束。断开时所有未决的 agent→编辑器请求（`session/request_permission`、`elicitation/create`）一律得到 `.unavailable`，从不当作允许。

## 五、版本协商与能力声明（已实现）

**协商**（与官方 TS SDK `AgentProtocolRouter` 相同）：

| 客户端发送 | 我们的处理 |
| --- | --- |
| `1` | 用 v1 |
| `2`…`65535`（比我们新） | 按规范回我们支持的最高版本 `1`，由客户端决定是否断开 |
| `0`（比我们支持的最低版本还老） | **拒绝**：-32600 `unsupported ACP protocol version 0; this agent speaks 1`，`data.reason = "protocol_version_unsupported"` |
| 缺失、字符串、小数、负数、> 65535、`1.0`、`1e0` | -32602 `initialize.protocolVersion must be an integer from 0 to 65535` |

连接负责协商，服务器（S 线）只收到 `.initialize(client:capabilities:requested:)`；服务器回 `.initialized(version:)` 时版本必须等于协商结果，否则连接回 -32603，绝不发出与协商不符的版本。

**能力声明**（v1 `InitializeResponse`，由 `ACPAgentCapabilities` 逐项决定，默认全是 false）：

| 模型字段 | v1 线上字段 | 说明 |
| --- | --- | --- |
| `resumeSessions` | `agentCapabilities.loadSession: true` 且 `sessionCapabilities.resume: {}` | 同时解锁 `session/load`（→ `.resumeSession(replay: true)`，规范要求先重放历史再回复）与 `session/resume`（→ `replay: false`，不得重放）；两者都必须带绝对路径 `cwd`，原样交给模型 |
| `listSessions` | `sessionCapabilities.list: {}` | 解锁 `session/list`；`cwd` 过滤参数（须为绝对路径）交给模型 `.listSessions(cwd:)`；回复里 `SessionInfo.cwd` 取自 `ACPSessionSummary.cwd`；不发游标，收到游标回 -32602 |
| `closeSessions` | `sessionCapabilities.close: {}` | 解锁 `session/close` |
| `promptImages` | `promptCapabilities.image` | 图片字节留在适配器里，模型只拿句柄 |
| `promptEmbeddedContext` | `promptCapabilities.embeddedContext` | 只取文本内容，二进制 blob 不往下传 |
| 无 | `audio: false`、`mcpCapabilities: {http:false, sse:false}`、`authMethods: []` | 始终不声明 |

`session/delete`、`session/set_mode`、`authenticate`、`logout`、`fs/*`、`terminal/*` 以及所有 unstable 方法都回「方法不存在」；`resumeSessions` 为 false 时 `session/load` 与 `session/resume` 也是「方法不存在」。客户端能力：`elicitation` 只有 `elicitation.form` 明确存在且非 null 时才算支持（规范明确与 MCP 不同，`{}` 不算）；不支持时 `ask()` 直接返回 `.unavailable`，不发请求。

**v1 表达不了、因此不发的内容**：`ACPSessionUpdate.usage`（v1 `usage_update` 是上下文窗口占用 used/size，不是每轮 token 数）、`ACPSessionUpdate.turnEnded`（v1 由 prompt 响应结束一轮）。直接丢弃，不近似。

**补位约定**（v1 必填但模型没有的字段）：计划条目 `priority` 固定 `"medium"`；配置选项一律 `type: "select"`，`id == "mode"` 时加 `category: "mode"`；工具调用的三级结果放在 `_meta.agentdesktop.actionLevel`（如 `executed`、`refused:policy_denied`）；权限选项 id 为 `allow_once` / `reject_once`，编辑器选了未提供的选项（如 `allow_always`）一律当 `.unavailable`。

## 六、接口请求（需协调者改 `ACPModel.swift`）

状态（2026-10-08，`acp-skeleton` 34ae2c5）：第 1、2、3、5 条已由协调者落地（`ACPSessionSummary.cwd`、`.resumeSession(sessionId:cwd:replay:)`、`.listSessions(cwd:)`、测试目标 `exclude: ["Fixtures"]`），第二轮已接上；第 2 条没有另加能力标记，按协调者决定由 `resumeSessions` 同时控制 load 与 resume。第 4 条维持现状：v1 不发 `usage`。第 6 条由 D 线写进 RFC。下面保留原始请求以便追溯。

1. **`ACPSessionSummary` 缺 `cwd`。** v1 `SessionInfo.cwd` 必填。目前适配器用「本连接见过的该会话 cwd → 本次 `session/list` 的 cwd 过滤参数 → 空串」兜底，空串合法但没有意义。建议加 `cwd: String`。
2. **`.resumeSession` 分不清「重放」与「不重放」。** v1 的 `session/load` 必须重放、`session/resume` 必须不重放；Zed 与 agent-shell 都支持两者，agent-shell 默认优先用不重放的 `session/resume`。目前只声明 `loadSession`，`session/resume` 回「方法不存在」。建议改为 `.resumeSession(sessionId:, replay: Bool)`，并在 `ACPAgentCapabilities` 加 `resumeWithoutReplay`。
3. **`.listSessions` 与 `.resumeSession` 不带 `cwd`。** v1 的 `session/list` 可按 cwd 过滤，`session/load`/`resume` 必带 cwd。建议 `.listSessions(cwd: String?)`、恢复请求带 `cwd`，服务器自行校验。
4. **`ACPSessionUpdate.usage` 与 v1 语义不符。** 若要在 v1 展示，需要 `used/size`（上下文窗口），而不是输入/输出 token 数。
5. **测试夹具未在 `Package.swift` 排除。** `Fixtures/acp-schema/*.json` 会让 SwiftPM 报「unhandled files」警告（不影响构建与测试）。建议 `AgentDesktopACPTests` 加 `exclude: ["Fixtures"]`，与其它测试目标一致。
6. **`session/new` 的 `mcpServers`。** v1 规范要求所有 agent 支持 stdio MCP 服务器；我们按设计不连接编辑器给的 MCP 服务器，适配器忽略该字段。这是有意偏离，需在 RFC 0002 里写明（D 线）。

## 七、互通证据

### 7.1 官方 TypeScript SDK 客户端 ↔ 我们的 stdio 实现（已执行）

- 时间：2026-10-08，本机 node 22.23.2。
- 客户端：`@agentclientprotocol/sdk@1.7.0` 的 `ClientSideConnection` + `ndJsonStream`（`/tmp/acp-lane-t/interop/client.mjs`，未提交）。
- Agent：用 `AgentDesktopACP` 的 `ACPStdioConnection.standardIO()` 写的回声 agent（`/tmp/acp-lane-t/echo`，独立 SwiftPM 包按路径依赖本工作树，未提交、不进 Sources）。
- 结果（第一轮）：退出码 0。协商 1；新建、列表、设置配置、prompt（含计划、消息、工具调用、权限请求→允许、表单提问→回答、会话标题）、`session/load`（重放后回复）、`session/close` 全部成功；`session/resume` 当时未声明，得到 -32601；关闭 stdin 后 agent 以 `closed input_closed` 退出，退出码 0。
- 版本协商经 SDK 实测：请求 2 → 回答 1；请求 0 → `-32600: unsupported ACP protocol version 0; this agent speaks 1`。

线上记录（原样，C→A 为客户端到 agent）：

```text
C→A {"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{"fs":{"readTextFile":false,"writeTextFile":false},"terminal":false,"elicitation":{"form":{}}},"clientInfo":{"name":"ts-sdk-smoke","version":"1.7.0"}}}
A→C {"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"promptCapabilities":{"image":false,"audio":false,"embeddedContext":false},"mcpCapabilities":{"http":false,"sse":false},"sessionCapabilities":{"list":{},"close":{}}},"authMethods":[],"agentInfo":{"name":"agentdesktop-echo","version":"0.0.1"}}}
C→A {"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp/acp-lane-t","mcpServers":[]}}
A→C {"jsonrpc":"2.0","id":1,"result":{"sessionId":"echo-1","configOptions":[{"id":"mode","name":"Mode","category":"mode","type":"select","currentValue":"ask","options":[{"value":"ask","name":"ask"},{"value":"auto","name":"auto"}]}]}}
C→A {"jsonrpc":"2.0","id":2,"method":"session/list","params":{}}
A→C {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"echo-1","update":{"sessionUpdate":"available_commands_update","availableCommands":[{"name":"echo","description":"Echo the input","input":{"hint":"text"}}]}}}
A→C {"jsonrpc":"2.0","id":2,"result":{"sessions":[{"sessionId":"echo-1","cwd":"/tmp/acp-lane-t","title":"Echo echo-1","updatedAt":"2026-10-08T00:00:00Z"}]}}
C→A {"jsonrpc":"2.0","id":3,"method":"session/set_config_option","params":{"sessionId":"echo-1","configId":"mode","value":"auto"}}
A→C {"jsonrpc":"2.0","id":3,"result":{"configOptions":[{"id":"mode","name":"Mode","category":"mode","type":"select","currentValue":"auto","options":[{"value":"ask","name":"ask"},{"value":"auto","name":"auto"}]}]}}
C→A {"jsonrpc":"2.0","id":4,"method":"session/prompt","params":{"sessionId":"echo-1","prompt":[{"type":"text","text":"hello from TS"}]}}
A→C {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"echo-1","update":{"sessionUpdate":"plan","entries":[{"content":"echo","priority":"medium","status":"in_progress"}]}}}
A→C {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"echo-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"echo: hello from TS"}}}}
A→C {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"echo-1","update":{"sessionUpdate":"tool_call","toolCallId":"tc-1","title":"Pretend click","kind":"execute","status":"pending","content":[]}}}
A→C {"jsonrpc":"2.0","id":0,"method":"session/request_permission","params":{"sessionId":"echo-1","toolCall":{"toolCallId":"tc-1","title":"Pretend click","kind":"execute","status":"pending","content":[{"type":"content","content":{"type":"text","text":"Would click a button"}}]},"options":[{"optionId":"allow_once","name":"Allow once","kind":"allow_once"},{"optionId":"reject_once","name":"Reject","kind":"reject_once"}]}}
C→A {"jsonrpc":"2.0","id":0,"result":{"outcome":{"outcome":"selected","optionId":"allow_once"}}}
A→C {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"echo-1","update":{"sessionUpdate":"tool_call_update","toolCallId":"tc-1","title":"Pretend click","kind":"execute","status":"completed","content":[],"_meta":{"agentdesktop":{"actionLevel":"executed"}}}}}
A→C {"jsonrpc":"2.0","id":1,"method":"elicitation/create","params":{"sessionId":"echo-1","mode":"form","message":"Pick a colour","requestedSchema":{"type":"object","properties":{"answer":{"type":"string","title":"Answer","oneOf":[{"const":"red","title":"red"},{"const":"blue","title":"blue"}]}},"required":["answer"]}}}
C→A {"jsonrpc":"2.0","id":1,"result":{"action":"accept","content":{"answer":"blue"}}}
A→C {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"echo-1","update":{"sessionUpdate":"session_info_update","title":"Echo: hello from TS"}}}
A→C {"jsonrpc":"2.0","id":4,"result":{"stopReason":"end_turn"}}
C→A {"jsonrpc":"2.0","id":5,"method":"session/load","params":{"sessionId":"echo-1","cwd":"/tmp/acp-lane-t","mcpServers":[]}}
A→C {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"echo-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"(replayed history of echo-1)"}}}}
A→C {"jsonrpc":"2.0","id":5,"result":{"configOptions":[{"id":"mode","name":"Mode","category":"mode","type":"select","currentValue":"ask","options":[{"value":"ask","name":"ask"},{"value":"auto","name":"auto"}]}]}}
C→A {"jsonrpc":"2.0","id":6,"method":"session/close","params":{"sessionId":"echo-1"}}
A→C {"jsonrpc":"2.0","id":6,"result":{}}
C→A {"jsonrpc":"2.0","id":7,"method":"session/resume","params":{"sessionId":"echo-1","cwd":"/tmp/acp-lane-t","mcpServers":[]}}
A→C {"jsonrpc":"2.0","id":7,"error":{"code":-32601,"message":"method not found: session/resume"}}
```

（中间一条回显权限结果的调试消息省略。）

第二轮重跑（同一客户端脚本，agent 按 `acp-lane-t2` 重建，退出码 0）：`initialize` 结果里 `sessionCapabilities` 变为 `{"list":{},"close":{},"resume":{}}`，`session/resume` 不重放直接成功：

```text
A→C {"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"promptCapabilities":{"image":false,"audio":false,"embeddedContext":false},"mcpCapabilities":{"http":false,"sse":false},"sessionCapabilities":{"list":{},"close":{},"resume":{}}},"authMethods":[],"agentInfo":{"name":"agentdesktop-echo","version":"0.0.1"}}}
C→A {"jsonrpc":"2.0","id":7,"method":"session/resume","params":{"sessionId":"echo-1","cwd":"/tmp/acp-lane-t","mcpServers":[]}}
A→C {"jsonrpc":"2.0","id":7,"result":{"configOptions":[{"id":"mode","name":"Mode","category":"mode","type":"select","currentValue":"ask","options":[{"value":"ask","name":"ask"},{"value":"auto","name":"auto"}]}]}}
```

### 7.2 Zed 1.23.2 真机握手（未完成）

在隔离数据目录 `/tmp/adt-zed-lane-t`（`--user-data-dir`，配置在 `/tmp/adt-zed-lane-t/config/settings.json`，**未碰用户的 Zed 设置**）里登记了一个 custom agent server（回声 agent，外包 `tee` 记录双向帧），在 2ndscreen 虚拟屏上启动 Zed、打开了 Agent 面板；选择自定义 agent 的菜单在后台点击下没有弹出，随后 2ndscreen 菜单栏程序退出，测试 Zed 已关闭，没有拿到线上帧。Zed 说 v1 的证据目前来自源码（tag `v1.23.2`）与本机二进制内嵌的 crate 版本。真机握手留给 Q 线的 Zed 手册（需要前台操作一次「New Thread → AgentDesktop Echo」），届时把 `/tmp/adt-zed-lane-t/wire.in` 的第一行 `initialize` 贴到这里。

## 八、测试

`swift test --filter AgentDesktopACPTests`：T01～T05 与帧、编解码、schema 一致性测试见 `Tests/AgentDesktopACPTests/Transport/`、`Wire/`。一致性测试把官方 v1 `schema.json` 载入 `AgentDesktopContracts.SchemaRegistry`（先去掉不带断言的 `discriminator`、`x-*`、`unevaluatedProperties: true`），对编码器能产生的每一种回复、更新、权限请求、提问请求、错误对象做两次校验：整条消息对 schema 根，`params`/`result`/`error` 对具体类型。假编辑器 `TTestEditor` 收到的每一帧也都过同样的校验。

测试不靠墙钟时间窗口判断：`TTestInbox.next()` 等到下一个值或流结束为止（60 秒只作防挂死保护）；要证明「没有别的帧/事件」，就发一个探针请求（`probeFrameIsNext` / `probeEventIsNext`），因为帧和事件严格按序，探针的回答紧跟着到达即说明之前什么都没有。第一轮里 t04、t05 在全量并行负载下偶发失败，原因是 2 秒等待窗口在负载下不够；第二轮改法后全量 `swift test` 连跑三次全部通过。

## 九、未完成项

1. Zed 真机握手记录（见 7.2）。
2. `$/cancel_request`（v1 稳定，`CancelRequestNotification`）：规范说取消是可选的，支持方收到后必须为原请求回一个响应（-32800 或正常结果）。我们按「不支持」处理：忽略该通知，原请求照常由服务器回答。原因：版本中立模型里没有「取消某个请求」的入口，连接若自行回 -32800，会让编辑器以为已取消而服务器其实还在跑（prompt 的取消必须走 `session/cancel` 并以 `cancelled` 结束）。需要时由 S 线提接口请求。
3. v2 稳定且有真实客户端发送 2 之后，再加 `ACPWireV2` 与 v2 schema 夹具。
