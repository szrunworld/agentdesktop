# AgentDesktop：AI 服务与 GUI 模型端到端实施方案

**版本：DEV-SPEC v1.0 · 日期：2026-10-08（Asia/Shanghai）**  
**用途：交给开发 Agent 实施、评审与验收。产品实现状态：待开发；产品用例状态：NOT_RUN。**

本方案将已经讨论的 `AiService + GuiAiProvider + GuiExplorer + Runtime` 分层细化为可实施工程合同。页面、接口、数据结构、迁移、故障处理、测试和验收属于同一套交付要求。本文的具体字段、限制值和新增命令是本轮确定的开发建议；源代码状态与用户既定架构另列来源，不能将建议误读为仓库已经实现。

## 00. 开发 Agent 从这里开始

### 00.1 交付包阅读顺序

1. 阅读本文件，确认目标、依赖方向、状态机和 G0 前置门槛。
2. 阅读 `docs/contracts.md`、`contracts/operation-catalog.md` 和 `contracts/operations.json`，以最终交付的 JSON Schema、操作目录和本文语义共同约束实现。
3. 阅读 `docs/wireframes.md`，打开 `wireframes/index.html`；W01–W08 的控件与错误状态都需要实现。
4. 阅读 `docs/test-and-acceptance.md`、`tests/cases.csv`；每个工作项提交对应测试和证据。
5. 按 `AGENT_START_HERE.md` 的任务顺序实施。现有仓库已有同职责模块时复用；先提交真实现状和差异，再进行结构迁移。

若发现本文、Schema、操作目录或测试之间冲突，**先补同一版本的契约修正及回归夹具，再继续依赖该字段的实现**。不能各模块独立选择不同含义。外部用户最新明确指令优先于本方案；代码中的旧两仓维护说明不覆盖已确认的单仓收拢方向。

### 00.2 本次交付完成什么

交付完整设计、可以运行的契约校验与模拟上游、可点击线框图，以及待实施的产品验收用例。真实 AgentDesktop 应用、Swift/C# 实现和系统输入隔离仍需开发 Agent 在目标机完成。模拟模型服务只提供测试上游，不是生产 `AiService`，也不操作桌面。

### 00.3 已固定的产品决策

| ID | 决策 | 实施含义 |
|---|---|---|
| D01 | AgentDesktop 是唯一目标代码仓库 | 将所需 2ndscreen 资产并入本仓；最终包不依赖另行维护的 2ndscreen 产品或 TS task-runtime。 |
| D02 | 原生 Runtime：macOS Swift、Windows C# | 共用语义、Schema、夹具和验收；不增加永久 TS 宿主。 |
| D03 | AiService 是共享的模型调用服务 | 配置、凭据解析、协议、取消、预算与调用记录有一份权威实现。 |
| D04 | GuiAiProvider 只返回 Proposal | 无截图句柄、输入句柄或自授执行权限。 |
| D05 | GuiExplorer 管局部循环 | 观察、有限推理、提交动作、等待、重新观察与验证。招聘长程规划留在 BOSS。 |
| D06 | Runtime 执行器掌握真实输入 | API、CLI、MCP、回放与探索进入同一个控制权、目标校验与回执路径。 |
| D07 | 每个 run 固定配置绑定 | 修改默认配置只影响新 run；账号撤销会使旧授权失效。 |
| D08 | 必需图像和动作语义不能被兼容降级丢弃 | 缺少视觉或动作协议能力时明确失败；不删图、不静默过滤未知动作。 |
| D09 | 推理重试与动作重做分开 | 上游错误不能触发已发送动作的自动重放；unknown 保持未知并进入处理流程。 |
| D10 | 无模型仍可使用桌面底座 | 已支持的直接观察/输入及可确定性验证的回放继续可用。 |

