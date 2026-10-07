# Agent Desktop 产品功能与执行规划

_独立产品首发 业务应用接入 两仓实施与验收_

路线版本 3    更新日期 2026年10月7日    代码审阅基线 7a96154

**产品决定**

Agent Desktop 独立发布，提供通用任务、工作屏、执行控制、审批与结果。BOSS、微信、小红书各自作为业务应用发布，也可作为插件接入；所有产品复用同一套Runtime、SDK和2ndscreen原生能力。业务应用无需预装或打开Desktop主应用。

本版将首发拆成12项功能与接入要求，增加阶段0、两仓工作项、首个十个工作日的安排及明确验收。先交付可完成真实通用任务的macOS产品，同时在首发前用同一中性Agent包验证独立应用与插件两种形态；完整BOSS迁移按业务产品自己的进度推进。

第一里程碑是可构建、可识别、路由正确的新App宿主；公开测试版的里程碑是用户可独立完成任务、看见执行、接管控制并拿到有效结果。现有原生与Runtime资产继续复用，代码事实及历史验证保留在附录。

## 一 产品定位与边界

Agent Desktop 的核心价值是让用户把支持范围内的桌面任务交给 Agent，同时看见执行过程、控制权限与成本、随时暂停接管，并确认交付结果。首批用户建议为愿意配置模型或安装 Agent 的 AI 重度用户与 Agent 开发者；随着独立业务应用成熟，再扩展到招聘、运营等垂直用户。

| 名称 | 定位 | 交付边界 |
| --- | --- | --- |
| Agent Desktop | 面向用户的独立产品 | 安装包、主界面、工作屏、Agent 管理、任务、审批、结果、设置和更新。 |
| Agent Screen | 产品内的工作屏概念 | 用于展示 Agent 操作的屏幕与窗口，不另设一套执行底座。 |
| 2ndscreen Engine | 平台底层技术 | 虚拟显示、窗口、输入、AX/UIA、截图、OCR和原生适配。 |
| Agent Runtime 与 SDK | 公共执行服务与接入工具 | 任务协议、进程托管、租约、审批、预算、产物、诊断；支持两种产品形态。 |
| 业务 Agent | 独立应用与可安装插件 | BOSS、微信、小红书各自拥有业务核心、界面、账号流程、领域数据和发布节奏。 |

本路线不再保留永久内置的 BOSS 业务例外。此前 RFC 与代码中的 builtin BOSS 是迁移来源；通用平台可以自带不依赖具体商业平台的参考 Agent，业务 Agent 则使用独立包和版本。现有 SwiftPM 库与 process Agent 协议可继续作为实现基础。[S02][S24][S40][S41]

### 产品独立性的判断

- Agent Desktop 不安装任何业务 Agent 时，仍能完成受支持的通用桌面任务和中性示例。
- 用户只安装一个独立业务应用，也能完成它的工作、处理审批和接管窗口。
- 同一个业务 Agent 的插件形态与独立应用形态复用同一业务核心，不维护两套流程。
- 业务 Agent 升级不要求重新发布 Agent Desktop；核心协议变更有版本与兼容期。
## 二 目标架构与职责

目标结构分为产品界面、业务执行体和共享执行服务。Agent Desktop 主界面及独立业务应用通过客户端 SDK 提交和管理任务；业务 Agent 使用进程协议向 Runtime 请求能力；Runtime 再调用原生引擎。业务代码不加载到 Desktop 的主进程，也不复制一份平台调度器。以下为拟建结构，当前尚未具备完整的跨应用 Runtime 分发与发现机制。

| 组件 | 承担的职责 | 明确移出的职责 |
| --- | --- | --- |
| Agent Desktop App | 工作屏、任务工作区、Agent列表、授权审批、结果和更新 | 岗位、候选人、会话策略、内容选题等业务判断。 |
| 共享 Runtime | 会话所有权、任务状态、Agent进程、统一动作控制、预算、日志和恢复 | 各平台业务流程与业务数据库。 |
| 2ndscreen Engine | 原生屏幕、窗口、输入、截图、可访问性和视觉能力 | 业务策略与Agent专属生命周期。 |
| Client SDK 与公共组件 | 连接发现、版本协商、任务与事件、预览、接管、可信审批入口 | 复制底层执行、预算或独立调度代码。 |
| 业务 Agent Core | 任务拆解、领域规则、应用定位、业务验收、服务端对接 | 直接绕开Runtime操作桌面或自批平台权限。 |
| 独立 App Shell 与插件声明 | 前者提供独立品牌界面；后者声明输入表单、状态和结果视图 | 分别实现一份不同的业务工作流。 |

同机共享的是执行能力与受控资源，不是业务数据库或登录身份。任务、授权、日志、输出目录和事件订阅按 Agent 与账号作用域隔离；用户明确接入后，Desktop 才显示相应任务。运行在同一用户权限下的子进程仍不构成操作系统沙箱，首发只接入可信、固定版本的执行包。[S01][S02]

### 能力共享不等于界面统一

例如，BOSS 独立应用可以展示岗位、候选人和简历列表；作为插件时，同一业务核心把这些任务和结果投射到 Agent Desktop 的工作区。两者使用相同的屏幕管理、暂停接管、审批与模型预算能力。Agent Desktop 不需要把招聘数据模型变成平台的数据模型。

## 三 独立应用与插件的运行方式

| 项目 | Agent Desktop 插件模式 | 业务独立应用模式 |
| --- | --- | --- |
| 用户入口 | 从Desktop安装并打开Agent | 直接安装并打开业务应用 |
| 业务代码 | 独立Agent包，由Runtime作为进程托管 | 同一Agent包，由业务App通过Runtime启动 |
| Runtime来源 | Desktop安装包提供或复用兼容组件 | 业务安装包提供签名组件，或发现并复用兼容组件 |
| 是否需要Desktop界面 | 使用Desktop界面 | 不要求安装或打开Desktop |
| 任务展示 | Desktop统一任务、预览、结果视图 | 业务App使用SDK与公共组件展示同一任务状态 |
| 审批与接管 | 平台可信界面呈现 | 使用相同可信审批服务和接管协议 |
| 发布与更新 | Agent包独立版本 | 业务应用与Agent包独立版本；Runtime按兼容规则维护 |

### 共享 Runtime 的安装与发现

推荐由平台维护一个有固定签名身份的通用 Runtime 发行物。Desktop 和业务应用都可以携带它；业务应用首次运行时检查版本与完整性，按明确的安装流程启用兼容组件。用户没有 Desktop 时，也能看到权限说明、任务运行指示、紧急停止和审批。这里“独立”指不依赖另一个产品的主应用，不表示必须在每个业务进程内再运行一份显示和调度引擎。

同一系统用户的桌面会话由一个活动协调者管理。多个产品同时连接时，按应用/进程/窗口资源取得租约；首发串行运行桌面任务。不同 Runtime 版本可以保留在磁盘上，但不能各自抢占同一应用。版本不兼容时返回明确的升级或等待结果，不能悄悄启动第二个互不知情的执行器。现有 actor身份、worker确认与租约代码可复用，跨产品发现与版本仲裁仍需新建。[S43]

本地连接需要验证调用应用的进程与签名身份，并检查它可访问的任务作用域；不能只信任客户端自报的Agent名称或同一系统用户身份。服务启动、退出和卸载均需确认本地接口的当前所有者。现有ControlServer启动与停止时直接unlink路径，扩展到多产品之前需改成有所有权校验的实例管理。[S50]

升级应等待任务空闲，必要时先明确停止任务；卸载一个产品不能删除其他产品仍使用的共享组件。移除最后一个使用者时，单独处理后台组件和用户数据。任务状态、输出与业务授权的迁移需要版本控制；回滚程序版本不能盲目回滚已产生的业务记录。

### 第一阶段必须验证的原生安装问题

独立应用的bundle identity、原生helper签名、后台生命周期和系统权限需要在目标Mac上验证。Apple的后台服务管理与权限归因使helper结构、启动方式和稳定签名成为安装设计的一部分。共享Runtime不代表跳过系统授权，也不能预先承诺所有产品只需授权一次。第1至2周就应使用两个不同应用身份的测试壳，采用拟发布签名与helper启动模式，验证屏幕录制、辅助功能、私有接口、hardened runtime和公证试包，再验证并存、升级与卸载。[S47][S48][S49]

