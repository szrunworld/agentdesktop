# 08 Runtime 事件到 ACP 更新的映射规范

状态：工作线 E 交付稿，2026-10-08。基于 `acp-skeleton`（含 ai-gui-foundation b2831ca：A0 #47、G0 #51）。
实现：`Sources/AgentDesktopACP/Events/`（投影）、`Sources/AgentDesktopACP/Privacy/`（分类与脱敏）。
测试：`Tests/AgentDesktopACPTests/Events/`、`Privacy/`、`Fixtures/events/`（15 份 golden 夹具）。

依据：方案 v1.0 第五节、6.4；docs/plan/06 §6.4；README 第五节 Kevin 裁决附加约束 3（事件分三级，重点验证截图、窗口标题、输入内容、审批参数不泄露跨应用数据）。

## 〇、f1 审核结论（2026-10-08）

| 编号 | 结论 |
| --- | --- |
| E-1 | 接受形状，分两步：PR2b 把 `ActionReceipt.verification` 放宽为 not_requested / pending / matched / contradicted / inconclusive，并登记 `action.verified`；产生它的实现随 A3 的动作后观察落地。只有 Runtime 验证器能写 |
| E-2 | 接受：派发前拒绝也发 `action.failed`，回执 delivery=not_dispatched；不新增 `action.refused` |
| E-3 | 接受：`action.failed`/`action.unknown` 的 data 带 `error {code, details.reason}`，不带 message |
| E-4 | 接受：`run.ended` data 带 kind、unknownActions、closingReason；unit 级验证结论属 F40-03（40，PR2d） |
| E-5、E-6 | 接受：F1-01 在 methods.json 的 `events` 段冻结，type 为 string 加 pattern |
| E-7、E-10 | 接受，规则更硬：事件 data 只允许 id、枚举、数字、时间戳，任何文本只能以 artifact 引用出现；目录给每个 type 标一次级别 normal / sensitive / protected。ACP 届时按契约分级，不再按键名推断 |
| E-8 | 接受：closingReason 取值冻结为 completed / failed / cancelled / global_stop / owner_lost / runtime_restarted / grant_revoked / deadline_exceeded，表外值不显示 |
| E-9 | 接受：ImageArtifact 加可选 `scope`（window / screen）、`windowId`、`bindingGeneration` |

PR2b 合入后，工作线 E 改为读目录里的级别与字段，删除按键名推断的部分。

## 一、原则

1. **唯一出口。** Runtime 事件只经 `ACPProjector`（实现冻结接口 `ACPEventProjector`）变成 `ACPSessionUpdate`。投影是纯函数：同一事件、同一策略、同一上下文，输出逐字相同。
2. **三级结果不混淆**（方案 5.2、docs/plan/06 §6.4）：已受理 ≠ 已执行 ≠ 已验证。只有 Runtime 报告验证「matched」时才显示「已验证成功」；`verification = not_requested`、`businessResult = not_evaluated` 一律停在「已执行，未验证」。
3. **unknown 只显示「待核实」**：不显示完成、不显示失败（失败标记会诱导重试），附「不会自动重试，请在 AgentDesktop 主窗口核实」。
4. **默认最严。** 默认只显示动作类别、状态、耗时、脱敏目标标识、目录内错误码、验证状态。截图、页面文字、窗口标题、输入内容、原始参数默认都不出现。
5. **永不崩溃。** 未识别的事件类型变成一条中性 thought；字段缺失或类型不对时按最保守的语义投影。
6. **事件来源**：`ACPRuntimeEvent.payload` 可以是 RunEvent 的 `data`，也可以是整个 RunEvent（`{runId, sequence, at, type, data}`）；两种形状投影结果相同（夹具 `emitted-full-frame-payload`）。建议线 R 传整个 RunEvent，以便拿到 `at` 计算 Run 用时。

## 二、三级分级（Kevin 裁决）

| 级别 | 含义 | 事件 | 字段类 |
| --- | --- | --- | --- |
| 普通 normal | 可完整展示 | Run 生命周期：run.accepted / queued / started / resumed / finishing / quiescent / ended、stop.accepted、unit.started / ended | code、identifier、scalar |
| 敏感 sensitive | 脱敏后展示；内容类字段只在策略放宽时出现 | 动作：action.* 、verification.* | freeText、windowTitle、pageText、url |
| 受保护 protected | 只显示状态，任何策略下都不暴露内容 | approval.required、run.waiting_approval、question.asked、run.waiting_input、目录外的任何类型；以及 data 带 `sensitive / withheld / redacted` 或敏感 `dataClassification` 的事件 | typedValue（含审批与动作参数 params / arguments）、credential、screenshot（字节）、withheld（含 covering* / other* / foreign* / sibling* 等描述其他窗口的字段） |

