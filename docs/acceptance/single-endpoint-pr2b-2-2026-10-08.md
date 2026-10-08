# PR2b-2：删除 ai/1，Contracts 并入 Protocol —— 验收记录（2026-10-08）

授权范围：Kevin 批准 PR2b-2 的开发、测试和提交 PR；合并由他决定。PR #2 合入 main 不在本次授权内。

## 改了什么

| 项 | 内容 |
| --- | --- |
| ai/1 信封 | Swift 端全部删除：`Envelope`、`RpcRequest`、`DecodedFrame`、`FrameReader`、`RpcSocketServer`、CLI 的 `SocketClient` / `ContractOverRuntime`、UI 的 `SocketContractClient` 和信封组装。不保留兼容层 |
| 服务调度 | `ServiceRouter.answer(method:params:deadline:idempotencyKey:)` 直接调度：按 `<method>_params` 校验参数、写操作要求 8–128 字符的幂等键、按 `<method>_result` 校验结果。处理函数签名改为 `ServiceRequest` |
| Runtime 桥接 | `RuntimeBridge` 不再把调用编码成 ai/1 JSON 再解码，直接调用路由；服务错误映射为 runtime/1 小写码，原分类放在 `details.serviceCode`（原来叫 `aiCode`） |
| 合同 | 新增 `contracts/runtime/v1/service.schema.json`：由 ai-gui 的 domain 定义和 params / result 定义生成，不含任何信封定义。`methods.json` 的 servedBy 方法引用它，并写明 `asynchronous` / `requiresIdempotencyKey`。它和 runtime/1 的其他合同一起嵌入代码，由同一个 `RuntimeContract` 加载 |
| capabilities | AI 服务不再有自己的 `runtime.capabilities`；GUI 能力定义改名为 `GuiCapabilities`，去掉 ai/1 的 `schemaVersions` 字段，只出现在 `runtime.capabilities` 的 `gui` 字段里 |
| 模块 | `AgentDesktopContracts` 并入 `AgentDesktopProtocol`（148 个文件改 import）；唯一的重名类型 GUI `Rect` 改名为 `GuiRect` |
| CLI | `rpc` / `ai` / `gui` 命令直接组装 runtime/1 请求（幂等键即 requestId），在同一连接上先握手再发送，输出 runtime/1 应答；`rpc --request-file` 只收 runtime/1 请求；命令、参数和退出码表都不变 |
| 主窗口 | 设置页在进程内直接调路由；GUI 能力经 `guiCapabilities()` 读取 |
| 顺带修复 | AI 服务原来靠 SwiftPM 的 `Bundle.module` 加载合同文件，但打包脚本并不带这个资源包。本机能用只是因为它退回到了构建目录；换一台机器，AI 服务一启动就会 fatalError。现在合同嵌入在代码里，打包后的程序里已没有资源包引用 |

**没有动的**：Windows 的 C# 合同层（`windows/src/AgentDesktop.Contracts`）仍实现 ai/1，并嵌入 `contracts/ai-gui/v1`。本机没有 dotnet，无法构建验证，所以这次不改，在该目录加了 README 说明，交给 Windows 线迁移。

## 本地 CI（GitHub Actions 额度已用完）

见 PR 评论，所有步骤退出码为 0。

## 自动化测试

`swift test`：466 项全部通过，退出码 0。本次新增或改写的测试：

- **协议一致性**
  - 嵌入的 `service.schema.json` 与仓库文件逐字节一致；
  - 31 个 servedBy 方法的 params / result 引用都能在服务 Schema 中解析；每个写操作都要求幂等键；
  - 服务 Schema 里没有任何 `_request` / `_response` / Request / Response / ErrorResponse 定义，也没有 `agentdesktop.ai/1` 字样。
- **服务路由**：
  - 合法调用只到达处理函数一次；
  - 参数不合规时不调用处理函数，错误里只有指针和关键字，没有参数值（包括密钥）；
  - 写操作缺幂等键、键太短、太长、含非法字符时都拒绝，处理函数调用 0 次；
  - 违反合同的结果（含密钥）不会返回给调用方；
  - 未知方法、`runtime.capabilities` 和没有处理函数的方法都返回 UNSUPPORTED_COMMAND。
- **错误码**：
  - 服务的每一个错误码都映射到 `errors.json` 里存在的小写码，并带 `serviceCode`；
  - 冻结表的 13 条对应关系逐条核对；`retryable` 和 `retryAfterMs` 保留下来；
  - CLI 退出码：capability_missing、version_mismatch、handshake_required、runtime_offline → 3；其他 → 4。
- **CLI 经真实 Runtime 端点**（CLIFriendlyTests、cliOverTheRuntimeEndpoint）：
  - 原有的 CLI-001…004 改为跑在 RuntimeServer 加桥接上，输出是 runtime/1 应答；
  - 旧 ai/1 请求在本地被拒（invalid_argument，退出码 2）；
  - 客户端中途断开不影响服务端；
  - 端点不可达时退出码 3。
- **规范示例**：31 个操作的示例 params 和 result 都通过服务 Schema 校验。
- **跨平台**：与 C# 校验结论一致的 `fieldErrors` 路径（`/params/...`）保持不变。

## 真机（测试副本 /tmp/adt-b2）

| 检查 | 结果 |
| --- | --- |
| 打包后的宿主程序 / CLI 中的 `agentdesktop.ai/1` 字样 | 0 / 0 |
| 宿主程序中对 Contracts 资源包的引用 | 0 |
| 副本目录里的 socket | 只有 `side.runtime.sock` |
| `ai capabilities` | 返回 runtime/1 应答，`data.gui.implementedAiProtocols = ["openai_chat"]` |
| `ai connections create --credential-stdin --idempotency-key b2-conn-0001`，执行两次 | 都成功；requestId 就是幂等键；两次返回同一个 connectionId；输出里没有密钥 |
| `ai connections list` | 1 条 |
| `ai connections get --id conn_missing` | 退出码 4；`not_found`，`serviceCode: NOT_FOUND` |
| 幂等键 `short` | 本地拒绝（invalid_argument，phase local，notSent），退出码 2，没有发送 |
| `rpc --request-file`（runtime/1 请求） | 成功，requestId 原样返回 |
| `rpc --request-file`（旧 ai/1 请求） | 本地拒绝，退出码 2 |
| 端点不存在 | 退出码 3，提示无法连接 |
| 密钥落盘 | 只在副本自己的 `test-credentials` 里 |

清理：停止副本，删除目录。

## 未验证

- 主窗口设置页没有做人工界面检查。自动化 UI 测试（PagesTests 等）全部通过；宿主启动后 AI 服务正常，`gui` 能力字段可读。
- Windows 端不在本 PR 范围内。