允许业务应用直接嵌入原生库作为后续高级 SDK 选项，但首轮默认采用共享服务方式。直接嵌入会使每个应用独自承担签名、权限、升级和跨应用资源冲突验证，不宜成为第一批业务产品各自复制底座的理由。

## 四 第一版通用能力契约

SDK 首轮采用现有 process/JSONL 协议作为业务执行体边界，另提供面向产品界面的连接与控制客户端。TypeScript 与 Python 优先，Swift 提供客户端或轻量桥接。所有执行方式经过同一套受管 Session；底层开发 CLI/MCP 可保留，但产品默认工具不能暴露绕过策略的路径。[S17][S40][S41]

| 能力 | 平台提供的契约 | 业务 Agent 提供的内容 |
| --- | --- | --- |
| 屏幕与会话 | 创建工作屏、绑定应用、能力查询、资源租约、预览与释放 | 目标应用和已验证的版本/窗口配置 |
| 观察与动作 | 截图、AX/OCR、点击输入等待、动作回执与目标校验 | 页面定位、动作意图和预期后置条件 |
| 任务控制 | 提交、事件、暂停、取消、恢复、超时与崩溃恢复 | 任务输入、业务步骤和可恢复检查点 |
| 授权与审批 | 作用域、具体动作绑定、有效期、额度、拒绝和撤销 | 需要的能力、账号、目标和业务影响说明 |
| 模型与学习 | provider配置、预算预留、用量、单元回放、局部恢复、受限探索 | 任务提示、业务单元、领域验证规则 |
| 产物与结果 | 文件完整性、来源、hash、存储与提交回执 | 业务结果结构及领域验收证据 |
| 分发与兼容 | 清单校验、包hash与签名、固定版本、兼容检查、停用回滚 | 独立包、支持模式、输入和结果声明 |
| 诊断与数据 | 按任务关联事件、脱敏导出、保留与删除控制 | 业务错误分类及必要的领域诊断 |

清单最低字段建议包括 Agent 身份和版本、发布者、支持平台、Runtime兼容范围、task/resident模式、执行入口、输入输出schema、应用与能力声明、模型需求，以及可选界面声明。接口名称与schema需在实现里冻结；上表是目标契约，不代表相关SDK已经交付。

通用 Runtime 验证文件字节、来源和提交过程；业务 Agent 验证简历是否属于目标候选人、内容是否符合任务要求等领域事实。界面同时显示平台验证与业务验收依据，不能把进程正常退出或Agent自报完成直接等同于有效交付。当前外部Agent的控制和产物语义仍需补齐。[S28][S29][S30]

可信审批界面由平台组件提供，业务执行进程只可发起请求，不能持有自批权限。独立应用的自定义UI可以描述业务上下文，但最后的授权决定必须绑定真实动作与任务，并经平台信任通道产生。

## 五 产品功能与版本范围

首发面向愿意配置模型、希望让Agent处理桌面任务的用户，以及需要接入桌面执行能力的开发者。建议先做Apple silicon上的macOS公开测试版，明确实际验收过的系统、浏览器和应用版本。引擎的最低部署版本不能替代产品支持矩阵。

优先级定义：P0是公开测试版必须达到的范围；P1是共享能力稳定后的业务接入与体验扩展；P2在出现明确需求并通过相应原生验证后启动。功能编号用于开发和验收追踪，不代表已交付。

### 用户首日完成的任务

主任务建议为：用户选择受支持浏览器中的页面，交给官方桌面助手提取可见信息，生成一份包含来源截图和文字依据的本地结果。辅助回归任务为：在受控演示应用中填写并核对本地表单。两者均通过公开process协议和受管执行路径运行，不依赖招聘账号。

| 步骤 | 用户体验 | 系统完成依据 |
| --- | --- | --- |
| 准备 | 打开App，检查权限和模型连接，选择输出位置 | 拒绝权限、模型不可用时仍可查看帮助并重新检测 |
| 发起 | 选择官方助手、任务模板和目标窗口，确认任务范围与预算 | 目标唯一、范围受支持、资源可用后才启动 |
| 执行 | 查看工作屏、当前步骤、等待原因和用量 | 显示真实任务事件，不编造百分比或隐藏离线状态 |
| 介入 | 批准具体动作、回答问题、暂停或接管窗口 | 执行者停止后才表示已暂停或交还；未知效果单独保留 |
| 交付 | 打开本地结果，查看来源与验证情况 | 必须产物有效；部分成功和失败有可理解说明 |
| 再用 | 查看历史，用相同模板发起下一任务 | 建立新的任务记录；上次结果不明的动作不自动重发 |

### P0 面向用户的十项功能

| 编号与功能 | 首发范围 | 验收标准 |
| --- | --- | --- |
| F01 安装与首次使用 | 完整App安装包；系统、Runtime、权限与模型检测；入门任务；密钥受系统凭据机制保护 | 无需Node、Python或Homebrew；按向导完成首次任务；权限拒绝可恢复 |
| F02 工作屏与应用 | 选择受支持应用/窗口；创建工作屏；预览、缩放与窗口归属；释放回主屏 | 预览对应目标；关闭/接管解除跟随；目标窗口无法确认时停止输入 |
| F03 新建任务 | 官方中性助手；自然语言目标结合少量模板；目标、输出、预算与任务范围确认 | 任务经公共客户端接口提交、经Agent进程协议执行；不要求业务账号；未支持的范围在启动前说明 |
| F04 任务工作台 | 运行、排队和历史任务；详情、当前步骤、等待原因、心跳与操作记录 | 外部任务统一查询；App重开状态可解释；失联不继续显示正常执行 |
| F05 控制与人工接管 | 按任务暂停、继续、取消；本会话紧急停止；接管与恢复前核对 | 排队/运行/等待审批时取消均有效；确认停止后无新动作；不会将停止整个host伪装成取消一个任务 |
| F06 待处理与权限 | 动作审批、问答、登录等待；授权列表、有效期与撤销；决定历史 | 审批绑定任务、动作、目标与有效期；拒绝、撤销、已消费和重复批准有明确结果 |
| F07 模型配置与用量 | 首批经验证provider与模型；用户自带密钥；每任务调用/token限额；用量与已知费用 | 配置实际传入执行；调用前限额生效；未知token/费用不按0显示；零模型仍允许确定性步骤 |
| F08 结果与历史 | 结果摘要、文件打开、来源截图、平台验证与业务验收；部分成功说明；再次运行 | 必需文件缺失、越界或校验失败不能算有效成功；重复采纳不覆盖用户文件 |
| F09 Agent安装与管理 | 官方助手及少量可信包；本地导入、能力与版本展示、启停和兼容检查 | 同一公开协议执行；不兼容包不启动；禁用/卸载明确处理活跃任务；版本可追溯 |
| F10 设置与支持 | 预算与授权、数据保留/删除、脱敏诊断、版本与更新提示、帮助与反馈 | 诊断可关联任务且不包含明文密钥；更新前确认任务空闲；手动升级和恢复路径可用 |

F03先聚焦少量可重复的任务模板，不把任意应用任意任务自动化写成首发能力。F09提供受控包接入，不在首发建设公开市场。F10允许先提供可靠的手动更新及版本提示，自动下载、差分更新与市场交易后续扩展。

工作屏仍处于当前macOS会话。首发只运行一个活动桌面任务，并按目标进程占用资源；同一应用的其他窗口可能争用输入。遇到目标变化时暂停并要求重新确认，应用选择界面应说明已验证的窗口组合和使用限制。[S18][S19][S26]

### P0 接入与通用性两项要求

| 编号与能力 | 首发范围 | 验收标准 |
| --- | --- | --- |
| F11 受管CLI和MCP | 至少一个文档化接入样例，创建、查询、取消任务并获取结果；明确原生开发工具与产品受管入口 | 已验证客户端版本真实跑通；与GUI使用同一控制、预算与产物契约；默认工具不绕开检查 |
| F12 双形态SDK预览 | 最小产品客户端SDK；同一中性Agent包分别由Desktop和独立测试App使用；两个不同App身份 | 没有Desktop主应用也能启用Runtime、执行、审批和接管；共存不重复控制；退出/卸载一个不破坏另一个 |