实现：`ACPEventTier`、`ACPEventType.tier`、`ACPEventType.tier(of:)`（目录外 → protected）、`ACPDataClass.tier`。受保护事件一律按最严策略投影并只保留状态行；被标记 withheld 的动作事件只剩「状态：…」一行。

### 2.1 跨应用数据（四类重点）

| 数据 | 风险 | 规则 | 测试 |
| --- | --- | --- | --- |
| 截图 | 屏幕或桌面截图可含其他应用 | 字节、base64、路径永不输出；只在 `screenshots` 放宽时输出 artifact 引用，且仅当图像对象的 `windowId` 等于本动作绑定目标的 `windowId`；没有 windowId（整屏）或不一致一律不出 | `crossAppScreenshots`、夹具 `privacy-cross-app` |
| 窗口标题 | G0 拒绝会描述遮挡窗口；事件可能同时带多个窗口 | 只读取绑定目标对象（data.target / 回执 target）上的 title / windowTitle / label；两者 windowId 不一致时都不读；covering* 等字段归 withheld；Runtime 错误 message 永不显示（只显示错误码与固定原因词表） | `crossAppWindowTitles` |
| 输入内容 | 粘贴或输入的文本可来自其他应用 | text / input / clipboard / paste / keys 归 typedValue，任何策略都不显示 | `crossAppTypedInput` |
| 审批参数 | 摘要、参数可引用其他应用内容 | 审批与提问事件属受保护级，只显示「等待批准（未批准前不会执行）」「等待回答一个问题」；params / arguments 归 typedValue | `crossAppApprovalParameters` |

## 三、映射表

「来源」一列：**已发**＝Runtime 今天发出且在 F1-01 目录内（GAP-08）；**暂定**＝方案 5.1 或协调者清单里有、Runtime 今天不发（04-gap-analysis C-10），已按最保守语义映射，目录冻结后对齐。

### 3.1 Run 生命周期

| Runtime 事件 | 来源 | 读取字段 | ACP 更新 | 用户看到 |
| --- | --- | --- | --- | --- |
| `run.accepted` | 暂定 | — | agentMessage + plan | 任务已受理（Run run_xxx） |
| `run.queued` | 暂定 | — | agentMessage + plan | 任务排队中，等待执行 |
| `run.started` | 已发（RunStore.swift `create`） | `kind`、`lifetime` | agentMessage + plan | 任务已开始（Run run_xxx）；`connection_scoped` 时加「编辑器断开后将停止输入」 |
| `run.waiting_approval` / `approval.required` | 暂定 | 无（受保护） | agentMessage + plan | 等待批准（未批准前不会执行）。真正的审批请求由线 S 发，这里只显示状态 |
| `run.waiting_input` / `question.asked` | 暂定 | 无（受保护） | agentMessage + plan | 等待回答一个问题。问题正文与选项不经投影器显示 |
| `run.resumed` | 暂定 | — | agentMessage + plan | 任务继续执行 |
| `unit.started` | 暂定（#50 F40-03） | `unitType` / `taskType`（仅标识符形状）、`index`、`total` | agentMessage + plan（执行项写单元名） | 开始执行单元：calculator.add。`goal` 等自由文本不显示 |
| `unit.ended` | 暂定 | `outcome`、`verification` | agentMessage | 执行单元结束：已执行（业务结果：未评估）／结果已验证／验证未通过／失败／已取消／结果待核实 |
| `stop.accepted` | 已发（ExecutionCoordinator `stop`） | `inFlight` | agentMessage + plan | 正在停止；有进行中的动作时加「（等待进行中的动作收尾）」 |
| `run.finishing` | 已发（同上，reason 为 finished/completed/exit*） | `inFlight` | agentMessage + plan | 正在收尾 |
| `run.quiescent` | 已发（`settle`） | — | agentMessage + plan | 已停止输入 |
| `run.ended` | 已发（`settle`、重启恢复） | `outcome`、`reason`、`unknownActions`（暂定）、`verification`（暂定） | 先补齐未结动作的 toolCallUpdate，再 agentMessage + plan | 见 3.3 |