其中 D01、D02、D04–D06、D09–D10 继承用户架构基线；D03、D07–D08 在本轮细化。[S01](#source-s01)

## 01. 现状、来源与开发范围

### 01.1 已核对的源代码快照

| 仓库 / 材料 | 核对版本 | 已确认的事实 |
|---|---|---|
| 架构 HTML | FINAL v1.0，文件版本 2 | 原生 Runtime、GuiExplorer/GuiAiProvider、统一执行、按 run 隔离、旧路径退出。 |
| `szrunworld/agentdesktop` | `91cfd09a9c0213baf35e8191f135319db93a29f1` | 产品还通过 SwiftPM 精确依赖 2ndscreen 0.2.0；有产品 CLI wrapper 和 product control.sock。 |
| 包内旧引擎依赖 | `7a9615406b4bbc2fcf09224a30667404b4765ecb` | ControlProtocol 是每个本地 socket 连接一条 JSON 请求、一条 JSON 回复；请求字段为 command。 |
| 旧模型迁移资产 | `da5677c2be421dc2d35cdda5cdf66b7134f6a381` | Swift 有多模态 Chat Completions 与 UI-TARS 解析；TS 有宿主持钥、取消、用量 unknown 等语义。 |
| `farion1231/cc-switch` | `f9db9f7056cbe7f972cdc02644722002316866b9` | 应用级 Provider 配置、模型接入、配置投影、代理和故障转移实现可参考。 |

源码来自静态读取，不代表本方案已经构建运行。[S02](#source-s02) [S03](#source-s03) [S04](#source-s04) [S05](#source-s05)

先前提到的独立 CLI 规划文件本轮未能读取；本方案以可访问的架构 HTML、当前产品 README 与 ControlProtocol 为接入依据。下列 `ai` / `gui` 命令为本次新增设计，实施时对照当时最新 CLI 分支合并，保留既有可用命令。

### 01.2 V1 交付边界

| 范围 | 必须交付 | 边界 |
|---|---|---|
| 连接与凭据 | 连接 CRUD/禁用/软删除，凭据创建与轮换，版本冲突 | V1 只实现 `openai_chat`；其他协议可在类型中预留，但 UI 不可假装可用。 |
| 模型与 GUI 配置 | 模型发现/手填、model profile、GUI profile、默认选择、能力证据 | 模型列表不等于 GUI 可用；UI-TARS 适配按实际模型配置验证。 |
| GUI 推理 | 文本+图片输入、完整响应解析、一个标准建议 | `fixture_json_v1` 只在测试构建/测试模式使用。 |
| 探索执行 | 有界循环、新观察验证、取消、结果可追溯 | G0 原生执行边界通过后才能启用真实输入。 |
| 可靠性 | 版本绑定、有限候选、预算、unknown、计量、恢复 | 非流式 `stream:false` 是 V1 正式路径；不承诺跨协议无损转换。 |
| 页面与 CLI | W01–W08、JSON CLI、同一配置服务 | 页面框架是现有 App 设置/诊断界面的扩展，不新增完整 Agent 市场。 |
| 平台 | macOS 端到端主验收；Windows 对等实现任务与独立验收 | Windows 未通过 G6 时明确标记未支持，不能借用 macOS 的验收结论。 |

本地 HTTP 模型网关、外部 Claude/Codex 配置接管、OAuth 订阅账号导入、公共 Agent 市场、多组织远程管理、模型训练、任意原生 computer-use 工具转换不构成 V1 完成条件。未来加入时复用 AiService，并单独版本化能力。

### 01.3 业务范围

首条演练使用包内中立表单：填写本地字段、点击测试按钮、读取本地状态。BOSS 可以在下一阶段通过相同 Runtime API 委托局部 GUI 目标，但候选人、沟通对象、业务限额、外发授权和业务结果判断仍归 BOSS。`run_unit` 对 external-submit、文件类条件和旧内置业务 page 条件的边界继承既定文档；本方案没有将这些能力自动打开。[S01](#source-s01)

## 02. 一条端到端用户流程

| 步骤 | 用户 / 系统行为 | 调用及持久化结果 | 可见结果 |
|---|---|---|---|
| E01 | 用户打开设置，查看 AI 连接 | `ai.connections.list` | W01 空状态或连接列表。 |
| E02 | 新建连接，录入 API 凭据 | `ai.connections.create`；先完成凭据写入再激活连接 | W02 显示已保存、revision、脱敏凭据。 |
| E03 | 获取或手填模型 | `ai.models.refresh/list`；保存 model profile | 型号可选；发现失败不阻断手填。 |
| E04 | 创建 GUI profile | model+adapter+prompt/parser/coordinate version+limits | W03 显示未验证状态。 |
| E05 | 运行四层能力测试 | `ai.tests.start` → operationId → get | W04 分层结果、失败原因、测试版本。 |
| E06 | 设为默认或为一次 run 指定配置 | 默认指针 CAS；不修改现有 run | W03 提示对新任务生效。 |
| E07 | 选择 Desktop、中立目标、允许动作并启动 | `gui.runs.start`；绑定配置快照、请求去重 | W05 → W06，返回 runId。 |
| E08 | Explorer 获取观察并调用 Provider | Observation → AiService → Proposal | 记录 inferenceAttempt，不产生输入。 |
| E09 | Runtime 校验并执行 | 校验控制权、generation、snapshot、目标与动作；写 ActionReceipt | W06 显示实际动作状态。 |
| E10 | 新观察验证目标 | 成功条件满足才写 succeeded / UnitResult | W06 结果和证据；模型 finish 本身不构成成功。 |
| E11 | 用户停止、上游错误或结果未知 | cancelling / failed / waiting_user；保留证据 | W07 显示下一步与可用控制。 |
| E12 | 查看用量与导出诊断 | `ai.usage.summary`；按 attempt 聚合、脱敏 | W08 分开显示模型尝试与实际动作。 |

开发验收必须覆盖 E01–E12，不能只展示“API key 保存成功”或“模型返回了文本”。

## 03. 模块、依赖和代码落点

### 03.1 推荐 SwiftPM targets

以下是目标目录，不是对当前仓库已有目录的声明。

| Target / 目录 | 依赖 | 实现内容 |
|---|---|---|
| `Sources/AgentDesktopContracts` | Foundation | 版本化 DTO、错误、状态、Observation/Proposal/Receipt、GUI ports。 |
| `Sources/AgentDesktopAI` | Contracts | 配置服务、SQLite store、CredentialStore、ModelCatalog、AiService、OpenAIChatTransport、预算和调用记录。 |
| `Sources/AgentDesktopGUI` | Contracts、AI | UITars codec、GuiAiProvider、GuiExplorer、能力测试协调；通过 ports 访问观察/执行。 |
| `Sources/AgentDesktopRuntime` | Contracts、AI、GUI、Core | composition root；执行权、会话、Desktop、IPC、cancel 与恢复；实现 GUI ports。 |
| `Sources/AgentDesktopCore` | 平台系统库 | 从 2ndscreen 迁入的原生显示/窗口/输入/AX/OCR 资产。 |
| `Sources/AgentDesktop` | Runtime、设置 UI | 已有 App 宿主、生命周期、菜单、设置及诊断窗口。 |
| `Sources/AgentDesktopCLI` | Contracts、本地客户端 | 参数解析、IPC、JSON 输出和 exit code；不直接实例化 InputEngine。 |

`GUI` 不导入 Runtime 实现以避免循环依赖。`ObservationService`、`ScopedExecutor`、`GoalVerifier` 的协议在 Contracts/内部接口 target 中声明，由 Runtime 提供实例。只有 Explorer 获得受限执行 port，GuiAiProvider 构造函数仅接受 AiService、codec 和纯数据依赖。

首期可将小文件集中在同一 target 的子目录，但依赖约束必须在 import、构造函数和测试中保持可检查。新目录合入前读取仓库当前 `AGENTS.md` 和构建脚本；对旧“两仓维护、禁止携带引擎代码”的说明作与用户新决定一致的正式更新，不能仅绕过检查脚本。

### 03.2 Swift 实现方式

| 部件 | 具体方案 |
|---|---|
| 并发 | `AiConfigurationStore` actor 串行化写入；每个 run 独立 `GuiRunActor`；网络 await 不能持有全机执行锁。 |
| 网络 | 使用异步 URLSession；注入 transport/clock/random 以便确定性测试；统一 redirect 拒绝与 deadline。 |
| 凭据 | macOS Keychain generic-password，service 前缀 `com.agentdesktop.ai`，account 为随机 credentialId；不启用云同步。 |
| 存储 | SQLite + migrations；事务维护当前版本/默认指针/幂等记录；旧版本快照不可原地修改。 |
| GUI UI | 在现有原生 App 中增加设置和诊断窗口；ViewModel 只调用 ApplicationService；机密输入只存在于录入过程。 |
| 执行门槛 | 复用同一个原生执行器；禁止在 Provider 或 UI 中新增 CGEvent/AX input 旁路。 |
| 时间 | 持续时间和预算使用可注入单调时钟；ISO8601 时间仅用于接口和审计。 |

### 03.3 Windows 实现方式

Windows 以 C# 实现相同 Contracts / AI / GUI / Runtime 分层。新项目建议使用 .NET 10 LTS，并把实际 SDK/patch 锁定于 `global.json` 与依赖锁文件；微软当前支持表将 .NET 10 列为 LTS。[S13](#source-s13)

HTTP 使用 HttpClient、CancellationToken；配置写入有事务；机密使用 DPAPI `CurrentUser` 加密后保存到当前用户受 ACL 保护的应用目录；本地 IPC 使用当前用户 ACL 的 NamedPipe。DPAPI CurrentUser 的保护范围是当前用户，不是同用户恶意进程隔离。[S14](#source-s14)

平台自有 UI 可用既有框架实现 W01–W08；JSON enum 的 wire 值必须与 Swift 相同。Windows 不能通过建立一个永久 Node 代理规避原生实现目标。

## 04. 数据模型与不变量

字段和枚举的机器可读定义位于 `contracts/domain.schema.json`。下表说明生命周期和实现不变量；字段名称以最终 Schema 为准。

| 对象 | 关键字段 / 关联 | 不变量 |
|---|---|---|
| AiConnection | connectionId、revision、name、protocol、baseUrl、credentialRef、state、timeoutMs | 端点、协议、凭据身份按版本引用；配置中不保存原始 key。 |
| AiModelProfile | modelProfileId、revision、connectionId/Revision、modelId、requestOptions、capability evidence | 同一个供应商连接可以有多个模型；modelId 精确保留大小写。 |
| GuiAiProfile | guiProfileId、revision、modelProfileId/Revision、adapter/version、prompt/parser/coordinate version、limits、fallback refs | GUI 协议和请求协议分离；备用配置最多 1 个，且必须完整解析。 |
| DefaultGuiProfile | revision、guiProfileId 或 null | 默认指针有自己的 revision；不能用 GUI profile revision 替代 CAS。 |
| GuiRunBinding | run/session/Desktop、goal、verification、候选完整快照、policy revision、初始 generation | 原子解析整个引用图；开始后不重新追踪全局 default。 |
| Observation | snapshotId、Desktop/窗口/进程启动身份、捕获时间、尺寸、几何版本、图像变换 | 可访问元素证据由 Runtime 与同次观察内部关联，不新增未经定义的 wire 字段；不能凭时间新就忽略窗口更换。 |
| GuiProposal | proposalId、kind、snapshotId、run generation、动作或控制字段、provenance | 恰好一个动作/控制建议；不包含可由模型赋值的执行授权。 |
| InferenceReceipt | requestId、inferenceAttemptId、run/step、snapshot、候选、requestedModelId/actualModelId、usage、时间、终态 | 对外调用回执；内部 ledger 可称 InferenceAttempt。包含失败尝试；unknown 用量不是 0。 |
| ActionReceipt | actionId、proposalId、snapshotId、目标、输入路径、投递/确认状态、证据 | Runtime 产生；submitted 不等于 confirmed，更不等于业务成功。 |
| GuiRun / goalVerification | runId、终态、原因、最新观察、验证结果、最新两类回执 | 对外查询对象；既有内部 UnitResult 由它映射，不能在 wire 上另创未定义 DTO。模型完成建议必须经过新观察验证。 |

### 04.1 配置版本和引用

- `revision` 为正整数。update 使用 expectedRevision；不匹配返回 CONFIG_CONFLICT 和当前版本号，不回显密钥。
- model profile 固定 connectionRevision；GUI profile 固定 modelProfileRevision；保存新版时，服务返回实际引用版本。
- 修改上游 connection 后，已有 profile 不悄悄改指向。UI 显示“存在新连接版本”，用户通过编辑 profile 显式采纳并重新测试。
- 修改已选中的 GUI profile 会影响随后启动的默认 run，因为 default 指向 GUI profile 身份并在 start 时解析当时 current revision；已经创建的 run 保留之前快照。
- 禁用阻止新绑定，既有有效绑定可继续。凭据撤销/轮换导致旧授权失效；下一动作之前必须检查，不得使用缓存凭据继续生成新建议。
- 删除采用 tombstone；有活跃运行或当前引用时返回 RESOURCE_IN_USE。先改 default、迁移引用/结束运行，再删除。历史快照与回执保留。

### 04.2 图像与模型能力

能力状态区分 `unknown / declared / verified / failed`；证据记录测试时间、连接/模型/profile revision、adapter、测试素材版本、结果。一次模型列表查询不能设置 `vision=verified`。连接/模型/GUI adapter 的相关字段更新，使依赖它们的旧验证证据失效。

V1 的生产 GUI adapter 为 `uitars_v1`；`fixture_json_v1` 是中立测试协议，生产默认配置不得误选。UI-TARS 名称表示被明确测试的提示词/动作格式适配，不保证任意使用该模型名字的端点都兼容。

## 05. 本地 IPC 与应用服务接口

### 05.1 传输设计

继续使用产品现有 `~/Library/Application Support/AgentDesktop/control.sock`。本轮扩展版本化 decoder，识别 `schemaVersion=agentdesktop.ai/1` 的新请求；没有该字段的请求进入旧 ControlRequest 兼容 decoder。两条解码路径最终调用同一个 Runtime，不能产生两个输入执行者。[S02](#source-s02) [S03](#source-s03)

每个连接发送一个 UTF-8 JSON 对象加 LF，服务返回一个 JSON 对象加 LF 后关闭。帧大小最多 1,048,576 字节，包含末尾 LF；不允许批量数组、重复 JSON key、非有限数值或多条请求混在一个帧中。超过大小应在读取过程中终止，不等完整分配后才校验。无 JSON 日志混入响应。

长任务快速返回 runId/operationId，调用方使用 get/events 轮询。V1 不改造为持续推送 socket，也不要求新建 HTTP 监听端口。

目录权限 0700、socket 0600；验证 peer user，并使用原子宿主锁避免多个实例同时接管 endpoint。Windows NamedPipe 使用等价当前用户 ACL。`runtime.capabilities` 返回 schemaVersions、implementedAiProtocols、verificationPredicates、guiAdapters、actions、features 和 limits；客户端先协商再显示可用控件。新版本的 32 个命令组成同一版本合同；未支持的版本或命令分别返回 UNSUPPORTED_SCHEMA / UNSUPPORTED_COMMAND。

当前产品按同用户可信 CLI / Agent 运行，不宣称同 UID 恶意程序间的 OS 沙箱隔离。Runtime 的 session/目标范围来自服务端的有效会话和控制权；调用 JSON 中的 accountId、Desktop 名称或伪造的 lease 字段不能自行授予权限。

`gui.runs.start.sessionId` 可省略。显式提供时，Runtime 校验现有 session 的所有者、Desktop 与目标范围；省略时只允许可信的 owner UI/CLI，由 Runtime 创建仅用于本 run 的 session，并在终态释放。目标窗口必须由 Desktop/session 的受支持绑定确定；缺少绑定、多个歧义目标或 backend 不支持时拒绝启动。普通一次请求完成后的 socket 关闭不等于 session 断开，不能取消已受理的 run。显式 session 的撤销、Desktop 关闭和 Runtime epoch 改变按失效路径处理。

### 05.2 请求与响应

```json
{
  "schemaVersion": "agentdesktop.ai/1",
  "requestId": "11111111-1111-4111-8111-111111111111",
  "command": "ai.connections.list",
  "params": { "limit": 20 }
}
```

成功统一为 `{schemaVersion, requestId, ok:true, result}`；失败统一为 `{schemaVersion, requestId, ok:false, error:{code,message,retryable,details?}}`。所有返回的 credential 信息必须是引用或脱敏摘要。只有凭据写入请求在安全输入阶段携带 key，错误 details 和日志不复制请求体。

已合法解析的请求必须原样关联 requestId。只有无法关联的非法帧，且错误为 VALIDATION_ERROR、UNSUPPORTED_SCHEMA 或 IPC_FRAME_TOO_LARGE 时，错误响应才允许 requestId=null。不得用 null 隐藏普通业务请求的关联信息。

请求可带 `context.deadlineAt` 和 `context.idempotencyKey`。deadline 到服务端后转成单调剩余时长；不能凭修改系统时钟增加已有预算。

### 05.3 操作目录

完整必填参数、成功结果和错误枚举在 `contracts/operations.json` 与 `rpc.schema.json`。下面列出业务作用，实施与测试应逐项对应。

| 组 | 命令 | 关键语义 |
|---|---|---|
| 能力 | runtime.capabilities | 报告实现状态和限制；未实现协议明确不可用。 |
| 连接 | ai.connections.list/get/create/update/disable/delete | CAS、软删除、依赖检查；create 可写初始凭据。 |
| 凭据 | ai.credentials.rotate | 独立事务操作；撤销旧 identity、激活新 identity、失效旧调用。 |
| 模型发现 | ai.models.list/refresh | 每连接缓存；失败可保留旧缓存并标 stale；允许手填。 |
| 模型配置 | ai.modelProfiles.list/get/create/update/disable/delete | 模型参数与连接版本引用。 |
| GUI 配置 | ai.profiles.list/get/create/update/disable/delete | GUI adapter、坐标协议、限额、候选引用。 |
| 默认 | ai.profiles.default.get / ai.profiles.setDefault | 使用 expectedDefaultRevision；非空目标同时核对 expectedProfileRevision。 |
| 能力测试 | ai.tests.start | 只用固定测试素材；返回 operationId，不产生桌面输入。 |
| 异步操作 | ai.operations.get/cancel | get 幂等；cancel 受理和终态分开。 |
| GUI run | gui.runs.start/get/cancel/events | start 去重；绑定配置；events 使用单调序号 cursor。 |
| 用量 | ai.usage.summary | 只聚合当前调用者范围；已知值、未知次数、估算成本分列。 |

list 默认 20、最多 100 条；cursor 不透明且绑定过滤条件。events 以 afterSequence 获取大于该序号的记录，允许客户端重复读；序列号用于去重。事件保留范围不包含 cursor 时返回 EVENTS_CURSOR_EXPIRED，客户端先 get 完整快照再从最新游标继续，不能伪装没有事件。事件 payload 为 Schema 定义的受控字段，不包含截图正文或机密；公开接口暂不提供任意原始 trace 下载。

### 05.4 幂等与并发写

create、rotate、tests.start、runs.start 和配置修改请求都需要 mutation idempotencyKey。按 caller scope + command + key 存储语义摘要和结果，保留至少 24 小时；活跃 operation/run 对应记录不能提前过期。

- 相同 key + 相同语义请求：返回同一对象/run/operation，不再次扣请求预算或调用模型。
- 相同 key + 不同语义：IDEMPOTENCY_CONFLICT。
- mutation 执行中重复请求：返回原 operation 状态或明确 in-progress 结果，不能重复启动。
- 对包含 secret 的请求，内部摘要使用本机密钥 HMAC，不保存原文请求，不公开摘要；不能在日志中对比两个 raw key。
- 比较语义摘要时排除 requestId、deadline 等请求追踪字段；保留实际修改内容、expected revision 和 secret 的内部摘要。
- 崩溃恢复发现 mutation 状态为 pending 时按该操作的恢复规程完成或失败，不能简单删除幂等记录后重做可能产生副作用的操作。

### 05.5 错误处理

错误分成配置/授权、能力、推理、执行、生命周期几类。具体 code 以 Schema 为准。UI 需要为 CONFIG_CONFLICT、RESOURCE_IN_USE、CREDENTIAL_REVOKED、CAPABILITY_MISMATCH、UPSTREAM_UNAVAILABLE、DEADLINE_EXCEEDED、CANCELLED、INVALID_ACTION、STALE_OBSERVATION、ACTION_OUTCOME_UNKNOWN、AUDIT_UNAVAILABLE 提供可解释状态。

HTTP body 可能回显请求或凭据，对外错误只含受控字段。`retryable` 表示这类操作是否有候选恢复途径，不是客户端可以自动重放整个 GUI run 的授权。客户端只有在同 idempotencyKey 下重取状态，或由服务端策略执行受限推理重试。

## 06. 内部设计接口与实现顺序

### 06.1 AiService

接口职责是对固定候选执行一次有限模型调用，具体内部声明见 `contracts/interfaces/AiGuiContracts.swift` 和 `.cs`。request 是已构造的有限多模态内容；候选已固定端点/模型/credential identity；GUI context 带 runId、stepIndex、inferenceAttemptId、deadline 和预算资格，诊断 context 见 18.1。

```swift
protocol AiService: Sendable {
    func infer(_ request: AiInferenceRequest,
               resolvedModel: AiResolvedModel,
               context: AiCallContext) async throws -> AiInferenceResult
}
```

V1 requestOptions 只接受 temperature 和 seed，不默认发送厂商专用 thinking 等字段。需要该类字段的端点，先扩展并版本化合同、增加适配与测试，再在 UI 开放；当前传入未知字段返回 VALIDATION_ERROR，不能悄悄转发。

调用顺序必须固定：

1. 校验调用者范围、run generation、候选授权和限制。
2. 检查凭据 identity 未撤销，解析 key；endpoint 与该 identity 的配置版本绑定。
3. 在 durable ledger 中预留 attempt 和资源额度，再发 HTTP 请求。
4. transport 仅编码当前协议支持的字段；加入 model/options；reject redirect。
5. 完整读取有限响应；解析 provider 错误、实际 model、finish reason、usage；响应大小上限 2 MiB，超过返回受控错误。
6. 记录 attempt 终态，包括失败、超时、取消和未知 usage。
7. 归还未使用资源；再次检查 generation。已取消的结果可以作为审计事件落盘，但不得进入下一动作。

网络调用不能在 @MainActor 上阻塞，也不能使用 `DispatchSemaphore.wait()` 等待 URLSession。已有同步 `VisionModel` 是迁移来源。[S04](#source-s04)

### 06.2 GuiAiProvider

接口形状：

```swift
protocol GuiAiProvider: Sendable {
    func suggest(_ input: GuiInferenceInput) async throws -> GuiInferenceOutput
}
```

它只接收指定 Observation、有限历史和允许的动作。构造依赖不含 screen、InputEngine、ControlServer、窗口对象或能够重新捕获任意屏幕的闭包。输入中的截图引用由授权观察服务解析，不能让模型返回的路径决定读哪个文件。

生成顺序：构建版本化 GUI prompt → 加入当前截图和必要历史 → AiService → action codec → schema 校验 → 坐标解码 → 带来源的 Proposal。模型输出中的未知动作、重复动作、额外授权字段或不可解释参数都拒绝。生产 GUI Provider 不执行 `eval` 或由模型构造的脚本。

### 06.3 GuiExplorer

应用服务入口为 `GuiExplorerService.start(binding:)`，取消入口为 `requestCancellation(runId:)`；内部工作任务执行已有 run_unit 所需的局部循环。goal 和 verification 来自 binding；scoped ports 由 composition root 注入。每次 run 独立历史、步数、预算与终态。

```text
获取新的 Observation
如果确定性后置条件已经满足：返回成功证据
如有可用的已验证流程：受控回放，再观察并验证
否则在预算内循环：
  检查取消、deadline、控制权、候选与剩余额度
  向 GuiAiProvider 请求一个完整 Proposal
  检查 generation、snapshot、动作范围
  action：交给统一执行器，记录回执
  wait：在可取消定时器中有限等待
  finish：只触发新观察和验证
  needs_user：写 waiting_user 并返回等待原因
  再获取 Observation 并验证目标
未达成且预算耗尽：failed，保留最后观察和原因
```

确定性回放和验证成立时，模型调用数应为 0。流程学习只读取真实执行轨迹及验证证据；不直接把未执行 Proposal 作为可回放动作。

### 06.4 V1 完成条件与验证接口

`gui.runs.start` 必须携带 `verification`，本版本只支持 `{kind:"element_text_equals",role:"static_text",text:"…"}`。这是调用者提交、Runtime 验证并固定到 binding 的条件；模型不能写入、替换或放宽它。`GoalVerifier.evaluate(observation, boundVerification)` 只读取授权窗口的可访问元素，使用跨平台规范化后的角色 `static_text` 和完整文本相等比较；不做模糊匹配，也不在所有桌面中搜索同一句话。

角色映射由各平台 Observation adapter 完成，取可访问静态文本节点；不能把整个窗口拼接字符串当作一个静态文本节点。相同窗口内多个完全相同文本节点可满足“存在匹配静态文本”，但不能代替更复杂的业务状态验证。目标窗口、进程启动身份或 layout epoch 变化须重新校验绑定。当前 backend 不能可靠提供该谓词时，`runtime.capabilities.verificationPredicates` 不公布它，start 返回 CAPABILITY_MISMATCH。

中立流程的 goal 固定为“在指定中立表单的姓名中输入 Ada，然后点击应用”；fixture URL 的 case 标签为 `MAC-001-A`。预期条件为 `已保存：Ada / MAC-001-A / 提交次数 1`。计数器、备注等额外控件不属于此 happy path 的完成承诺，它们用于其他输入/重复动作测试。收到模型 finish 后必须获取更晚的 Observation，记录 verifierId、checkedAt、observationId；不匹配返回 VERIFICATION_FAILED 或在剩余预算内重新观察，不能直接 succeeded。

### 06.5 统一执行器

在每次输入前重新验证：有效控制能力、Desktop、真实冲突域、holder generation、进程启动身份、窗口身份、几何版本、snapshot 新鲜度、动作类型与参数、deadline、run 是否取消。

执行队列按真实输入冲突域有序；同 Desktop 有序，不同独立 Desktop 可并发。共享同一 PID/应用输入资源时必须用真实冲突域限制，不能只给两个 displayId 就宣称隔离。

UI 点击“停止”可以迅速使新的动作资格失效；已经进入 OS 输入路径的动作需要回执和收尾，不能仅 cancel 一个 Swift Task 就立即释放给新运行。

## 07. 运行状态机与异常恢复

### 07.1 状态定义

| 状态 | 含义 | 允许进入的下一状态 |
|---|---|---|
| queued | run 已创建，等待作用域资源 | observing、cancelling、failed |
| observing | 获取/检查指定目标观察 | inferencing、verifying、cancelling、failed |
| inferencing | 模型 attempt 进行中 | validating、waiting_user、cancelling、failed |
| validating | 检查 Proposal / 快照 / 权限 | executing、observing、verifying、waiting_user、cancelling、failed |
| executing | 原生执行器处理动作 | observing、verifying、waiting_user、cancelling、failed |
| verifying | 使用新观察判断后置条件 | succeeded、observing、waiting_user、cancelling、failed |
| waiting_user | 缺授权、需处理或结果未知 | cancelling；外部 Runtime 确认资源安全后可结束本 run，不自动重做 |
| cancelling | 已禁止后续输入，正在取消/收尾 | cancelled；未知在途动作仍需明确等待原因和隔离状态 |
| succeeded | 新观察验证通过 | 终态，不再产生动作 |
| failed | 无法达成或预算/配置失败 | 终态，不再产生动作 |
| cancelled | 取消完成，输入收尾已确认 | 终态，不再产生动作 |

有限 wait 作为 validating 后的可取消等待，再回 observing；可保留 wait 事件而不新增 run 状态。实现所有转换时使用 compare-and-set generation，不能以异步回调先后顺序覆盖终态。

### 07.2 取消协议

cancel 接口立即设置 cancelRequested、递增 `GuiRun.currentGeneration`，并返回当前 state 与 accepted 标识。binding.runGeneration 是启动时的初始值，不能修改不可变 binding。Observation 和 Proposal 携带当时的 currentGeneration，输入前与当前值比较。cancel 的受理不等于已经 terminal cancelled。

在模型请求中：取消对应 URLSession task/HttpClient 请求；迟到响应只记录 discarded，输入计数保持不变。在执行前：已排队 Proposal 失效。在输入中：记录当前 actionId，由 Executor 确认完成/未发送/未知再处理租约。

若动作结果未知，UI 必须显示“停止请求已收到；有一项输入结果尚未确认”。保留或隔离冲突域，直到 Runtime 的既有收尾/人工确认机制证明可安全释放。V1 不新增一个绕过该机制的 `resume` 按钮或 RPC；重新运行必须使用新观察和新的授权条件。

状态选择固定为：未请求取消时，unknown → waiting_user / ACTION_OUTCOME_UNKNOWN；已经受理取消时保持 cancelling，waitingReasonCode=ACTION_OUTCOME_UNKNOWN，安全核对后才 cancelled。不要在 cancelled 后再回到执行态，也不要在等待未知输入时悄悄清除取消资格失效。

### 07.3 重试矩阵

| 错误 | 同一 step 的自动行为 | 实际动作 |
|---|---|---|
| 429 | 在 deadline 内尊重 Retry-After；候选和次数受限 | 未提交前才重试推理。 |
| 5xx、网络断开、连接超时 | 可尝试下一个允许候选；最多 2 次总 attempt | 不重放此前已完成步骤。 |
| 401/403、credential revoked | 失败并显示认证原因 | 不自动跨账号寻找可用凭据。 |
| 不支持图片/协议/GUI codec | CAPABILITY_MISMATCH | 不删图、不静默转换未知工具。 |
| malformed JSON / invalid action | 本轮失败或按明确上层策略重新观察后结束 | 不把不完整输出送执行器；V1 不做自动“修复再执行”。 |
| stale snapshot | 重新观察；消耗步数/时限 | 不对旧坐标直接点击。 |
| 用户取消 | 中止 attempt，不记为供应商健康故障 | 迟到 Proposal 无效。 |
| ActionReceipt unknown | waiting_user / 隔离冲突域 | 不自动再次 click/type/submit。 |

基础策略为一次 step 最多 2 次模型 attempt（含第一家），run 总共最多 30 次；不能把“同一家重试 2 次”和“候选 2 家”乘成 4 次。备用 GUI profile 必须有兼容当前任务的图像、动作、坐标与数据范围证据。

### 07.4 崩溃与重新启动

run 在创建、准备输入、收到回执、终态时持久化关键事件。若进程在输入后、确认前退出，重启时恢复为待处理 unknown；不得根据最后一条日志重新发送动作。所有旧窗口句柄、lease 和 snapshot 在新 runtime epoch 下失效。

配置恢复允许恢复引用和历史；动作恢复只允许重新观察及确定结果，不能回放历史 trace。证据文件缺失时结果标 missing，不生成替代“成功证据”。

## 08. 坐标、快照与 GUI 输出合同

### 08.1 三个坐标空间

1. **模型输入画布**：经过 resize/crop/letterbox 的图片，像素尺寸明确。
2. **源截图像素**：Proposal 的 canonical x/y；与 snapshotId 一起使用。
3. **Desktop 逻辑坐标及 backend 坐标**：由 Runtime 将源像素转换；平台 backend 处理原点方向和窗口偏移。

每个图像变换保存版本和完整参数。模型协议明确是 normalized_1000、image_pixels 等之一；不通过“数值是否大于 1”猜尺度。坐标有效域为 `[0,width)`、`[0,height)`；NaN/Infinity、越界和 letterbox 留白内的点拒绝，不静默 clamp。

### 08.2 变换公式与验收样例

仿射数组固定为 `[a,b,c,d,tx,ty]`：`x'=a*x+c*y+tx`，`y'=b*x+d*y+ty`。

例：源截图 2560×1600，裁剪 `(x=400,y=200,w=1600,h=1000)`，缩放为模型画布 800×500，无 letterbox。模型 normalized_1000 给出 `(500,500)`：

- 模型画布点为 `(400,250)`；
- 回到源截图为 `(400+400*2, 200+250*2)=(1200,700)`；
- 源截图到 Desktop 逻辑坐标使用 `[0.5,0,0,0.5,0,0]`，得到 `(600,350)`；
- 若 backend 的全局 Desktop 原点是 `(-1280,100)`，最终为 `(-680,450)`，仅由 backend 使用，不回退到宿主屏幕。

纯数值夹具误差要求 ≤1e-6 像素。真机验收用命中目标元素的 hit-test/计数/回执证明定位，不用固定网络时延替代。

### 08.3 Snapshot 有效性

捕获时记录 app identity、PID start identity、window identity、window frame/layout epoch、Desktop binding epoch 和图像变换。输入前至少确认这些条件仍匹配。时间 TTL 是附加条件：建议默认 2 秒、允许按后端更严设置；超过 TTL 重新观察。即使时间未超过，只要窗口替换、目标移动、布局 epoch 改变，也必须失效。

为了避免在截图后等待模型导致所有请求自然过期，最终输入校验允许在同一目标上获取快速新观察并验证定位条件仍成立；这个 revalidation 必须产生明确证据，不能只刷新 timestamp。若目标定位无法重证则重推理。

### 08.4 动作范围

V1 只接受 click、type、key、scroll，以及 wait/finish/needs_user 控制建议。click 默认左键；key 使用 Schema 中明确命名的 key 集合；scroll 的方向和像素量具有固定语义；type 最大长度和字符规则在 Schema 中校验。drag、多动作串联、任意脚本、任意路径操作在此版本拒绝。

动作字段仍受当前后端 capability 和 run 允许列表限制。schema 合法不等于执行允许。日志默认不记键入正文；普通 UI 只显示字符数/目标摘要，需要查看敏感内容时走已有明确的证据访问界面。

## 09. 预算、用量和记录

### 09.1 V1 默认值与硬上限

本版本默认等于下列服务端硬上限；用户 profile 可调低，不可调高。将来提升需修改 policy version、测试与容量验证。

| 配置 | 默认 / 上限 | 计数方式 |
|---|---|---|
| maxSteps | 20 | 每次进入 observe→suggest 决策轮消耗 1 步；wait/finish/needs_user 也计入。该步重试只增加 attempt。初始验证和动作后的纯验证不额外计步。 |
| maxWallTimeMs | 120000 | 从 run 创建时建立单调 deadline，包含排队和等待；达到后禁止新模型调用和新输入。 |
| maxModelAttemptsPerStep | 2 | 包含第一家与所有重试/备用候选。 |
| maxTotalModelAttempts | 30 | run 所有 step 总和，失败也计数。 |
| maxOutputTokens | 1024 | 每次请求显式传给上游；上游是否遵守另记录。 |
| maxWaitMs | 5000 | 单次 wait，可随时取消。 |
| maxScreenshots | 5 | 单请求历史截图数量上限。 |
| maxImageEncodedBytes | 8388608 | 一次请求所有图片 base64 payload 的 UTF-8 字节总和，不含 data URL 前缀和 JSON 开销。 |

图片预算等于上限应通过，多 4 字节应拒绝；本地 RPC 只传截图引用，因此 1 MiB IPC 帧上限与上游图像预算不冲突。历史压缩可丢弃更早截图，必须保留当前截图并记录裁剪策略；不得以 text marker 替代当前必需图像。

maxWallTimeMs 约束主动执行；到时中止自动工作。已经提交且结果未知的 OS 输入，其对账/隔离收尾可能超过该时间，不能为了让状态在 120 秒内变终态而提前释放控制权。界面此时显示停止处理中和原因，不继续计入新的模型或动作。

### 09.2 预算执行

调度器在请求开始前原子预留 attempt 名额，使用统一 deadline。两个并发任务可以独立发网络请求，但不能共享可变历史；连接级并发限制与 run 预算分开，等待连接额度也消耗 run 时限。

V1 强保证的是步数、请求次数、输入大小、输出请求上限和运行时间。上游未报告 token/计价信息时，用量为 unknown，不能显示“花费 0”。金额为估算展示，不声称是精确的账单硬限额。若启用 requireReportedUsage，缺失用量后停止下一次模型尝试并说明原因；已经发出的请求不能假设免费。

### 09.3 记录结构和去重

普通日志记录 run/step/attemptId、connection/model/profile revision、请求模型和返回模型、HTTP 分类、延迟、usage source、结果，不写 API Key、Authorization、Cookie、截图正文和键入正文。

输入回执与模型记录分别保存，通过 proposalId、inferenceAttemptId、runId+stepIndex 关联。统计以 inferenceAttemptId 去重；同一次事件重复接收不能重复累加。多个候选实际调用都应计入；UI 展示“2 次模型尝试 / 1 个动作”，不能只保留最后成功的模型。

若在发模型前写入 attempt ledger 失败，拒绝调用；若上游请求完成后的记账失败，保留待恢复记录并阻止下一次自动推理，不能继续无限执行且声称可追溯。执行器在输入前也必须写入 pending action；记录失败不得发送输入。

诊断导出使用受控 allowlist；证据截图默认按 run 私有目录存放，普通导出只带引用/哈希。用户主动包含图像的诊断包需清楚展示内容范围。V1 默认保留结构化元数据 30 天、诊断截图 7 天，可由明确配置调短；引用缺失应标记，不伪造。

## 10. 凭据、端点与持久化实现

### 10.1 端点规则

baseUrl 使用标准 URL parser：必须 HTTPS，或在本地模型选项开启时使用 HTTP loopback。HTTP 的 127.0.0.1、[::1]、localhost 需确认实际连接地址属于 loopback；不允许借 localhost 名称连接其他地址。

拒绝 URL userinfo、query、fragment；拒绝以 `/chat/completions` 作为 base 的重复拼接配置并给出修正提示。内部统一末尾 `/`，追加相对 `chat/completions` 保留已有 `/v1/` 或 `/api/v3/` 路径。不要使用会丢弃 base path 的绝对 `/chat/completions` 拼接。

V1 不开放任意自定义认证头。API key 使用当前协议的 Bearer 方式，由 transport 生成；redirect 一律拒绝，防止凭据被转发到未配置目标。测试服务地址与生产地址分别配置，不把测试场景控制头发送到生产。

### 10.2 凭据创建/轮换的恢复流程

SQLite 和系统凭据库没有一个跨两者的原子事务，使用明确的 pending/outbox 流程：

1. 事务创建 pending credential identity 与 mutation 记录；尚不可用于模型调用。
2. 把 secret 写入系统凭据库；失败则 mutation 失败并清理 pending。
3. 事务更新连接 revision 和 active credentialRef；轮换时把旧 identity 标 revoked，并写入 invalidation outbox。
4. 提交后应用 outbox，取消旧 identity 的进行中推理并使旧 generation 无动作资格。
5. 旧系统机密清理由幂等任务执行；即使清理暂失败，revoked identity 也不得解析使用。

崩溃在步骤 2 后、3 前：恢复程序清理无 active 引用的孤立 secret。崩溃在步骤 3 后、4 前：从 outbox 重放失效事件。任何中途失败都不能让 UI 显示完整成功而 Runtime 使用另一份密钥。

旋转旧凭据会影响使用旧 identity 的在途任务；W02 必须明确提示，W06/07 显示 CREDENTIAL_REVOKED 等原因。普通 metadata 编辑不应触发密钥替换；空密码输入表示“不修改”，不能覆盖为空。

### 10.3 SQLite 建议表

| 表 | 作用 / 约束 |
|---|---|
| ai_connections + ai_connection_revisions | 身份/current pointer 与不可变配置 JSON；联合键 (id,revision)。 |
| ai_model_profiles + ai_model_profile_revisions | 精确引用连接版本；更新不改写旧 revision。 |
| gui_profiles + gui_profile_revisions | 精确引用模型配置、codec 和 limits。 |
| ai_defaults | scope 为 current user/purpose=gui，pointer revision 单独 CAS。 |
| credential_identities | handle、state、created/revoked time；无 raw key。 |
| capability_tests | operation、目标版本、素材版本、分层结果、时间和错误。 |
| gui_runs | 状态、不可变 binding JSON、当前 generation、最后 sequence。 |
| gui_events | (runId,sequence) unique，kind、redacted payload。 |
| inference_attempts | attemptId unique，预留/开始/结束、候选、usage 与恢复状态。 |
| action_receipts | actionId unique，pending/submitted/confirmed/unknown 和证据索引。 |
| mutation_keys | scope+command+key unique，内部语义摘要、结果/operationRef、过期时间。 |
| outbox | 按序执行 credential invalidation 等提交后操作。 |
| schema_migrations | 版本、时间、脚本校验和。 |

使用外键和事务维护引用；history/table 与 keychain 清理分别处理。升级前备份数据库；恢复时保留 credential identity 的缺失状态，不将别台机器的引用自动绑定到本机任意同名 key。

## 11. 四层测试服务

`ai.tests.start` 固定使用版本化中立素材，返回 operationId。执行前展示将调用模型及最多尝试数；测试不读取当前桌面、不点击真实界面。

| 层 | 请求 | 成功条件 | 失败后的界面 |
|---|---|---|---|
| network | 对配置 base 的轻量探测 | 收到 HTTP 响应即可达；记录具体 status | 显示 DNS/TLS/超时等网络原因。 |
| auth_model | 一个极小模型请求 | 正确协议、认证成功、非空合法响应 | 显示鉴权/模型/协议原因，不能显示 GUI 可用。 |
| image_input | 固定测试图片和可验证问题 | 图片被保留，回答符合素材期望 | 视觉不支持或无法验证。 |
| gui_contract | 固定测试界面和目标 | 输出完整、动作类型/坐标合法且命中预期区域 | 显示解析/坐标/动作能力原因。 |

先运行必需前置层，失败时后续层标 skipped，不伪装 failed 或 passed。默认一次 operation 最多 3 次真实模型请求（auth/model、image、GUI），不做隐藏重试；总 deadline 不超过 120 秒。测试产生独立 inference attempts 和用量。

capability_test operation 失败时，`AiOperation.result` 仍保留已完成各层的 AiTestResult，`error` 同时说明终止原因。模型发现操作失败则可 result=null。GUI 契约证据归属于完整 GUI profile revision（包括 adapter/prompt/parser/coordinate 版本）；模型配置上的 vision 标志不能代替它。

仅 GUI 契约通过不证明真实 Desktop 后端可执行。真实输入能力由 G0/G5/G6 证据决定，UI 要将“模型已验证”和“当前 Desktop 支持执行”分开显示。

## 12. 页面实施合同

W01–W08 的完整线框图和逐控件规则见 `wireframes/index.html`、`docs/wireframes.md`。线框图中的模型、端点、任务和测试状态是演示数据。

| 页面 | 必须完成的主要交互 | 关键状态与接口 |
|---|---|---|
| W01 AI 连接 | 列表、搜索、新增、进入编辑、禁用/删除 | empty/loading/error/disabled；connections.list/get。 |
| W02 连接编辑 | 字段验证、保存、独立凭据轮换、获取模型 | 校验错误、CAS 冲突、key 状态；connections.create/update、credentials.rotate。 |
| W03 GUI 配置 | 选择模型、adapter、限额、备用候选、默认配置 | unverified/verified/stale/default；modelProfiles 与 profiles/default。 |
| W04 能力测试 | 启动、查看分层结果、取消、保存证据 | running/partial failure/cancelled；tests.start、operations.get/cancel。 |
| W05 启动诊断 | 选择受支持 Desktop、profile、中立目标、允许动作 | capabilities不足/缺模型/未验证/正常；gui.runs.start。 |
| W06 运行详情 | 当前状态、绑定版本、步骤、模型尝试、回执、停止 | running/succeeded/failed/cancelling；runs.get/events/cancel。 |
| W07 需处理 | 展示未知动作、最后证据、停止/返回详情 | unknown 不显示“重试上一步”；不制造 resume/reconcile RPC。 |
| W08 用量诊断 | 范围、已知 token、未知次数、模型/动作区分 | empty/error/unknown usage；usage.summary。 |

全局要求：按钮未实现时不可点击且有原因；空/加载/失败各有独立状态；保存期间阻止重复 mutation；服务返回的实际状态覆盖本地乐观状态；密码不回填原文；键盘 Tab 可达、焦点可见、弹窗有关闭和焦点归还；状态变化用可访问文本，不只靠颜色。

复杂的 parserVersion、binding generation、原始错误 code 放在高级配置/诊断详情。主流程展示用户能据此行动的信息，例如“当前模型未通过截图测试”“这次运行使用保存时的配置”“输入结果尚未确认”。

## 13. CLI 合同与可操作演练

### 13.1 命令映射

下列命令需要在现有产品 CLI 内实施；交付包本身不含可替代原生产品的 CLI。全局参数置于命令前：`agentdesktop --json [--socket PATH] ...`。未指定 socket 时使用产品默认路径，保留现有环境变量兼容规则。Windows 使用对应 pipe，不能让 CLI 直接加载输入 backend。

| CLI 形状 | RPC | 参数和结果 |
|---|---|---|
| `runtime capabilities` | runtime.capabilities | 输出能力协商结果。 |
| `ai connections list/get/create/update/disable/delete` | ai.connections 对应操作 | get 等使用 `--id`；修改使用 `--expected-revision`；复杂字段使用 `--params-file`。 |
| `ai credentials rotate` | ai.credentials.rotate | `--connection-id`、`--expected-revision`、`--credential-stdin`；不支持命令行明文 key。 |
| `ai models list/refresh` | ai.models 对应操作 | `--connection-id` 与 catalog 版本参数按操作合同；refresh 可 `--wait`。 |
| `ai model-profiles list/get/create/update/disable/delete` | ai.modelProfiles 对应操作 | CLI kebab-case 映射固定 camelCase wire 命令。 |
| `ai profiles list/get/create/update/disable/delete` | ai.profiles 对应操作 | GUI profile 的模型和版本引用必须完整。 |
| `ai profiles default get/set` | ai.profiles.default.get / ai.profiles.setDefault | set 使用 `--id` 或 `--clear`、`--expected-default-revision`；非空同时 `--expected-profile-revision`。 |
| `ai tests start` | ai.tests.start | `--profile-id`、`--expected-revision`，fixture 固定 synthetic_gui_v1；可 `--wait`。 |
| `ai operations get/cancel` | ai.operations 对应操作 | `--id`；cancel 必须 mutation key。 |
| `gui run` | gui.runs.start | `--desktop`、可选 `--session`、可选 profile+revision、`--goal-file`、`--verification-file`、`--allowed-actions`；可 `--wait`。 |
| `gui status/cancel/events` | gui.runs.get/cancel/events | `--run-id`；events `--after-sequence`，可 `--follow`。 |
| `ai usage` | ai.usage.summary | 日期/筛选以 Schema 为准，不发送客户端自选账户授权。 |
| `rpc --request-file FILE` | 原样版本化 envelope | 提供不依赖所有友好别名的完整 32 操作入口；本地 Schema 校验后发出。 |

每个 mutation 必须携带 `--idempotency-key` 或请求文件中的同名 context 字段。交互界面可生成 UUID 并保存到正在提交的操作状态；自动化 CLI 不得在一次不确定重试时悄悄换 key。`--params-file` 是 params 对象，不是完整 envelope；`rpc --request-file` 则是完整 envelope，两者不混用。字段同时在 flags 和文件中出现时返回本地参数冲突，禁止静默覆盖。

### 13.2 输出、退出码与取消

普通 `--json` 命令 stdout 只输出一行 JSON；进度信息在 stderr。mutation 默认在服务受理后返回，不能把返回的 queued/running 当成完成。`--wait` 使用 get 轮询，最终 stdout 为最后一次合法 get 的 RPC envelope，内含终态对象；受理消息只写 stderr。events 的 `--follow` 逐轮输出完整响应的 NDJSON，调用者按 runId+sequence 去重。

| Exit code | 含义 |
|---|---|
| 0 | 只读成功、写入已受理，或 `--wait` 的任务 succeeded；调用者仍需看 state。 |
| 2 | 本地参数/Schema 校验失败，未提交。 |
| 3 | 本地 Runtime 无法连接、版本不兼容或响应帧错误。 |
| 4 | 服务端业务拒绝或任务 failed，例如 CONFIG_CONFLICT、CAPABILITY_MISMATCH。 |
| 5 | `--wait` 观察到终态 cancelled。 |
| 6 | 客户端等待截止，任务可能仍在运行；输出最后状态，用户通过 status 查询。 |
| 130 | 收到用户 Ctrl-C 并结束本地等待；若存在已启动 run，应先提交同一幂等 cancel 并打印受理结果，仍不能声称终态。 |

`--wait-timeout-ms` 限制客户端等待，不扩展 Runtime deadline。普通 socket 请求结束或 CLI 在非 `--wait` 模式正常退出，不取消已受理任务。测试 `CLI-003` 必须验证此区别。

`--dry-run` 只在本机解析 flags、组装并校验 Schema，打印 `{dryRun:true,valid:true,request:脱敏请求}`，不连接 Runtime、不读截图、不发模型、不执行输入。它不宣称 session 授权、能力证据或当前资源可用；真实提交仍需服务端校验。失败输出对应本地错误，exit=2。

### 13.3 凭据输入和配置演练

新建连接的 params 文件只保存 name/protocol/baseUrl/timeoutMs；`--credential-stdin` 把当前 stdin 读作一次性 apiKey，再补入待发送 params。stdin 在接收 secret 的命令中不能同时作为 params 文件。终端交互采用无回显输入；不支持 `--api-key 明文`，不把 key 写入 shell history、process argv、诊断文件或完整 envelope fixture。

生产流程按顺序创建 connection → model profile → GUI profile → tests → default。每一步读取响应生成的 id 和 revision，再用于下一步；禁止把本包的 `connection-test-001` 当成服务保证分配的真实 id。

```bash
agentdesktop --json runtime capabilities
agentdesktop --json ai connections list
agentdesktop --json ai profiles list
agentdesktop --json ai profiles default get
```

一次 run 的 verification 文件内容如下：

```json
{
  "kind": "element_text_equals",
  "role": "static_text",
  "text": "已保存：Ada / MAC-001-A / 提交次数 1"
}
```

goal 文件仅写“在指定中立表单的姓名中输入 Ada，然后点击应用”。Desktop ID 和 GUI profile ID 使用前面服务实际返回/当前 Runtime 绑定的值，下例为说明占位符：

```bash
agentdesktop --json gui run \
  --desktop desktop-A \
  --profile-id GUI_PROFILE_ID \
  --expected-profile-revision 1 \
  --goal-file goal.txt \
  --verification-file verification.json \
  --allowed-actions click,type,key \
  --idempotency-key neutral-MAC-001-A \
  --wait
```

允许使用 `fixtures/valid/requests` 验证编解码，实际联调时必须替换对象 ID、关联版本、session/desktop 和每次新操作的 key。例子中的 `test-key-local-only` 仅用于本包模拟服务，不能用于生产或作为真实密钥示例导入正式环境。

### 13.4 当前即可运行的交付包检查

解压后在包根目录运行下列命令；这些命令验证交付材料，不要求安装 AgentDesktop：

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -r tools/requirements.txt
.venv/bin/python tools/run_handoff_checks.py
```

Windows PowerShell 对应 `.venv\Scripts\python.exe`。验证器使用本地 Schema registry，不从 Schema 的 `.invalid` URI 下载任何内容；pip 首次安装需要正常包源。结果写入 `validation/contracts-report.json` 和 `validation/mock-report.json`。单独启动模拟服务使用 `python3 tools/mock_ai_server.py --help` 所列参数；场景、认证及调试路由见 `docs/contracts.md`。

## 14. 如何参考 CC Switch 与迁移旧资产

### 14.1 借鉴对应表

| 源码设计 | 在本项目的采用方式 | 原因 / 验证点 |
|---|---|---|
| CC Switch 的 Provider 配置与前端 API 分层 | 借鉴连接列表、编辑、模型选择、测试反馈及服务层封装 | 在本项目拆成 connection / model profile / GUI profile；一个配置对象不同时承担凭据、模型动作协议和运行状态。 |
| 只投影自己管理的配置字段 | 设置界面编辑本服务管理字段，默认选择和运行快照分别维护 | 避免 UI 全量覆盖未知配置；CAS 冲突明确展示。 |
| 网络探测 | 将可达性单列为 network 层 | 任意 HTTP 状态表示收到响应，不等于认证、图像或 GUI 契约成功。 |
| Provider 路由与失败分类 | 借鉴可观测的候选选择、有限失败转移思路 | 本方案冻结候选版本与授权范围，并共享总 attempt 限额。 |
| 请求/用量记录 | 按每次实际 attempt 记录来源、模型、延迟、usage | 失败尝试和缺失用量也保留；与 ActionReceipt 分开。 |
| image sanitizer / 兼容转换 | 不采用自动删掉当前必需图像的路径 | GUI 必需视觉输入被删除后，语义不再等价。 |
| 通用协议工具转换 | V1 使用明确的 UI-TARS codec 和严格动作子集 | 未知工具不能过滤成成功；不声称 OpenAI/Claude/Gemini computer-use 同义。 |
| SQLite 配置存储 | 只保存 credential reference 和非机密设置；系统凭据库保存 key | CC Switch 的具体存储方式不构成本项目的秘密管理合同。 |

这里参考的是已有产品设计和实现经验，`cc-switch` 的 Provider 本身管理的是 AI 客户端配置，不能直接当成有桌面授权能力的 GuiAiProvider。相关证据按固定 commit 列于 S05–S10；如果复制 MIT 许可源文件，保留其版权与许可声明。[S05](#source-s05) [S06](#source-s06) [S07](#source-s07) [S08](#source-s08) [S09](#source-s09) [S10](#source-s10)

### 14.2 旧 2ndscreen / task-runtime 的迁移单

| 资产 | 迁入内容 | 必须改造 | 原路径退出条件 |
|---|---|---|---|
| Core 显示/输入/窗口/AX/OCR | 原生可用能力及有价值的测试 | 统一 scope/目标校验/冲突域/回执 | 产品正常安装、无旧 checkout 也能运行；所有输入调用进入 Runtime。 |
| ControlProtocol / ControlServer | 现有 JSONL 接入和可用命令语义 | 版本解码、权限、帧限制、异步 run 查询、原子宿主锁 | 新旧请求都进入同一服务；无第二个可绕过的旧 socket 执行入口。 |
| TarsAgent/Model.swift | 已有多模态协议字段和模型兼容知识 | 去除同步 semaphore、host env key、硬编码 thinking；使用 AiService | 不再直接持密钥或发生产请求。 |
| TarsAgent/ActionParser.swift | 经测试的 UI-TARS 文法 | 版本化语法、严格单动作、显式尺度和变换、拒绝未知字段 | 新 codec 通过完整 parser/坐标夹具。 |
| TarsAgent/Agent.swift | observe/think/act/verify 的可复用逻辑 | Proposal 与执行分离、有界状态机、cancel、后置验证 | 不再直接调用 InputEngine.perform。 |
| TS agent-providers / agent-host | purpose/caller、AbortSignal、usage unknown 等语义 | 用 Swift/C# 重新实现同一语义，不保留永久生产 TS 宿主 | 构建依赖、进程树、launch scripts 不依赖 task-runtime。 |
| BOSS Python | 业务调度保持在业务层 | 接入同一个 Runtime 合同，处理明确终态和未知状态 | 业务不回退到自行控制宿主桌面的旁路。 |

逐文件迁移清单需要列 source commit、目标文件、保留理由、修改点、替代入口和验证证据。用户既定单仓方向优先，旧仓规则应显式更新为历史迁移说明。不能在本项目实施计划中要求长期维持两个产品仓库同步发布。[S01](#source-s01) [S03](#source-s03) [S04](#source-s04) [S11](#source-s11)

## 15. 开发任务、依赖和 PR 切分

工作量用依赖和验收范围表达，不给未经团队校准的天数保证。每个 PR 保持可独立评审；不能以“页面完成”替代底层执行证据。

| ID | 工作 / 代码落点 | 依赖 | 必须提交的结果 | 对应验证 |
|---|---|---|---|---|
| T00 | 核对当前仓库、AGENTS、构建/安装/CLI；建立迁移清单 | 无 | BASELINE.md、文件映射、实际 commit、现存能力和缺口；更新旧两仓规则 | MIG-001/002/003 |
| T01 | 原生 Runtime G0：scope、Desktop、target、lease、真实冲突域、receipt、unknown 收尾 | T00 | 直接 API 可调用；无 AI 的 host+A+B 隔离演示；可重现故障注入 | EXE-001..004；G0 全项 |
| T02 | Contracts、版本化 decoder、错误、32 操作 dispatch、CLI rpc | T00；有动作的路由依赖 T01 | Swift/C# DTO 编解码；Schema 校验；新旧命令兼容；socket/pipe 边界 | RPC-001..008 |
| T03 | SQLite store、revision CAS、default pointer、idempotency、恢复 migrations | T02 | 事务实现；不可变 snapshot；删除引用检查；配置 unit tests | CFG-001..008 |
| T04 | CredentialStore、端点、创建/轮换 outbox、日志脱敏 | T02/T03 | Keychain/DPAPI；撤销旧 identity；恢复 fault harness | SEC-001..006 |
| T05 | AiService、OpenAIChatTransport、模型 catalog、预算/usage ledger | T03/T04 | 完整多模态编码、异步取消、错误映射、未知用量、无降级丢图 | TRN-001..007、RET/USG |
| T06 | UITars codec、显式坐标、Proposal provenance | T02/T05 | Production adapter 与 test adapter 隔离；parser golden suite | GUI-001/002/004/005、COO-001..008 |
| T07 | GuiExplorer、run actor、GoalVerifier、Runtime composition | T01/T05/T06 | 一步到多步完整循环、steps/attempt 分离、cancel/unknown、真实验证 | GUI-003/006..008、CAN/RET |
| T08 | 四层能力测试和证据失效 | T05/T06 | synthetic fixture service；partial results；测试不产生输入；用量记录 | TRN-008、UI-004 |
| T09 | 设置 W01–W04；ViewModel 只调用服务 | T03/T04/T08 | 连接/模型/profile/default 全流程、错误和键盘操作 | UI-001..004 |
| T10 | 诊断 W05–W08；run/events/usage | T07/T08 | 目标+verifier 输入、快照和 timeline、取消结果、unknown 页面 | UI-005/006、USG-004 |
| T11 | CLI 友好命令、stdin、dry-run、JSON、poll/cancel | T02/T03/T07/T08 | 32 操作可通过 rpc 调用；表中友好命令与页面同语义 | CLI-001..004 |
| T12 | macOS 完整集成、清洁安装、真模型与隔离验收 | T01..T11；G0–G4 通过 | G5 原始证据、发行包、迁移/回滚说明 | MAC-001..007 |
| T13 | Windows 原生实现和平台对等验收 | T02 契约稳定；语义任务 T01..T11 | C# Runtime/AI/GUI/IPC/凭据；SDK 锁定；G6 独立证据 | WIN-001..007 |
| T14 | 集成收尾、旧路径删除、文档与能力声明 | 已声明平台的验收通过 | 无生产旧依赖；构建和 clean install；实际支持矩阵；证据索引 | G0 重跑相关迁移项 + 发布审查 |

T02/T03 的纯契约和配置实现可与 T01 并行；T05/T06 可以使用模拟 scoped ports 做测试。**真实 GUI 输入入口保持关闭，直到 G0 对该平台和后端的前置条件有通过证据。** Windows 的 Contracts、配置与网络代码可平行实施，但不能自动继承 macOS backend 的隔离证明。

## 16. 测试架构与具体用例

### 16.1 测试层次

完整 CSV 每项包含 id、gate、priority、domain、test_kind、preconditions、steps、expected_result、assertion、evidence、status。开发 Agent 需要实现真正执行断言的测试，不是仅解析 CSV 后打印 PASS。

| 层次 | 注入依赖 | 验证什么 | 不可代替什么 |
|---|---|---|---|
| Schema / 静态契约 | 本地 registry + valid/invalid fixtures | 类型、必填、enum、上限、禁止额外字段、操作覆盖 | 服务端 CAS、权限、取消和桌面安全。 |
| 原生单元测试 | FakeClock、FakeCredentialStore、StubTransport、SpyExecutor | 事务、计数、状态、parser、坐标、错误分类 | 真正 OS API 是否只影响目标窗口。 |
| 原生集成测试 | 临时 SQLite、mock HTTP、实际 socket/pipe | JSONL、idempotency、revocation、重试、partial report、usage | 真实模型兼容和 UI 输入隔离。 |
| 故障注入 | 在响应/落盘/发送输入边界设置 failpoint | 迟到响应、未知输入、崩溃恢复、audit 不可写 | 正常路径之外的实际后端能力。 |
| 原生 UI / CLI | 可控服务 fixtures + 辅助功能自动化 | 每个控件、空/加载/错/冲突/取消、stdin/exit code | 接入真实模型后的完整闭环。 |
| 真机 E2E | 原生 bundle、真实 Desktop、中立表单、实际 GUI 模型 | 端到端目标完成、主桌面不受影响、证据一致 | 另一个未测试的 OS、DPI 或输入 backend。 |

### 16.2 必须优先通过的高价值断言

| 用例 | 安排与动作 | 预期结果及判断方法 |
|---|---|---|
| CFG-003/004 | R1 已绑定 P1；把 default 改 P2，再创建 R2 | R1 仍用 P1 完整版本链；R2 用 P2；修改 default 不改变 R1 的 binding 字节内容。 |
| CFG-005 | 删除被 profile/default/active run 引用的资源 | RESOURCE_IN_USE；无级联删除、无孤立运行引用。 |
| SEC-004 / CAN-002 | 模型已收到请求但未响应；轮换 K1→K2 或取消 | 旧结果不进入输入；currentGeneration 已增加；K1 无法再解析；receipt/原因可查。 |
| GUI-003 | 模型直接返回 finish，目标文本未出现 | 新观察的 verifier 不通过，不能 succeeded；模型自报完成不改变结果。 |
| COO-002..005 | Retina、负原点、crop、resize、letterbox 组合 | 纯数学结果误差 ≤1e-6；留白和越界点拒绝；无尺度猜测。 |
| TRN-005 | 图片 payload 恰好 8 MiB，再增加 4 字节 | 前者通过，后者 LIMIT_EXCEEDED；必需当前截图始终保留。 |
| RET-001 | 主候选 429、Retry-After=2s，剩余 5s | 使用 FakeClock 前进后才重试；单步总 attempt≤2；到 deadline 无新请求。 |
| RET-004 / MAC-005 | click 已提交且计数增加，丢失确认 | ActionReceipt=unknown；不自动重发；冲突域安全释放前不让新 run 使用。 |
| USG-002 | 成功响应但缺 token 或费用 | 显示 unknown / incomplete；已报告小计不冒充全部；实际返回模型单独记录。 |
| RPC-006 | 同一个 start key 发送两次，相同/不同请求 | 相同返回同 runId 且模型只启动一次；不同返回 IDEMPOTENCY_CONFLICT。 |
| MAC-002 | 主桌面持续输入，同时 Desktop A/B 各执行中立任务 | A/B 各自目标正确；host 文本/焦点无窃取，动作未串台；连续录像与 target receipts 对照。 |
| MAC-007 | 无 AI key、模型离线、无旧 2ndscreen 目录 | 产品可启动；已有直接 API/确定性回放可用；AI GUI 显示未配置，不导致底座崩溃。 |

以上为阅读摘要，具体步骤、边界值、负例与证据按 `tests/cases.csv` 和 runbook 执行。所有原生产品用例初始状态为 NOT_RUN；交付包工具运行结果只表明材料自身可解析、模拟服务按设计响应。

## 17. 验收门槛、执行方法和预期结果

| Gate | 范围 | 执行方法 | 通过结果 / 证据 |
|---|---|---|---|
| G0 | 单仓迁移 + 原生执行前置 | 构建与 clean install；无 AI 的直接输入；host+A+B；unknown 故障注入 | 产品不依赖旧仓；目标/冲突域真实；unknown 不重放；原始录像和 ActionReceipt。 |
| G1 | IPC、配置、凭据、基础网络 | Swift/C# 原生 contract/unit/integration；canary 密钥扫描；多用户 IPC | DTO 对齐；CAS/幂等/边界正确；无机密泄漏、redirect 或跨用户访问。 |
| G2 | GUI parser、坐标、预算、验证、能力测试 | golden/property tests、FakeClock、synthetic image 上游 | 精确变换、拒绝未知动作、有限循环；模型 finish 不自验；四层报告保留。 |
| G3 | 页面和 CLI | W01–W08 操作录像/自动化；JSON/exit/stdin/dry-run | 同一后台状态；完整异常状态；退出码和终态分开；无秘密进 argv。 |
| G4 | 取消、重试、fallback、用量 | 延迟 mock、网络/DB/输入 failpoints、FakeClock | 无迟到输入；每步≤2/每 run≤30 attempts；unknown 不重放；用量完整性明确。 |
| G5 | macOS 真机闭环 | 正式候选 bundle、干净账户、中立表单、真实 GUI model；分别执行 MAC-001..007 | 完成条件新观察通过；宿主不受影响；原生 target/receipt 可核对；离线底座可用。 |
| G6 | Windows 独立证明 | C# build、pipe/DPAPI、跨平台 golden、DPI矩阵、host+A+B、真模型 | 相同语义与本平台证据同时成立；不能以 macOS PASS 覆盖 Windows。 |

未执行的门槛写 NOT_RUN；环境缺失写 BLOCKED，并列缺什么；失败写 FAILED。不能将 skip 或“不适用”改成 PASS。只发布 macOS 时可把 Windows 明确标记未交付，但不能声称本方案全部跨平台任务完成。要声明本方案端到端全部完成，需要 G0–G6 的适用项都通过。

### 17.1 真机一次 happy path 的操作单

1. 记录 OS/build、硬件/显示布局/DPI、App commit、backendId、输入路径、model endpoint host 与 modelId；记录实际版本，不放 API key。
2. 安装当前候选包，打开 Runtime 能力页；确认 G0 已通过的 backend，目标 Desktop/session 与中立窗口绑定唯一。
3. 在 W01–W04 创建连接、模型与 GUI profile，运行四层测试并保留 operationId/完整结果。真实模型测试会产生实际请求，由操作者使用自己的已授权测试连接。
4. 在 Desktop A 打开 `fixtures/neutral-form.html?role=A&case=MAC-001-A`，重置，确认姓名为空、提交次数为 0。
5. W05 指定目标、允许动作与上文 verification，启动；从 W06 观察模型 attempt 和 ActionReceipt。
6. 期待状态文本精确为 `已保存：Ada / MAC-001-A / 提交次数 1`；Runtime 通过较新的 Observation 记录 GoalVerification=passed；run=succeeded。
7. 对照表单、录像和回执，确认只修改目标窗口；ActionReceipt 的执行目标与绑定一致，提交不重复；记录模型 usage 的已知/未知状态。
8. 通过既有 Runtime 的确定性验证/回放入口检查已经达成的状态，不应产生模型调用或再次提交；与 MAC-007 的无模型底座能力联合验收。这里没有承诺任意第二个 `gui run` 自动零模型，也不复用原 run 的 idempotency key 来伪造第二次执行。

### 17.2 结果包格式

复制 `tests/acceptance-result.template.json`，每个 case 填 actual、assertions、evidence paths、commit、platform 与 status。证据文件包含 testId/runId，按各自实际 schema 保存 request/response、redacted run、events、inference receipts、action receipts、verification、截图/录像索引与哈希。一个 PASS 必须有机器断言或明确可复核的人工证据；“界面看上去可以”不够。

当模型/上游不报告 usage 时，验收结果可以 PASS 且 usage=null，前提是 unknown 逻辑正确；不能为了过测填 0。当 OS 输入结果无法确定时，不能把 unknown 改写 confirmed 来通过 happy path；应在 unknown 专项中验证正确处理，并修复/更换可支持的 backend 后重新验收普通路径。

### 17.3 非功能要求

主线程不阻塞网络；原生窗口在模型等待期间仍可点击停止。取消与状态更新的单元测试用 FakeClock/spy 精确验证事件先后；真实请求响应时长只记录分布，不把不同网络环境下的固定毫秒值作为未经测量的性能承诺。资源泄漏检查至少覆盖重复创建/取消任务与关闭窗口，观察 Task、URLSession、句柄、临时截图及 SQLite 文件是否回到稳定范围。

安装包不能要求用户部署 Node/TS daemon 或旧 2ndscreen App。日志、诊断、UI 错误、CSV 导出和崩溃恢复文件均扫描测试 canary；扫描通过范围和工具输出作为 SEC-001 的证据。

## 18. 接口实现中必须明确的补充语义

### 18.1 能力测试和 GUI 调用共用 AiService

共享 AiService 内部调用 context 使用 purpose 区分 `gui_step` 和 `capability_test`。GUI 请求携带 runId/stepIndex/snapshotId/currentGeneration；诊断请求携带 operationId/level/合成 snapshot 标识，不提供任何输入 port。两者共用 credential、HTTP、deadline、attempt ledger 和 usage 的底层逻辑。

对外 `InferenceReceipt` 是 GUI run 的回执 DTO；诊断内部 ledger 可使用 operationId 外键并汇总到 AiTestResult，不伪造一个真实 GUI run。SQL 表需要 purpose、nullable runId、nullable operationId 和互斥 CHECK；不能因为诊断没有真实 Desktop 就绕过预算或把 token 丢掉。`ai.usage.summary` 的整体汇总包含两类已授权调用，V1 仅支持 from、to、connectionId 筛选；单 run 通过 gui.runs.get 的回执及 events 查看，不能传 Schema 未定义的 runId 过滤参数。

### 18.2 候选选择、状态和费用

fallback 在 run start 时解析为最多一项完整候选，验证无循环、自引用、被禁用资源或跨授权边界；每个候选继承相同动作允许列表和运行预算。运行中修改 fallback 不影响已固定列表。

health 记录只作诊断与选择依据。用户主动 cancel、输出 parser 不匹配和授权拒绝不能全部统称“服务商宕机”。费用按实际尝试分别记录；上游报告的 requestId 若存在保留在 upstreamRequestId，用于对账，但不能覆盖本地 requestId。

### 18.3 页面演示与生产 UI 的关系

离线 wireframes 用固定演示数据展示布局、控件和状态；它不是 App 实现，也不向模型或桌面发请求。静态图片为精确工程线框图，若由 SVG 渲染则明确标为静态图，不能标作真实 App 截图。HTML 的按钮模拟状态只用于评审交互；生产 UI 按 W01–W08 控件合同连接 application service。

浏览器 QA 或原生 UI 自动化未执行的项目必须保留 NOT_RUN/BLOCKED。任何文档中“通过”的标签只有带来源的测试报告或明确“演示”标识才成立。

## 19. 开发 Agent 的交付与审查约定

每个任务提交：问题与目标、实际改动、合同差异、对应测试、证据路径和剩余限制。评审先核对对外行为和执行边界，再看目录命名。实现中需要新增字段时，同一 PR 更新 Schema、Swift/C# DTO、fixtures、CLI/UI 和用例；不能只改一端。

集成者负责维护一个支持矩阵：OS / backend / actions / verifier / independentDesktopConcurrency / tested commit / evidence。只对有实证的组合设置 nativeIsolationEvidence=VERIFIED；其他组合保持 NOT_RUN 或 FAILED，并在 UI 给出原因。

最终交接材料至少有：可安装产品、完整源代码 commit、可运行测试命令、G0–G6 结果矩阵、32 操作契约版本、八页 UI 证据、凭据与 DB migration/rollback 说明、已删除旧路径清单、发布限制。不得用 mock server 的 PASS 代替以上产品交付。

## 20. 来源与证据索引

本方案在 2026-10-08（Asia/Shanghai）核对以下材料。固定 SHA 指向本轮依据，开发 Agent 开工时需再记录实际仓库 HEAD 差异。下面是事实依据；新增合同、限制数值、任务顺序和验收规则属于本方案的设计决策。

<a id="source-s01"></a>
**S01 · 用户架构基线** — [BOSS / AgentDesktop architecture FINAL v1.0](https://chatgpt.com/library/share/libfile_bf735d92cad88191a59e9e1eb7cd113b?account_id=personal)，文件版本 2，读取内容为 494 行。GuiAiProvider/GuiExplorer 分层与统一输入主要在 137–162、246–269；原生单仓迁移和旧路径退出在 307–361。此处给行号便于复核原材料，不是当前文档文件行号。

<a id="source-s02"></a>
**S02 · AgentDesktop 当前产品** — [`README.md`](https://github.com/szrunworld/agentdesktop/blob/91cfd09a9c0213baf35e8191f135319db93a29f1/README.md)、[`Package.swift`](https://github.com/szrunworld/agentdesktop/blob/91cfd09a9c0213baf35e8191f135319db93a29f1/Package.swift)。依据：2ndscreen 0.2.0、产品 CLI wrapper、product control.sock 与当前构建边界。

<a id="source-s03"></a>
**S03 · 已打包旧 Runtime** — [`ControlProtocol.swift`](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/Sources/SecondScreenCore/ControlProtocol.swift)、[`AgentRuntime.swift`](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/Sources/SecondScreenRuntime/AgentRuntime.swift)。依据：单请求/单响应 JSONL、command enum、旧 input 执行与宿主结构。

<a id="source-s04"></a>
**S04 · Swift GUI 模型迁移资产** — [`Model.swift`](https://github.com/szrunworld/2ndscreen/blob/da5677c2be421dc2d35cdda5cdf66b7134f6a381/Sources/TarsAgent/Model.swift)、[`ActionParser.swift`](https://github.com/szrunworld/2ndscreen/blob/da5677c2be421dc2d35cdda5cdf66b7134f6a381/Sources/TarsAgent/ActionParser.swift)、[`Agent.swift`](https://github.com/szrunworld/2ndscreen/blob/da5677c2be421dc2d35cdda5cdf66b7134f6a381/Sources/TarsAgent/Agent.swift)。依据：多模态请求、UI-TARS 解析、同步调用与直接执行的改造需求。

<a id="source-s05"></a>
**S05 · CC Switch 配置与 UI API** — [`src/types.ts`](https://github.com/farion1231/cc-switch/blob/f9db9f7056cbe7f972cdc02644722002316866b9/src/types.ts)、[`src/lib/api/providers.ts`](https://github.com/farion1231/cc-switch/blob/f9db9f7056cbe7f972cdc02644722002316866b9/src/lib/api/providers.ts)。依据：应用 Provider 配置结构与 API 封装；与 GUI 动作 Provider 的职责区别。

<a id="source-s06"></a>
**S06 · CC Switch 配置投影与网络检查** — [`claude_direct.rs`](https://github.com/farion1231/cc-switch/blob/f9db9f7056cbe7f972cdc02644722002316866b9/src-tauri/src/services/provider/claude_direct.rs)、[`stream_check.rs`](https://github.com/farion1231/cc-switch/blob/f9db9f7056cbe7f972cdc02644722002316866b9/src-tauri/src/services/stream_check.rs)。依据：管理字段投影、HTTP 可达检查与业务可用性分层。

<a id="source-s07"></a>
**S07 · CC Switch 图像兼容路径** — [`media_sanitizer.rs`](https://github.com/farion1231/cc-switch/blob/f9db9f7056cbe7f972cdc02644722002316866b9/src-tauri/src/proxy/media_sanitizer.rs)、[`forwarder.rs`](https://github.com/farion1231/cc-switch/blob/f9db9f7056cbe7f972cdc02644722002316866b9/src-tauri/src/proxy/forwarder.rs)。依据：存在可选媒体清理/重试路径；本方案不将删图作为 GUI 兼容恢复。

<a id="source-s08"></a>
**S08 · CC Switch 路由与转换** — [`provider_router.rs`](https://github.com/farion1231/cc-switch/blob/f9db9f7056cbe7f972cdc02644722002316866b9/src-tauri/src/proxy/provider_router.rs)、[`transform_codex_chat.rs`](https://github.com/farion1231/cc-switch/blob/f9db9f7056cbe7f972cdc02644722002316866b9/src-tauri/src/proxy/providers/transform_codex_chat.rs)。依据：候选路由与工具转换的上下文；本方案要求无损保留 GUI 必需语义。

<a id="source-s09"></a>
**S09 · CC Switch 存储实现** — [`dao/providers.rs`](https://github.com/farion1231/cc-switch/blob/f9db9f7056cbe7f972cdc02644722002316866b9/src-tauri/src/database/dao/providers.rs)、[`database/mod.rs`](https://github.com/farion1231/cc-switch/blob/f9db9f7056cbe7f972cdc02644722002316866b9/src-tauri/src/database/mod.rs)。依据：JSON 配置与 SQLite 实现；本方案另定 Keychain/DPAPI 与 credential reference。

<a id="source-s10"></a>
**S10 · CC Switch 许可** — [`LICENSE`](https://github.com/farion1231/cc-switch/blob/f9db9f7056cbe7f972cdc02644722002316866b9/LICENSE)。本方案为重新设计的工程合同；实际复制源码时由开发 Agent 保留对应声明。

<a id="source-s11"></a>
**S11 · TS 调用语义迁移资产** — [`agent-providers.ts`](https://github.com/szrunworld/2ndscreen/blob/da5677c2be421dc2d35cdda5cdf66b7134f6a381/packages/task-runtime/src/agent-providers.ts)、[`agent-host.ts`](https://github.com/szrunworld/2ndscreen/blob/da5677c2be421dc2d35cdda5cdf66b7134f6a381/packages/task-runtime/src/agent-host.ts)、[`agent-config.ts`](https://github.com/szrunworld/2ndscreen/blob/da5677c2be421dc2d35cdda5cdf66b7134f6a381/packages/task-runtime/src/agent-config.ts)。依据：宿主凭据、调用用途/调用者、取消、usage unknown 和端点验证的可迁移语义。

<a id="source-s12"></a>
**S12 · JSON Schema 版本** — [JSON Schema Draft 2020-12](https://json-schema.org/draft/2020-12)。本包采用该版本，离线 registry 解析相对引用。

<a id="source-s13"></a>
**S13 · .NET 支持周期** — [Microsoft .NET releases and support](https://learn.microsoft.com/en-us/dotnet/core/releases-and-support)。用于 .NET 10 LTS 选型依据；开工时锁定实际可用 SDK patch。

<a id="source-s14"></a>
**S14 · DPAPI CurrentUser** — [Microsoft .NET ProtectedData package documentation](https://github.com/dotnet/runtime/blob/main/src/libraries/System.Security.Cryptography.ProtectedData/src/PACKAGE.md)、[Microsoft data protection guide](https://github.com/dotnet/docs/blob/main/docs/standard/security/how-to-use-data-protection.md)。用于凭据静态加密与保护范围说明；进程授权仍由应用边界控制。