F12的原型在第1至2周验证；首发前完成受支持安装组合的最小闭环，发布时仍可标SDK预览。第9至12周再扩大兼容矩阵、稳定开发者体验并接入真实业务。这将此前集中放到后期的双形态工作拆成早期验证、首发基本可用、后期稳定三个阶段。

### 界面组织与交互规则

| 入口 | 主要内容 | 关键规则 |
| --- | --- | --- |
| 任务主页 | 新建任务、当前任务、排队与历史；任务详情内含预览、过程、结果和用量 | 默认进入这里；任务有唯一ID；进度和按钮能力来自Runtime |
| Agent | 已安装包、官方样例、能力、版本、启停与导入 | 业务输入由schema描述；首发不加载任意第三方代码面板 |
| 待处理 | 审批、问题、登录与人工核对；按任务关联 | 展示具体目标与动作；业务进程不能自己批准请求 |
| 设置 | 模型、权限、预算、数据、Runtime状态、更新与诊断 | 内部协议和路径放高级诊断，不要求用户填写开发环境变量 |
| 菜单栏 | 运行状态、打开主窗口、暂停/紧急停止与退出 | 保留快速控制；独立产品有清楚的主窗口和Dock入口 |

关闭主窗口与退出产品分开处理：关闭窗口可保持任务运行，并保留可见运行指示；退出时明确处理本产品的活跃任务并释放其资源。共享Runtime不得因一个客户端退出而直接结束另一个客户端的任务。

暂停中、已暂停、停止中和已停止分别显示。发生崩溃时先显示中断或需要核对；恢复前重新观察应用、账号和页面。首发的继续仅支持已定义的安全检查点；其他中断提供检查后的重新提交，不承诺任意步骤自动续跑。

### P1和P2的后续功能

| 优先级 | 功能 | 启动依据 |
| --- | --- | --- |
| P1 | SDK稳定版、完善TS/Python样例；将独立App引导和升级扩展到真实业务及更广版本矩阵 | F12/T10最小安装、共存与升级已通过，再扩大兼容承诺 |
| P1 | BOSS独立App和插件、第二个真实业务Agent | 使用相同核心与SDK；业务结果独立验收；无需核心新增业务判断 |
| P1 | 模板保存、学习单元版本、失效解释与回退 | 回放已经过受管动作和统一预算 |
| P1 | 常驻Agent管理、有限触发与定时任务 | 任务级取消、恢复检查点及unknown核对完整 |
| P1 | 更多可信包、包更新与更丰富的声明式结果 | 真实用户需要且兼容策略稳定 |
| P2 | Windows完整产品、Android与iPhone可选适配 | 相应平台与安装包重新验收，现有缺陷先处理 |
| P2 | 多任务并行、任意插件面板、公开市场、ACP、企业多设备 | 分别有采用需求，并通过资源冲突、信任与维护门槛 |

## 六 业务 Agent 的产品路线

每个业务Agent拥有独立产品目标、业务核心与发布周期，可提供独立应用和Desktop插件两种入口。平台只维护共同能力与协议，不把具体业务的客户、数据模型或付费关系变成平台的前置条件。

| 业务应用 | 建议首个范围 | 用来验证的通用性 |
| --- | --- | --- |
| BOSS Agent | 已有会话简历采集与核验；后续外发动作另行验收 | 从内置实现迁出业务类型、流程和结果格式；独立App与插件同源 |
| 微信 Agent | 一个明确授权、目标可核对的会话或联系人任务 | 第二个应用与账号模型；在不改核心业务分支的情况下接入 |
| 小红书 Agent | 先内容整理、草稿准备与人工检查；发布动作单独设计 | 新应用适配、编辑型任务、富结果视图与外发审批 |
| 其他 Agent | 围绕单一用户任务定义输入、效果与完成依据 | 复用同一SDK和Runtime，独立更新与分发 |

上述业务范围是路线建议，不是现有接入完成度声明。独立BOSS仓库当前内容未能通过现有连接核对，微信的最新实现亦未在本轮重新审阅；业务应用排期应在各自仓库完成差异核对后细化。

BOSS相关页面识别、候选人模型、简历清单和采集runner应进入独立业务包。通用文件校验、租约、模型预算、回放与受管动作继续留在平台。现有BOSS资产可以保留原语言与实现方式，通过适配协议接入；不需要仅为“拆分”而重写所有算法或重新移植语言。[S42][S44][S45]

## 七 仓库与迁移安排

| 仓库或包 | 建议归属 | 迁移验收 |
| --- | --- | --- |
| 2ndscreen | 原生引擎、通用Runtime、协议及底层SDK；以tag发布 | 无BOSS生产依赖时可构建和运行；保留原生测试 |
| agentdesktop | 独立产品App、品牌、UI、安装更新和官网发布材料 | 按版本依赖核心，不fork引擎；可单独发布 |
| 业务Agent仓库 | 每个业务一个仓库，含Agent Core、独立App Shell与插件声明 | 两种入口使用同一业务核心；更新不重发Desktop |
| SDK发布包 | 首阶段与通用Runtime同仓开发，独立版本化发布 | 契约测试验证TS/Python及产品客户端兼容 |
| Agent目录与组织配置 | 先少量可信包；有实际需求后独立索引与组织服务 | 平台启动不依赖某个业务应用或组织账号 |

Agent Desktop使用独立产品仓agentdesktop；核心内部暂不再拆出大量小仓库。先完成依赖方向、构建与发布边界，再按维护规模拆包。现有库名与CLI命令保留兼容；调整默认分支和包名另行集中安排。

### BOSS外置分两步完成

第一步解除平台默认依赖：把BOSS工作流、领域runner和schema移入明确的业务包或兼容区，移除通用worker对它的固定注册与直接构造，产品包不再复制boss-resumes。通用外部Host成为产品任务的主要执行路径，中性Agent证明其独立可用。此步是平台首发门槛。[S41][S42][S46]

第二步在独立BOSS项目完成业务整合：将已有采集能力接到SDK与Runtime，复用验证过的领域规则，形成独立App和插件声明。可以先将现有业务runner作为独立Agent内部实现，再逐步清理重复基础设施；不要求平台先成为能够表达任意业务的万能workflow系统。完整BOSS功能通过自己的产品验收后发布。

通用任务输入不再固定为CollectResumesInput，账号模型不再限定platform=boss；招聘清单归业务Agent，平台Artifact接口保留通用内容验证。兼容旧任务记录时应保留原始证据，标明需要旧业务包或迁移处理，不能静默丢弃历史。迁移前后的BOSS有效产物、去重与零模型回放语义需要对照验收。[S44][S45]

## 八 分阶段执行计划

沿用阶段0至阶段3的命名，补阶段4做真实业务和SDK稳定。工期采用相对周，假设2名全职平台工程师分别负责macOS客户端/原生与Runtime/SDK，并有产品和QA支持；业务接入另有可复用代码及业务开发支持。第6至8周公开测试是目标窗口，需在阶段0和早期签名试包后按真实工作量重新校准。

相对周和工作日均从阶段0启动当天计。阶段0的1至3工作日计入第1周，与阶段1的契约梳理并行，不另加在十二周之前。阶段0未通过的产品构建和路由问题会影响后续客户端工作的开始时间。

| 阶段 | 主要交付 | 阶段出口 |
| --- | --- | --- |
| 0 宿主骨架
约1至3工作日 | 新agentdesktop仓库、App身份、精确依赖与CI；裁剪旧UI；包内CLI；路由与实例检查 | 干净checkout可构建；真实新App响应create/list/destroy和截图；包无Android默认依赖与开发路径 |
| 1 边界与原型
第1至2周 | 无BOSS默认构建；公共任务契约；R1至R5修复与R6语义回归；外部控制、产物、队列；双App签名原型 | 中性任务在公共执行路径可控；关键回归通过；拟发布身份/helper权限与公证试包有目标机证据 |
| 2 产品内测
第3至4周 | F01至F10串成完整用户任务；官方参考包；F11/F12接入预览；5至10人定向试用 | 用户无需开发命令完成首日任务；暂停、审批、预算、结果连通；失败路径有明确下一步 |
| 3 公开测试
第5至8周 | F01至F12完成首发范围；正式包、支持矩阵、帮助、更新恢复与诊断；双形态最小安装验收 | 发布包可独立下载使用；公共执行门槛全部通过；独立测试App无Desktop也能运行；SDK预览范围明确 |
| 4 业务与SDK稳定
第9至12周目标 | BOSS双形态接入、第二个独立业务Agent、SDK文档与兼容矩阵扩展 | 两个业务使用同一公共能力；业务升级不重发Desktop；据稳定性和重复使用决定1.0 |