plan 固定四项：受理任务 / 执行 / 停止输入并收尾 / 结果。状态随阶段推进；结果项在 unknown 时保持 `in_progress`「结果：待核实」，绝不打勾。

### 3.2 动作

toolCallId = `act:<runId>:<requestId>`，两段都经 `ACPRedactor.identifier`（调用方自选的 requestId 一律哈希）。标题 =「类别 — 状态」，如「点击 — 已执行，未验证」。

| Runtime 事件 | 来源 | 层级 `ACPActionLevel` | ACP 状态 | 标题后缀 |
| --- | --- | --- | --- | --- |
| `action.accepted` | 已发（Act.swift） | accepted | pending | 已受理（发 `toolCall`） |
| `action.dispatched` | 已发 | dispatched | in_progress | 已发出，等待执行结果 |
| `action.completed`，回执 dispatched + completed | 已发 | executed（验证 matched 时 verified） | completed | 已执行，未验证 |
| `action.completed`，回执 verification ∈ {matched, verified, passed, confirmed, succeeded} | 暂定（schema 现为 const `not_requested`） | verified | completed | 已验证成功 |
| 回执 verification ∈ {contradicted, mismatched, not_matched, failed, rejected} | 暂定 | contradicted | failed | 验证未通过 |
| `action.failed`，回执 not_dispatched | 已发 | refused(code) | failed | 未发出 |
| `action.failed`，回执 dispatched + failed | 已发 | refused(execution_failed) | failed | 执行失败 |
| `action.unknown`，或任何回执 delivery / execution 为 unknown | 已发 | unknown | in_progress | 结果待核实 |
| `action.refused` | 暂定（方案「Policy Rejected」） | refused(code，缺省 policy_rejected) | failed | 已拒绝 |
| `action.verified` | 暂定 | 按 `verification` 值：matched→verified，contradicted→contradicted，其余→executed | — | — |
| `verification.succeeded` / `verification.failed` | 暂定（方案 5.1） | verified / contradicted | completed / failed | 已验证成功 / 验证未通过 |
| （无结果事件）`run.ended` 时仍只到 accepted | 已发路径：G0 派发前拒绝 | refused(not_dispatched)；Run outcome 为 unknown 时为 unknown | failed | 未发出 |
| （无结果事件）`run.ended` 时已 dispatched | 已发路径：重启恢复 | unknown | in_progress | 结果待核实 |

规则：

- **回执优先于事件名。** 回执是 Runtime 的记录；`action.completed` 携带 `execution = failed` 的回执按失败显示，携带 `delivery = unknown` 的按待核实显示，未识别的轴组合一律待核实。
- **verified 需要投递与执行都成立**：回执 delivery 为 unknown 时即使写了 matched 也只显示待核实。
- **G0 窗口身份拒绝**（RuntimeService+Target.swift）在派发前抛错，事件流里只有 `action.accepted`，没有结果事件。`ACPProjectorSession` 记住未结动作，在 `run.ended` 时补一条「未发出」；如果错误详情带 `details.reason`，显示固定文案：window_gone「目标窗口已不在该桌面」、not_visible「目标窗口不可见」、occluded「目标窗口被其他窗口遮挡」、other_window_of_process_in_front「同一应用的另一个窗口在前面」、moved「目标窗口在发送时移动」、target_changed_during_dispatch「发送过程中目标发生变化，输入可能到达其他窗口」。遮挡窗口的 id、pid、应用名从不显示。
- 详情行（默认）：状态、投递 / 执行 / 验证三轴（有回执时）、业务结果（有字段时）、耗时（回执 `timing.acceptedAt → completedAt`，或 `elapsedMs`）、目标（`ref-xxxxxxxx`，windowId + elementRef 的字母哈希）、错误码、待核实提示。坐标、pid、windowId 原值不显示。

### 3.3 Run 结束文案

| outcome | Run kind | 文案 |
| --- | --- | --- |
| success，且事件报告 verification matched（暂定） | 任意 | 任务完成：结果已验证 |
| success | act 或未知 | 任务结束：已投递（业务结果：未评估）（docs/plan/06 §6.4：act 的 success 只表示投递） |
| success | unit / exec | 任务结束：已执行（业务结果：未评估） |
| failed | — | 任务结束：失败 |
| cancelled | — | 任务结束：已取消 |
| unknown、空、其他 | — | 任务结束：结果待核实（不会自动重试，请在 AgentDesktop 主窗口核实） |