阶段0的半天至一天只宜估算仓库骨架；真实安装包、正确路由、权限和共存验收需要单独安排。上述1至3工作日仍是计划估算。阶段1中风险修复与原生服务可以并行，复杂项如超出两周应调整后续日期，不用已完成的界面代替未完成的执行能力。

### 阶段0的具体安排

- 建立agentdesktop产品仓与独立主线；产品版本独立于引擎版本，内部构建可从0.1.0-dev开始。Package.swift用exact固定已存在的0.2.0，并提交Package.resolved。
- 只移植必要的App装配、菜单、热键与预览连接，记录来源SHA；裁掉Android启动、菜单、fallback和打包资源。原生显示、输入和通用执行继续依赖公开库。
- 优先使用产品包内的2ndscreen CLI。若依赖图不能直接构建该可执行产品，进入已解析且版本受控的依赖checkout构建；CLI、Runtime、Node版本与来源写入产物清单。
- 先以独立测试endpoint验证新宿主及CLI，明确UI主进程和后台/侧实例角色。阶段0不让测试副本同时操作真实业务应用；共享协调者原型随后接管资源仲裁。
- v0.2.0只能代表当时已有能力。不带skills的上游选项须发布新tag后使用；新tag未就绪时可先交App与CLI宿主，任务功能保持未开放，不能篡改旧tag或偷偷修改依赖checkout。
- 准备中文README、边界文档、产品功能矩阵、阶段0验收记录及macOS CI。工程文档只归档必要决策与证据，不把完整私有工作区复制到公开引擎仓。
SwiftPM的from定义版本范围，Package.resolved记录解析结果；产品对可复现发行的要求可用exact进一步固定。产品CI与发布构建应拒绝本地editable覆盖，并记录实际解析提交。核心脚本变更合并后先发布新tag，再更新产品依赖。[S53][S54]

### 两仓工作项与依赖

以下C代表2ndscreen核心仓，A代表agentdesktop产品仓；它们是建议工作项编号，不是已创建的PR。一个工作项可拆成几个小PR，以单一可观察行为为验收边界。

| 工作项 | 主要变更与归属 | 前置与完成依据 |
| --- | --- | --- |
| A01 产品骨架 | agentdesktop：App身份、依赖、必要UI移植、构建与CI | 先用现有tag；明确只交宿主原型 |
| C01 通用发行装配 | 2ndscreen：skills可选、通用入口、BOSS注册/runner/schema与产物格式外置 | 删除业务包仍能构建启动；依赖图与包内无BOSS生产代码 |
| C02 共享服务原型 | 2ndscreen：实例锁、endpoint所有权、客户端身份/作用域、发现与版本握手；独立测试壳 | 与C01并行；两App、拟发布签名与helper验证；不把共享路径当仲裁 |
| C03 任务查询与控制 | 2ndscreen：统一task读模型、能力标志、按任务取消/暂停意图、执行停止回执 | C01；保留历史两表兼容读取；取消不误停其他任务 |
| C04 动作与预算 | 2ndscreen：审批绑定/确认链、持久unknown、受管回放、调用前预算与任务配置 | C03标识契约；R1至R5与零模型语义回归；provider和探索共用限额 |
| C05 产物与调度 | 2ndscreen：业务无关的文件采纳/验证；跨Agent全局队列；接管与恢复检查点 | C03/C04；无效产物不能成功；仅一个活动桌面任务 |
| A02 完整任务界面 | agentdesktop：F01至F08、主窗口/菜单栏、真实状态与结果、模型凭据配置 | C03后可先做只读；写操作按C04/C05能力合入开放 |
| C06 参考Agent与接入 | 2ndscreen：公共协议中性样例、最小客户端SDK、受管CLI/MCP与双形态测试 | C02至C05；同一包在两入口运行，不走官方特例 |
| A03 Agent与支持 | agentdesktop：F09/F10、接入说明、可信包导入、版本、权限撤销和诊断 | C06；首发安装/停用/兼容回退有真实执行验收 |
| C07 通用发行候选 | 2ndscreen：固定Runtime/helper发行物、升级与卸载、必要兼容调整 | 核心回归、双App安装和目标机试包通过，再发布核心tag |
| A04 公开测试包 | agentdesktop：更新核心版本、完整包、签名公证、干净安装、帮助与下载材料 | 消费C07最终tag；公开测试验收集全部完成 |
| B01与B02 业务接入 | 各业务仓：BOSS与第二个Agent独立App/插件，业务数据与流程各自负责 | 公共SDK可用后推进；产品与业务结果独立验收 |

公共动作修复宜拆成审批绑定、unknown持久化、回放入口和预算等独立PR，先补复现对应的回归。不要为界面在产品仓再写一套调度、状态库或预算器。各界面通过薄TaskClient读取结构化JSON与控制结果；以后更换底层传输时保留产品接口。

跨仓交付顺序为：核心接口和修复合并 → 核心验证及新tag → 产品依赖升级 → 实际安装包验收。UI可在接口约定后并行开发，只有真实事件与失败路径连通后才把功能标为完成。CLI/MCP命令语义尽量兼容；新任务控制和能力协商需要时采用版本化扩展，不把零改动作为优先于正确性的约束。

### 首个十个工作日

| 时间 | 客户端与原生负责人 | Runtime与SDK负责人 | 共同检查点 |
| --- | --- | --- | --- |
| 第1至2日 | App骨架、身份、精确依赖、主/Agent屏编号与CLI打包 | 冻结task读模型、能力和结果契约；列BOSS默认依赖及安装资源 | 新App响应者可识别；提交首发功能/验收清单 |
| 第3至5日 | 原生宿主路由、endpoint owner与权限试包；主窗口原型 | C01与按任务取消；审批/预算等真实问题拆PR | App/CLI/worker指向相同服务；无业务资源的真实host启动 |
| 第6至8日 | 接管与预览；第二应用身份及Runtime发现原型 | 受管动作、unknown、模型限额、产物采纳与全局排队 | 中性任务执行、取消和有效结果；关键负向用例 |
| 第9至10日 | 安装向导、任务详情接真实事件；试包复核 | 两种入口同一参考包；SDK样例与异常恢复记录 | 演示首日任务；依据真实缺口重排第3至4周工作 |

这张表规定顺序和检查点，并不承诺全部公共缺口在十天内关闭。产品负责人负责范围与任务样本，工程师各自交代码和证据，QA维护最小验收集；跨入口变化每次只合入一组完整行为，避免多个不兼容接口同时进入产品。

## 九 交付验收与发布运营

### 现有能力与新增工作的界线

| 能力 | 可复用内容 | 需要补齐的产品工作 |
| --- | --- | --- |
| 原生宿主 | 三个Swift库产品、虚拟屏、预览、窗口与输入 | 产品主窗口/身份、明确角色、路由、全局仲裁和接管修复 |
| 运行和待办视图 | agents/inbox/grants/usage返回结构化数据 | 统一task查询与能力、过期/离线状态、可信操作与审批历史 |
| 外部任务控制 | process托管、底层停止、共享worker与持久记录 | 按taskId控制通道；暂停检查点；恢复核对；不直接套旧TaskControl |
| 模型 | provider调用和用量汇总 | 每任务设置接入、调用前限额与持久累计、凭据引导 |
| 结果 | 已有文件校验、hash和崩溃reconcile机制 | 通用产物契约与外部Host接线；业务验收分层 |
| 并发 | 现有租约和进程身份机制 | 跨Agent的一条桌面队列；两客户端控制优先级 |
| 包管理 | manifest/profile/入口校验 | 可信包导入、固定版本、来源、更新回退与Runtime分发 |

现有status/outcome可以兼容读取两类任务，但pause/resume/cancel/artifacts仍直接转旧TaskControl。UI应读取结构化字段，不能解析供人阅读的lines，也不能仅在本地把任务改成已暂停。外部Agent当前按Agent各自串行，尚不是全局单个桌面任务；每任务预算也仍需从默认值改为真实配置。[S55][S61]

### 最小验收集

| 编号 | 验收场景 | 通过依据 |
| --- | --- | --- |
| T01 | 干净Mac只安装Desktop | 不用开发工具、不用BOSS账号，按向导完成真实通用任务 |
| T02 | App与CLI路由 | 新App与开发宿主同时存在时识别响应者；错误endpoint不误判成功；包内路径含空格也可运行 |
| T03 | 暂停取消与接管 | 排队、输入、审批等待时可停止，确认后无新动作并释放窗口；从支持检查点继续须复核应用/账号/页面，不重做已完成的有副作用步骤；失效时拒绝继续并说明 |
| T04 | 审批替换与重放 | 换动作、目标、任务、过期、撤销及重复消费均拒绝；确认链范围有界 |
| T05 | 模型预算 | 调用前限制；零次预算无新增模型调用；确定性任务仍可执行；未知用量独立显示 |
| T06 | 产物与成功 | 缺文件、越界、hash/格式失败不计有效交付；重复采纳幂等；历史结果可打开 |
| T07 | 崩溃和效果不明 | 持久记录操作意图；跨新任务与worker重启不盲目重发；可人工核对后继续 |
| T08 | 两个Agent与两个界面 | 只有一个活动桌面执行者；取消优先；同一目标进程不会获得两个控制者 |
| T09 | 独立App与插件 | 同一中性包，两种入口；无Desktop主应用也可启动/审批/接管；任务与授权作用域受控 |
| T10 | 安装升级与卸载 | 最终签名身份下授权、公证、空闲更新和恢复通过；卸载一个不删除他者使用的服务 |
| T11 | 环境变化 | 权限撤销、睡眠唤醒、显示器变化、模型断连和子进程卡住时可理解地等待或停止 |
| T12 | 可信包与外部入口 | 导入、兼容拒绝、禁用、回退和一个受管CLI/MCP客户端版本端到端通过 |

T01至T08、T11、T12使用实际Agent Desktop发布候选包验收。T09/T10使用该发布候选包与一个独立中性测试App，验证无Desktop安装、两者共存、升级、退出与卸载。阶段1可先用两个测试壳完成原型验证，不能代替首发实包验收。真实业务与更广版本矩阵后续分别验收。原生真实交互需目标Mac执行；macOS CI构建通过不等于授权、显示、输入和安装体验全部通过。

### 发布材料和观察指标

公开测试提供完整安装包、明确支持矩阵、入门任务、版本说明、已知限制、帮助、脱敏诊断和反馈入口。网站分发按Developer ID和公证路径准备，签名试包提前进行。数据设置说明截图与模型传输、结果位置、记录保留和删除；默认不要求组织账号或管理员权限。[S48][S49]

首轮建议5至10名目标用户，再扩大到20至30台受支持Mac；这些是计划样本。观察首次有效任务时间、任务完整交付比例、接管耗时、可恢复失败比例和重复使用。SDK单独观察接入耗时、双形态复用和升级成功；BOSS等业务另计自己的有效结果。

建议发布门槛为预定义支持任务集至少90%完整交付，同时列出失败、等待与未知用量。已知未授权、错对象、取消后仍执行、unknown自动重发等回归必须全部通过。比例只针对列明任务和环境，不能代替这些关键控制门槛。

## 十 六项迁移决定与实施约束

| 事项 | 建议决定 | 执行时必须满足 |
| --- | --- | --- |
| 1 App身份 | 采用Agent Desktop.app；com.agentdesktop.app作为产品ID；CLI签名ID可加.cli | 早期固定签名身份；命令名可继续2ndscreen；独立主窗口和Dock入口在产品内测完成 |
| 2 Socket与编号 | 阶段0使用明确的独立测试endpoint；主路径只作为有原子互斥的兼容方案；正式使用共享协调者 | 验证owner与版本；CLI/MCP/worker路由贯通；分别配置主屏serialNumber与Agent serialBase |
| 3 AppController | 先复制裁剪必要UI装配并记录来源，随后按真实重复下沉 | 不复制原生引擎、任务状态机或预算；菜单栏宿主过渡到任务工作台 |
| 4 Android | 首发不带，开发宿主保留，后续可选适配 | 裁掉启动ADB、重连、菜单/fallback、下载与资源；产品工具清单对未支持能力明确返回 |
| 5 Skills与BOSS | 上游提供通用资源选择；真正无BOSS构建单独验收 | 缺目录与空目录有兼容定义；不能只测help；构建依赖图无BOSS生产实现才算解耦 |
| 6 版本依赖 | exact加Package.resolved；核心和产品独立版本；本地覆盖仅开发 | 脚本/API改动发新tag再消费；发布拒绝editable源码，不重打旧tag |

共享一个socket路径不会自动得到单实例仲裁。旧入口先检查监听者再退出，ControlServer在启动和停止时无条件unlink；需要原子获取所有权、验证旧实例已退出、仅清理自己的endpoint。独立路径也不代表桌面隔离，阶段0测试副本限制在专用测试应用；跨产品图形执行仍须统一按进程租约仲裁。[S50][S57][S58]

侧实例仍然启动自己的控制socket；CLI与MCP必须携带同一路由。当前task-runtime默认使用boss.sock，全局CLI兜底查找又限定旧bundle ID。因此应优先执行包内CLI，并显式贯穿App、socket、Runtime、CLI和任务目录配置。仅修改App名称或CLI签名标识不能修复发现链。[S57][S60][S62]

SECONDSCREEN_SOCKET非空还会让旧宿主进入侧实例模式，隐藏菜单栏、跳过主屏和热键，并启用空闲退出。测试可见产品宿主时，用AgentRuntime.start(socketPath:)明确指定endpoint，并调整复制入口的primarySocket预检查与产品角色判断；不能只给UI主进程设置环境变量。主屏serialNumber与Agent屏serialBase也须分别设置。[S57][S58][S59][S63]

不带skills首先是资源裁剪。现有build.mjs仍将BOSS代码编进main/worker；loadSkills对不存在目录会报错。过渡安装选项至少保留空目录或改变loader，并检查真实host启动；最终通用发行物去掉BOSS静态依赖与默认构造，既验证构建内容，也验证中性任务运行。[S42][S46][S56]

私有产品仓保存产品UI、品牌和路线文档；公开引擎仓只接受通用接口、实现及中性测试，不反向依赖私有产品工作区。2ndscreen.app可作为开发和测试宿主保留，Agent Desktop作为用户产品单独发布。两者优先兼容既有协议，必要的能力和控制扩展须带版本说明。

## 附录一 已有能力与历史验收

| 层次 | 现有能力 | 成熟度与下一步 |
| --- | --- | --- |
| macOS 原生引擎 | 虚拟屏、窗口管理、后台输入、AX、截图、OCR、显示休眠与几何保护、可嵌入库。 | 已有真实实现与历史验证；保留架构，补同应用多窗口与焦点失败回归。 |
| Swift 视觉执行 | UI-TARS 解析、模型桥接、元素与坐标操作、流程学习、Android 与 iPhone 适配。 | 可作为探索与调试能力；任务预算、授权与执行记录统一交给 runtime。 |
| TypeScript 任务运行时 | SQLite、任务状态、租约、执行者核验、产物校验、单元回放、局部恢复、预算契约。 | 主要技术资产；先补各执行入口的一致性。 |
| Agent Hub 初版 | process task/resident agent、JSONL 协议、宿主、收件箱、grant、usage、action/audit 记录。 | 已超出文档草图，仍有执行保障与安装管理缺口。 |
| BOSS 内置只读任务 | 已有会话中的在线简历采集、身份核对、完整性检查与归档。 | 作为独立业务Agent迁移资产；平台首发使用中性参考任务。 |
| Windows 底座 | 虚拟显示驱动接入、托盘、UIA/消息输入、CLI/MCP、旧版 Tars 与回放。 | 当前 SHA 有 58 单测和 50 E2E 通过；task/Hub 全功能尚未齐平。 |
| 普通用户产品面 | 菜单栏屏幕控制、部分预览、手机连接与窗口管理。 | Hub 主要靠 CLI 与配置文件；需要统一任务、审批、接管与结果界面。 |