追加：`unknownActions > 0` 时「N 个动作待核实」；`reason` 只按固定表翻译（owner_lost / connection_lost「编辑器连接已断开」、runtime_restarted「Runtime 已重启」、stopped 等「已请求停止」、global_stop「已全部停止」、超时类「超过时限」），表外原因不显示；见过 `run.started` 时追加「用时 N 秒」。

### 3.4 未识别事件

`agentThought("收到未识别的运行事件（<type>），未作处理")`。type 只有符合 `段.段` 小写形状时才回显，否则写「未知类型」（夹具 `unknown-types`：类型名里塞邮箱也不回显）。

### 3.5 ToolKind

| 动作 kind | ToolKind |
| --- | --- |
| observe、snapshot、read、wait | read |
| click、type、key、scroll、drag、launch、act | execute |
| submit、send*、publish、post、external_submit、outbound、upload、pay、*_submit | other（外部提交类，不当本地命令） |
| 其他 / 缺失 | other |

### 3.6 不由投影器产生的更新

- `sessionInfo`（会话标题）归线 S（`ACPSessionBinding.title`）；投影器不改会话标题，避免把 Run 信息写进标题。
- `turnEnded` / `promptFinished` 由线 S 按版本决定；投影器只描述 Run。
- 审批请求（`session/request_permission`）与提问（`elicitation/create`）由线 S 根据 `ACPRuntimePort.pending` 发起；投影器只显示「等待批准 / 等待回答」。线 S 构造审批摘要时须调用 `ACPRedactor.redact`。

## 四、数据分类与脱敏

### 4.1 字段分类（`ACPDataClassifier.classify(key:)`）

| 类 | 例子（键名，大小写与分隔符不计） | 默认 | pageText 打开 | screenshots 打开 |
| --- | --- | --- | --- | --- |
| code | kind、phase、outcome、delivery、execution、verification、businessResult、code、reason | 只显示固定词表的中文 | 同左 | 同左 |
| identifier | *Id、*Ref | 运行时形状 id 原样，其余哈希 | 同左 | 同左 |
| scalar | sequence、revision、windowId、x、y、pid、时间戳 | 只用于计算（耗时、目标哈希），不显示原值 | 同左 | 同左 |
| freeText | message、summary、description、goal、name，及所有未列出的键 | 不显示 | 只显示动作自身的 title（说明）与 summary（摘要），脱敏后；Runtime 错误 message 永不显示 | — |
| windowTitle | title、windowTitle | 不显示 | 仅绑定目标的标题，脱敏后显示 | — |
| pageText | label、value、elements、matches、content、ocr | 不显示 | 仅绑定目标的元素标签，脱敏后显示；elements / matches 列表不显示 | — |
| typedValue | text、input、typed、clipboard、paste、keys、params、arguments、args | **永不显示** | **永不显示** | **永不显示** |
| url | url、href、link、uri | 不显示 | 不显示（文本内链接一律 `[链接]`） | — |
| screenshot | image、screenshot、png、base64、bytes | 不显示 | 不显示 | 只显示 artifact 引用（「截图：art_xxx（在 AgentDesktop 主窗口查看）」），从不含字节，且图像 windowId 须等于绑定目标；`submit` 只对提交类动作显示 |
| credential | password、token、attachToken、secret、apiKey、cookie、authorization、*token | **永不显示** | **永不显示** | **永不显示** |
| withheld | 对象带 `sensitive: true`、`withheld: true`、`redacted: true` 或敏感 `dataClassification`；covering* / other* / foreign* / sibling* 字段 | **永不显示** | **永不显示** | **永不显示** |

Runtime 因缺少屏幕录制授权而给出 `title: null`（`contracts/fixtures/runtime/v1/window-title-withheld.valid.json`）时，放宽策略下也不出标题行（夹具 `privacy-window-title-withheld`）。

### 4.2 文本脱敏（`ACPRedactor.redact`）

对每一个离开投影器的自由文本（标题、元素标签、窗口标题、摘要；以及其他线经 `redact` 写日志的错误与参数）执行；**与策略无关**：放宽只决定哪些字段出现，不放松字段内容的遮盖。

| 顺序 | 识别 | 替换为 |
| --- | --- | --- |
| 0 | 全角数字、字母、＠＋－．转半角；换行、控制字符、格式字符变空格；超过 160 字截断加「…」 | — |
| 1 | `Bearer/Basic/token <值>`、`password= / 密码： / 验证码：` 等键值、JWT、sk-/ghp_/xox*/AKIA 等前缀密钥、32 位以上十六进制、40 位以上混合 base64 | `[凭据]` |
| 2 | http(s)/ftp/file/ws/smb/afp 链接、`www.` 开头 | `[链接]` |
| 3 | 邮箱（含 mailto:、裸主机名） | `[邮箱]` |
| 4 | 18 位居民身份证号（含出生日期校验形状、末位 X） | `[证件号]` |
| 5 | 中国大陆手机（可带 +86、空格、短横）、带 + 的国际号码、(555) 123-4567 形式、0xx-xxxxxxxx 座机 | `[电话]` |
| 6 | 4 位一组的卡号、7 位以上连续数字（银行卡、15 位旧身份证、QQ、账号） | `[数字]` |

投影器在输出前还对每个字符串再过一遍凭据、链接、邮箱规则（`guardOutput`，纵深防御）。

### 4.3 给其他工作线的接口

| 函数 | 用途 |
| --- | --- |
| `ACPRedactor.redact(_:)` / `ACPEventProjector.redact(_:policy:)` | 任何自由文本（审批摘要、提问、错误）在显示或记录前 |
| `ACPRedactor.redactJSON(_:policy:)` | 把整个 payload 按字段分类脱敏后写日志或存储 |
| `ACPRedactor.logLine(_ event:)` | 一行安全的事件日志 |
| `ACPRedactor.logSafe(_ error:)` | 错误描述写日志、崩溃报告前 |
| `ACPRedactor.identifier(_:)`、`errorCode(_:)` | 显示 id；把任意错误码收敛到 runtime/1 目录（目录外 → `unlisted_error`） |
| `ACPProjectorSession` | 每个 ACP 会话一个，按游标顺序喂事件；它记住动作类别、Run kind、开始时间和未结动作 |

## 五、测试

| 组 | 文件 | 内容 |
| --- | --- | --- |
| golden | `Events/ETestGoldenTests.swift` + `Fixtures/events/*.json`（15 份） | 每份夹具：合成输入事件、策略、逐事件的期望更新、`mustNotContain`（植入的个人信息）与 `mustContain`；所有输出另过一遍泄露正则。`ETEST_REGEN=1 swift test --filter ETestGoldenTests` 重写期望，提交前人工核对 |
| 三级结果 | `Events/ETestProjectorTests.swift` | accepted ≠ dispatched ≠ executed ≠ verified；只有 matched 才 verified；回执轴优先；unknown 不完成也不失败 |
| T19 | 同上 + 夹具 `privacy-t19-*` | 默认不出截图；`all` 只出引用不出字节；`submit` 只对提交类 |
| T20 | 同上 + `privacy-t19-t21-*` | 默认不出窗口标题、元素标签、摘要；放宽后脱敏显示 |
| T21 | 同上 | `Click send to candidate: example@email.com` 在任何策略下输出都不含邮箱；输入内容永不出现；坐标、pid、windowId 不出现 |
| 脱敏 | `Privacy/ETestRedactorTests.swift` | 28 条样例、单行与截断、策略不放松遮盖、id 哈希、错误码目录覆盖 errors.json 全部 40 个码、字段分类、`redactJSON`、`logLine` |
| 健壮 | 同上 | 每个目录类型 × 多种畸形 payload 不崩溃；未识别类型只产生 thought |
| 三级与跨应用 | `Events/ETestProjectorTests.swift` + 夹具 `privacy-cross-app` | 每种事件与字段类有级别；截图、窗口标题、输入内容、审批参数四类各一条测试；带 sensitive 标记的动作只剩状态 |

## 六、需要 f1 补的契约（schema 缺口）