README 开头仍把项目介绍成 software second screen，而 RFC 0001 已把它定义为 Agent Desktop 的引擎，v0.2.0 release 又称其为第一个可用 Agent Desktop 版本。这三个描述对应不同成熟阶段。Agent Desktop与各独立业务应用分别维护产品说明、下载入口和支持矩阵；2ndscreen维护通用引擎与Runtime的开发文档。历史方案保留版本与适用范围。[S01][S02][S07]

### 真实成果应当如何解读

BOSS 的历史协调验收记录包含一次从空屏幕列表开始、自动建屏并完成归档的单份任务，耗时 62.247 秒、模型调用为 0。后续小批量任务浏览 6 位，完整归档 5 位，失败 1 位，耗时 406.258 秒；有 6 次修复模型调用，token 用量未知，且与上一任务重合 1 位。它证明了小批量交付和失败后继续处理，也明确说明了跨任务去重与成本计量仍有边界。这些是历史真机记录，不是本次重新操作用户 BOSS 得到的结果。[S08]

Windows 在审阅 SHA 的 GitHub Actions 记录中，58 项单元测试与 50 项端到端检查全部通过，0 失败、0 跳过；实际覆盖虚拟显示、WinForms、WPF、Edge、真实模型输入点击与发送前拦截。本次读取了日志，未在本地 Linux 环境运行 Windows 桌面。这一结果应保留为已有底座的正面证据，同时补充失败分支与长时间使用测试。[S09]

## 附录二 代码问题与修复依据

以下 R1 至 R6 均已在当前代码上用真实 Host 或 Runner、JSONL 子进程以及模拟 Session/provider 安全复现，没有操作真实业务应用、真实候选人或调用外部付费模型。R1 至 R5 属于扩大试用前的优先项；R6 影响零模型回放的产品承诺。

| 编号 | 观察到的行为 | 直接影响 |
| --- | --- | --- |
| R1 审批绑定 | 批准 Ask resume 后，同 approvalId 可以执行 Delete candidate。 | 批准内容与实际动作脱节。 |
| R2 确认链 | 四个连续 external-submit 可用 confirms 串联，实际执行 4 次，仅记 1 次额度。 | 确认豁免可以递归扩展，绕过间隔与计数。 |
| R3 结果不明 | 第一任务同目标外发返回 unknown；60 秒后新任务仍得到 ok。 | 不确定结果可能被重复外发。 |
| R4 模型预算 | taskModelCalls 与 taskTokens 都设为 0，provider 仍被调用两次。 | 统计已存在，但调用前预算限制不完整。 |
| R5 单元回放 | 合法 navigation 每日额度1已用完，直接 act 被拒；run_unit 仍执行，账本无新增记录。 | 回放与普通动作没有经过同一检查和记录入口。 |
| R6 零模型执行 | 内置任务模型预算为 0 时，在 select_source 后以 budget_exhausted 提前结束。 | 禁止新增模型调用被当成终止整个确定性任务。 |

### R1 把批准绑定到具体动作

checkAction 校验 approval 的 granted、used、effect、app 与 target，但没有校验被批准的 Action 内容；askApproval 保存的记录也未保留动作摘要的不可变指纹。模拟审批中的按钮标签为 Ask resume，执行标签换成 Delete candidate 后仍通过。修复应绑定 agent、任务、账号、应用、稳定目标、动作内容和有效期，并一次性消费；内容或目标变化必须重新请求。验收应包含换动作、换任务、换目标、过期、重放及重启后的处理。[S10]

### R2 限定确认点击的豁免范围

act.confirms 找到上一个同应用、同目标、结果 ok、未被确认且在 60 秒内的外发，就免除新一次计数与审批；但没有排除“上一个动作本身也是确认”。因此 c1、c2、c3、c4 可以串成四步，只记录首步。修复应把一次业务操作定义为有界事务，确认只能引用根操作、消费一次，并校验真实确认界面和语义。不能只凭 agent 声称“这是确认”放行。[S11]

### R3 将结果不明状态持久化

runAgentTask 为每次运行创建新的 unknownTargets Set。尽管 effect ledger 已落盘记录 unknown，新任务的检查未从持久记录恢复该阻断。本次复现直接证明的是跨新任务重复；常驻宿主内部自动重启会共享 Set，而整个宿主或 worker 重启仍需单独验收。修复应把发送前意图、发送中、成功、失败、结果不明及人工核对写进持久账本，恢复时先对账，再决定是否可重试。对外界 GUI 操作不能仅凭数据库事务承诺绝对 exactly once。[S12][S13]

### R4 让预算在调用前生效

Host 的 provider 路径检查 provider 声明与用途，随后直接 call，并在完成后记 usage；未将该调用扣入任务预算。建议统一 provider 与 exploration 的预算预留、调用次数上限、输出 token 上限与回收逻辑。token 未知时保留 unknown 并采取保守预算政策；已知调用次数仍应严格限额。验收须覆盖零预算拒绝、并发调用、错误响应、未知 token、取消与重启累计。[S14]

### R5 让回放与普通动作共用检查入口

runUnit 把原始 session 交给单元服务。它会拒绝声明 external-submit 的单元，却没有逐动作复用 HostRun.act 的时段、额度和日志路径。复现使用通过 manifest 校验的每日额度1，并在真实账本预先记录已用1次；普通 act 被额度拒绝，非工作时段的同一会话回放仍成功执行1次，账本仍为原来的1条。应向单元服务、回放器和探索器提供受管 session，所有动作执行前调用同一套检查；内部调用也携带任务与操作标识。修复后普通 act、run_unit、内置任务和桥接探索应共享同一组负向契约测试。[S15]

### R6 分开模型预算与任务停止条件

skills/boss-resumes 的说明把 taskModelCalls=0 定义为只用已学流程，runner.checkLimits 却在模型预算耗尽时终止整个任务。应把“还可否调用模型”与“还可否进行确定性导航、回放、归档”分成独立判断：零模型模式继续本地流程，遇到必须探索的步骤时给出清晰的停止原因。验收应能在已学流程上完成任务，并且模型调用严格为 0。[S16]

### 原生与平台侧还要补充的验证

- 受管与底层入口的差异：原子 MCP click/type/key 直接转 CLI；它们有引擎级窗口与输入保护，却没有统一 task 审批。RFC 0002 自己也指出此现状。产品默认入口应走受管任务，底层开发接口需有清晰信任边界。[S06][S17]
- Mac 人工接管：菜单的 Bring Back 只移动窗口，没有解除 agent screen binding；followWindows 会再次把绑定窗口移回。CLI window release 已有正确释放路径，UI 应复用并先暂停执行。这是源码路径确认，尚未在本次真机复现。[S18]
- Mac 同应用多窗口：部分键盘输入按 PID 投递，窗口几何检查不等同于键盘目标被隔离。首版宜按应用会话独占，并对用户与 agent 同时使用同一应用的场景做回归；能力无法确认时等待或要求交接。[S19]
- 人物与账号不能沿用一般按钮的模糊定位：旧 Swift 学习器按标签前缀和最近位置选目标，测试会把“李四”匹配到“李四光”。业务对象应通过稳定ID或多个字段唯一确认，歧义时停下。此发现仅针对原生旧学习层，不据此认定 TS 实体定位存在相同问题。[S37]
- Windows 前台失败：ForegroundKey 忽略 TakeForeground 返回的 false，随后执行 SendInput。目标不能前置或前台被抢走时可能影响当前用户窗口。应验证目标前台所有权并在失败时拒绝。[S20]
- Windows 旧视觉 agent 的换行：Planner 只拦末尾换行，Input.Type 却将任意中间 CR/LF 转成 Enter。默认禁止提交时也可能通过多行文本触发聊天发送；这是裸 Tars 路径，不能泛化为 TS runtime 同样存在。补内部换行与不同输入路由的负向测试。[S21]
虚拟显示器与宿主仍共享用户会话；普通子进程也不是操作系统沙箱。首轮产品应限定可信 agent 与明确支持的应用版本。签名、检查链、工具白名单和操作系统隔离分别解决不同问题，发布承诺需要与实际提供的控制一致。[S01][S02]

## 附录三 全分支审阅与资产归属