| 编号 | 缺口 | 现状与影响 | 建议 |
| --- | --- | --- | --- |
| E-1 | 回执没有验证结果 | `ActionReceipt.verification` 是 const `not_requested`，所以今天任何动作都到不了「已验证」 | 定义 verification 枚举（建议 `not_requested / pending / matched / contradicted / inconclusive`）与产生它的事件（`action.verified` 或 unit 的验证事件），并说明谁有资格写 |
| E-2 | 派发前拒绝不产生结果事件 | G0 窗口身份拒绝、stale_observation、deadline 在 `action.accepted` 之后抛错，事件流里没有 `action.failed`；投影器只能在 `run.ended` 时推断「未发出」，且拿不到错误码与 `details.reason` | 派发前拒绝也发 `action.failed`（回执 `delivery = not_dispatched`）或新事件 `action.refused`，data 带 `error.code` 与 `details.reason` |
| E-3 | 结果事件不带错误码 | `action.failed` / `action.unknown` 的 data 只有回执；错误码只在 RPC 响应里，订阅事件的观察者（ACP 会话恢复后）看不到 | 结果事件 data 增加 `error: {code, details.reason}`（不含 message） |
| E-4 | `run.ended` 不带 kind、unknownActions、verification | 投影器需要 `run.started` 的上下文才能区分 act 的「已投递」；会话恢复时游标在 `run.started` 之后就只能按 act 的保守文案显示 | `run.ended` data 增加 `kind`、`unknownActions`；unit Run 增加单元验证结论 |
| E-5 | 排队、单元、审批、提问、策略拒绝事件不存在 | C-10；映射已按暂定名实现 | F1-01 冻结时给出正式名称与 data 字段；本文与夹具随之对齐 |
| E-6 | RunEvent.type 是自由字符串 | GAP-08；没有目录就无法在 schema 层拒绝未知类型 | F1-01 把 type 收为枚举（允许扩展前缀） |
| E-7 | 事件 data 没有敏感标记 | 今天靠键名分类；未来若在 data 里放标题、标签、摘要，需要显式 `sensitive` / `dataClassification` | 约定事件 data 中可能含个人信息的字段一律带分类标记，或只放引用（artifact id） |
| E-9 | 截图没有采集范围 | `ImageArtifact` 没有 windowId 或 scope（window / screen），投影器无法证明一张图只含绑定窗口，所以今天即使 `screenshots = all` 也不会显示任何截图引用 | `ImageArtifact` 增加 `scope` 与 `windowId`（及 binding generation） |
| E-10 | 事件没有分级字段 | 三级分级今天由 ACP 按事件类型与键名推断 | F1-01 给每个事件类型标注级别，data 字段标注分类，ACP 以契约为准 |
| E-8 | `run.ended.reason` 是自由字符串 | 已见 completed、finished、exit*、stopped、global_stop、owner_lost、runtime_restarted | 收为枚举；投影器对表外值不显示 |

## 七、需要协调者决定或调整的接口

1. `ACPActionLevel` 没有「派发后执行失败」：现在用 `refused(code: "execution_failed")` 表示，名称不贴切。建议增加 `.failed(code:)`。
2. `ACPEventProjector.project` 无状态，动作的后续事件拿不到类别、Run 结束拿不到 Run kind。已提供 `ACPProjectorSession`（值类型，内含 `ACPEventContext`）作为补充，不改协议；线 S 应每会话持有一个。若希望协议本身带上下文，可把 `project(_:policy:context:)` 提到协议里。
3. `ACPToolCall` 的 `title` / `kind` 在更新里是必填：无上下文时后续更新只能写「界面动作」，可能覆盖编辑器已显示的类别。建议线 T 在 toolCallUpdate 里只发变化的字段，或把这两个字段改为可选。
4. 夹具 JSON 位于测试 target 内，SwiftPM 报「found 14 file(s) which are unhandled」警告（线 T 的 Fixtures/acp-schema 同样）。建议协调者在 `Package.swift` 的 `AgentDesktopACPTests` 加 `exclude: ["Fixtures"]`。
5. unknown 动作的 ACP 状态选 `in_progress`（不选 failed，避免诱导重试；不选 completed）。代价是编辑器里会一直转圈；如果 Kevin 更希望显示终态，可改为 failed 并保留「待核实」标题。

## 八、待 Kevin 确认

- 放宽 `pageText` 后，页面文字里的邮箱、电话仍被遮盖（策略只扩大字段范围，不放松遮盖）。这让「看页面文字」对招聘类场景用处有限，但符合「默认最严、凭据永不外发」。若需要「看到原文」，应是单独的、带审计的开关，而不是 pageText。
- 人名无法可靠识别：放宽后绑定目标的窗口标题若含人名（如「候选人 张三 简历」），人名会出现（证件号、电话、邮箱仍被遮盖）。默认策略下不出现。