已获取完整 Git 历史与全部 17 个可见远程分支。默认分支为 vdisplay-prototype，审阅基线也是 v0.2.0 对应的提交。主线有 230 个受版本管理文件、67,144 行文本，计入源码、测试、文档与构建配置；其中 macOS Sources 13,930 行，TypeScript runtime/src 19,399 行，Windows src 6,534 行。行数用于说明范围，不能用于证明质量。

所有分支头快照去重后共有 700 个路径、827 个不同文件内容对象；历史共 525 个可达提交，主线可达 353 个。所有分支的文件树、合并基点和差异均已盘点；主线 macOS、Windows、TypeScript 生产代码及历史独有执行链均纳入阅读。monitor 归档的客户端、服务端、协议、邮件与部署脚本共110个文件、25,018行已完成全文阅读，其全部180个Python文件还做了AST扫描。测试、夹具与历史交接文档采用执行、扫描和重点阅读相结合的方式，不声称每个测试体和每个历史提交均逐行审计，也不等同于全部平台真机重新验收。

60 个 PR 的状态为 56 个已合并、3 个关闭但未合并、1 个开放。三个关闭项是 #27、#30、#40；开放项 #56 是 ACP 文档草案。祖先关系意味着提交已进入主线历史，但旧分支仍可能保留主线已删除或迁移的路径，因此归档判断还结合了文件迁移记录。 新路线下，各独立产品分别维护发布主线，通过版本化依赖使用通用能力。

| 分支 | 提交 | 领先 落后 | 处理建议 |
| --- | --- | --- | --- |
| act-confirms | db86dbf | 0 / 5 | 已进入主线历史，合并分支可按流程清理 |
| action-log | ee68ae2 | 0 / 7 | 已进入主线历史，合并分支可按流程清理 |
| agent-run-unit | 97f39f2 | 0 / 15 | 已进入主线历史，合并分支可按流程清理 |
| agent-stderr-log | adfc93e | 0 / 3 | 已进入主线历史，合并分支可按流程清理 |
| agent-worker-merge | c9f13c6 | 0 / 19 | 已进入主线历史，合并分支可按流程清理 |
| archive/llm-worker | 150258f | 1 / 214 | 保留模型网关参考，后续按需迁移 |
| archive/monitor-v1 | 6701762 | 170 / 63 | 保留归档；业务客户端与服务端按已定方案拆仓 |
| archive/ss-runtime-integration | 13792da | 0 / 63 | 已吸收的集成历史，保留追溯 |
| builtin-agents | 7251197 | 0 / 14 | 已进入主线历史，合并分支可按流程清理 |
| heartbeat-while-answering | 7fe176e | 0 / 17 | 已进入主线历史，合并分支可按流程清理 |
| release-0.2.0 | 6f5a5ab | 0 / 1 | 已进入主线历史，合并分支可按流程清理 |
| resident-wait-handover | 8655156 | 0 / 11 | 已进入主线历史，合并分支可按流程清理 |
| runtime-library | d8b6b14 | 0 / 48 | 已进入主线历史，合并分支可按流程清理 |
| szrunworld/rfc-0002-acp | dcccbf3 | 1 / 8 | 仅 RFC 草案，排入后续协议里程碑 |
| vdisplay-prototype | 7a96154 | 0 / 0 | 本次2ndscreen审阅基线；后续作为通用能力主线 |
| wait-for-login | b0aee84 | 0 / 9 | 已进入主线历史，合并分支可按流程清理 |
| windows | a52642b | 0 / 220 | 历史祖先；维护主线 windows 目录 |

领先与落后均相对审阅基线的 Git 提交可达性计算，不代表工作量或功能完成度。清理分支前应固定归档标签、保留关联 PR，并核对发布引用；本次审阅没有执行远程分支删除、合并或仓库改名。

### 三个差异分支的具体处理

archive/monitor-v1 有 170 个独有提交，相对共同祖先增加 422 个文件。它包括 Python 客户端、业务服务端、邮件接入、协议、集成测试与大量交接文档。归档状态明确记录了 10月5日的拆分决定：客户端转向 remotedesk-boss-agent，服务端、邮件和执行器协议交给 recruiting。应按迁移资产核对，整体合回引擎会重新混入已经移出的业务边界。归档中的 1774 测试记录也不能证明未完成的真实写操作与登录接力已经交付。[S03]

归档中可直接用于指导新主线的资产包括：先关闭操作闸门、等待当前动作结束、再释放窗口的接管语义；稳定业务标识、发送前冻结请求体的 outbox；区分结果不明、检查未运行与确认空结果的协议；产物来源、hash 与人工核对流程。应把这些约束变成当前 Runtime 的实现与验收要求，业务邮箱和招聘状态继续留在业务系统。直接复制旧代码仍需检查：邮件副本重取后 hash 改变只记警告，以及永久拒绝被缓存为 sent 后重试误读成功结果等静态缺口。旧 remote 模式要求的无人值守 Mac 设置也不应成为普通用户安装条件。[S34][S35][S36]

archive/llm-worker 的独有提交包含 Cloudflare 模型网关、用户 token、限流、总开关和脱敏日志等实现。它可为未来 RemoteDesk 组织 provider 提供参考。应先确定组织身份和调用预算契约，再按模块接入；不需要用恢复整条老分支的方式获得这些能力。[S05]

szrunworld/rfc-0002-acp 的唯一差异是 235 行 RFC 文档，尚未增加 ACP 执行代码。建议先完成受管任务入口与本地 UI，之后在真实开发者需求明确时先做入站，再评估出站执行体。协议中关闭文件系统或终端能力，不能作为操作系统隔离已经成立的证据。[S06]

## 附录四 验证记录

验证基线为主线 7a96154。审阅覆盖分支关系、源码、测试、PR、发布与 CI；当前验证结果写在下表，避免把历史平台报告与本次执行混为一谈。

| 验证 | 结果 | 解释 |
| --- | --- | --- |
| 本次 TypeScript 类型检查 | 通过 | 使用锁文件安装的 TypeScript 依赖，执行 npm run typecheck。 |
| 本次 Runtime 套件 | 489项：458通过，18受环境限制失败，13跳过 | Linux 不能代替 macOS 的原生助手、权限、进程查询和真实应用验证。 |
| 本次安全复现 | R1至R6均复现 | 真实 Host/Runner 与模拟应用/provider；未调用真实付费模型或业务外发。 |
| 当前 SHA Windows CI | 58单测与50 E2E通过 | 读取 GitHub Actions 日志；真实虚拟屏与测试应用路径。 |
| 历史 Mac BOSS 小批量 | 浏览6位 成功5位 失败1位 | 2026年10月4日历史记录；6次修复调用，token未知；非本次重跑。 |
| Mac 原生异常和焦点 | 源码路径确认 | Bring Back、PID键盘目标与Windows失败前台等风险需要目标机器负向回归。 |

npm test 的 tsx CLI 在本环境创建 Unix socket 时被 EPERM 拒绝，套件未能按原命令启动。随后以 node --import tsx --test tests/*.test.ts 执行：489项中458通过、18受环境相关限制失败、13跳过；其中6项涉及进程身份查询，另外12项涉及子进程 tsx/worker/crash fixture 的 IPC 限制及连带失败。这里的18项不作为18个业务缺陷，也不能将整套测试标成通过。本环境 Node 为24.19，发布包目标为22.23.2；发布前应在目标运行时与平台重新通过所需门槛。

已获取所有分支，不代表已验证所有历史版本。归档生产模块补充完成全文阅读，历史测试/夹具仍以盘点、扫描和重点阅读为主；正在交付的主线优先验证会改变产品可靠性的路径。没有读取两个外部业务仓库来判断其最新完成度，也没有运行真实的 Mac/Windows 交互来替代设备持有者的验收。

## 附录五 代码与决策来源

代码链接固定到审阅提交。既有审阅记录继续适用；本版新增功能、阶段与工作项均为产品实施目标。历史BOSS内置例外已被独立业务应用方向替代。

[S01] 主线 README 与引擎边界  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/README.md)

[S02] RFC 0001 产品定位与运行时方案  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/docs/rfc/0001-agent-hub/README.md)

[S03] monitor 归档状态与拆仓决定  [查看来源](https://github.com/szrunworld/2ndscreen/blob/67017628b0dd4be8e0bac6ff59fd590ecbe8f112/docs/monitor/status.md#L93-L111)

[S04] 历史PR40：子进程方案与当时的BOSS内置例外  [查看来源](https://github.com/szrunworld/2ndscreen/pull/40#issuecomment-6030099128)

[S05] 归档模型网关  [查看来源](https://github.com/szrunworld/2ndscreen/blob/150258f097fea393f6340ed4bc3e88a130c57d08/workers/llm/README.md)

[S06] RFC 0002 ACP 草案  [查看来源](https://github.com/szrunworld/2ndscreen/blob/dcccbf3cc176d0b9bb3ba32b279249099bee83ca/docs/rfc/0002-acp/README.md)

[S07] v0.2.0 发布与限制  [查看来源](https://github.com/szrunworld/2ndscreen/releases/tag/v0.2.0)

[S08] BOSS 单份与小批量历史验收  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/docs/agent-reports/Coordinator-review.md#L89-L103)

[S09] 当前 SHA 的 Windows CI  [查看来源](https://github.com/szrunworld/2ndscreen/actions/runs/37596806471)

[S10] checkAction 审批匹配  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/packages/task-runtime/src/agent-host.ts#L390-L405)

[S11] 确认关联与额度计数  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/packages/task-runtime/src/agent-host.ts#L896-L1029)

[S12] 新任务 unknownTargets 初始化  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/packages/task-runtime/src/agent-host.ts#L463-L474)

[S13] 常驻宿主 unknownTargets 生命周期  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/packages/task-runtime/src/agent-host.ts#L1375-L1398)

[S14] provider 调用与 usage 记录  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/packages/task-runtime/src/agent-host.ts#L1034-L1070)

[S15] run_unit 传入原始 Session  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/packages/task-runtime/src/agent-host.ts#L1073-L1101)

[S16] Runner 任务停止与预算  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/packages/task-runtime/src/runner.ts#L712-L722)

[S17] 原子 MCP 到 CLI 的映射  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/Sources/ScreenCLI/MCPServer.swift#L243-L283)

[S18] Mac Bring Back 菜单动作  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/Sources/SecondScreen/AppController.swift#L1056-L1060)

[S19] Mac 原生后台输入  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/Sources/SecondScreenCore/BackgroundInput.swift)

[S20] Windows 前台键盘输入  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/windows/src/SecondScreen.Cli/Input.cs#L229-L255)

[S21] Windows Tars 文本与换行  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/windows/src/SecondScreen.Core/Tars/Planner.cs#L122-L156)

[S22] Apple App Review Guidelines 2.5.1  [查看来源](https://developer.apple.com/app-store/review/guidelines/#software-requirements)

[S23] 仓库 Windows workflow  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/.github/workflows/windows.yml)

[S24] Swift 嵌入库和目标结构  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/Package.swift)

[S25] 零模型参数的现有说明  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/skills/boss-resumes/SKILL.md#L47-L59)

[S26] 窗口跟随与释放行为  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/Sources/SecondScreenRuntime/AgentScreens.swift#L735-L751)

[S27] 微信 agent 独立成仓决定  [查看来源](https://github.com/szrunworld/2ndscreen/pull/30#issuecomment-6016934938)

[S28] 统一 status 与各控制命令当前路由  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/packages/task-runtime/src/main.ts#L58-L76)

[S29] 外部 agent 的 item 与 artifact 收集  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/packages/task-runtime/src/agent-host.ts#L824-L835)

[S30] 外部 agent 完成状态的采用方式  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/packages/task-runtime/src/agent-host.ts#L1239-L1257)

[S31] Android 控制写入与参数处理  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/Sources/SecondScreen/AndroidMirror.swift#L355-L475)

[S32] iPhone 粘贴与剪贴板恢复  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/Sources/TarsAgent/IPhoneScreen.swift#L142-L155)

[S33] 用户要求移除手机 UI-TARS 侧栏  [查看来源](https://github.com/szrunworld/2ndscreen/commit/976ee1b07c25f8170009b5286897eef3ddfe10eb)

[S34] 归档 LocalSession 接管与交还  [查看来源](https://github.com/szrunworld/2ndscreen/blob/67017628b0dd4be8e0bac6ff59fd590ecbe8f112/monitor/client/monitor/bootstrap/session.py#L241-L360)

[S35] 归档邮件副本重取与 hash  [查看来源](https://github.com/szrunworld/2ndscreen/blob/67017628b0dd4be8e0bac6ff59fd590ecbe8f112/monitor/mail/monitor_mail/consumer.py#L202-L228)

[S36] 归档 outbox 的响应缓存与拒绝  [查看来源](https://github.com/szrunworld/2ndscreen/blob/67017628b0dd4be8e0bac6ff59fd590ecbe8f112/monitor/mail/monitor_mail/writer.py#L59-L110)

[S37] 旧学习器人物前缀匹配测试  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/Tests/TarsAgentTests/TarsAgentTests.swift#L533-L539)

[S38] Android 配对的取消与异步回调  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/Sources/SecondScreen/AndroidPairing.swift#L187-L207)

[S39] Android 音视频偏差记录  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/Sources/SecondScreen/AndroidMirror.swift#L668-L679)

[S40] 内置与进程执行体定义  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/packages/task-runtime/src/agent-contracts.ts#L85-L94)

[S41] 内置工作流与外部Agent启动分流  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/packages/task-runtime/src/agent-daemon.ts#L333-L338)

[S42] BOSS工作流在worker内构造  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/packages/task-runtime/src/bootstrap.ts#L397-L411)

[S43] actor身份与生命周期  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/packages/task-runtime/src/actors.ts)

[S44] 任务runner中的BOSS依赖  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/packages/task-runtime/src/runner.ts#L67-L95)

[S45] 招聘领域产物格式  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/packages/task-runtime/src/artifacts.ts#L994-L1023)

[S46] BOSS与skills随Runtime打包  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/packages/task-runtime/scripts/build.mjs#L28-L47)

[S47] Apple后台服务与登录项管理  [查看来源](https://support.apple.com/en-in/guide/deployment/depdca572563/web)

[S48] Apple Developer ID与公证分发  [查看来源](https://developer.apple.com/developer-id/)

[S49] Apple DTS：权限归因与稳定签名  [查看来源](https://developer.apple.com/forums/thread/678819)

[S50] 原生ControlServer实例与socket生命周期  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/Sources/SecondScreenRuntime/ControlServer.swift#L23-L58)

[S51] Android默认打包依赖  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/scripts/bundle-app.sh#L28-L41)

[S52] App启动时ADB重启与重连  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/Sources/SecondScreen/AppController.swift#L120-L124)

[S53] SwiftPM依赖范围与解析锁定  [查看来源](https://docs.swift.org/package-manager/PackageDescription/PackageDescription.html)

[S54] SwiftPM精确版本API  [查看来源](https://developer.apple.com/documentation/packagedescription/package/dependency/package(url:exact:))

[S55] 任务控制分流与结构化界面数据  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/packages/task-runtime/src/main.ts#L59-L110)

[S56] Skills目录加载与缺目录行为  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/packages/task-runtime/src/bootstrap.ts#L157-L179)

[S57] 主socket与侧实例环境路由  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/Sources/SecondScreenCore/ControlProtocol.swift#L8-L31)

[S58] 旧宿主单实例检查与菜单栏入口  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/Sources/SecondScreen/main.swift#L4-L19)

[S59] Agent屏编号与控制接口参数  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/Sources/SecondScreenRuntime/AgentRuntime.swift#L38-L50)

[S60] CLI的Runtime发现与旧App身份兜底  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/Sources/ScreenCLI/TaskCommand.swift#L111-L176)

[S61] 外部Agent按包调度与默认预算  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/packages/task-runtime/src/agent-daemon.ts#L213-L249)

[S62] Runtime配置与默认BOSS侧socket  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/packages/task-runtime/src/bootstrap.ts#L104-L125)

[S63] 主屏序列号参数  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/Sources/SecondScreenCore/VirtualDisplay.swift#L58-L83)

[S64] 外部Agent产物与完成事件  [查看来源](https://github.com/szrunworld/2ndscreen/blob/7a9615406b4bbc2fcf09224a30667404b4765ecb/packages/task-runtime/src/agent-host.ts#L824-L852)

