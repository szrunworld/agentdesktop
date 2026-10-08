# Runtime 承接 GUI 端口 · 验收记录（2026-10-08）

范围：Runtime 实现 GUI 层的 `GuiSessionAuthority` / `GuiObservationPort` / `GuiExecutionPort`（DEV-SPEC D06：Runtime 是唯一真实输入路径），宿主组装 AI/GUI 服务（agentdesktop.ai/1，`ai.sock`），`agentdesktop ai|gui|rpc` 默认连接它。真实 GUI 输入默认关闭。

构建：`scripts/bundle-app.sh`（基座 ai-gui-foundation 218b71a 之上），测试副本 `/tmp/adt-acc/side.sock`，Runtime `/tmp/adt-acc/side.runtime.sock`，AI 服务 `/tmp/adt-acc/side.ai.sock`，记录目录 `/tmp/adt-acc/side.runtime/`（含 `ai.sqlite`）。

## 自动化测试

`swift test`：333 项全部通过，退出码 0。新增：
- 端口单测：authorize 检查 Desktop、绑定窗口、Session、可信 owner；observe 交给模型的是裁剪后的绑定窗口（像素裁剪框、模型输入尺寸、source→desktop 变换落点、PNG 尺寸与 sha256、产物落盘、元素角色映射）；execute 走 runtime/1 act（同 actionId 由账本重放、不重复点击；Meta+A → cmd-a）；投递后失败为 unknown 且带执行目标；窗口外坐标 `rejected/COORDINATE_OUT_OF_BOUNDS`；重新绑定后 `rejected/STALE_OBSERVATION`；他人 Session 的 stamp `rejected/FORBIDDEN`。
- 集成测试（新 target AgentDesktopIntegrationTests）：真实 AgentDesktopService + 脚本化方舟 → Explorer → Runtime 端口 → 平台；GUI 运行一次点击后 `succeeded`，校验 passed，点击坐标误差 < 0.5 点。

## 真机结果（真实方舟模型 doubao-seed-2-1-lite-260915）

| 步骤 | 结果 |
| --- | --- |
| 开启 GUI 执行的测试副本（`AGENTDESKTOP_GUI_EXECUTION=1`） | `side.ai.sock` 出现；`agentdesktop --json ai capabilities` 经 CLI 路由到 ai.sock 成功 |
| `ai connections create --credential-stdin` | 密钥只经 stdin；输出不含密钥 |
| `ai models refresh --wait` | succeeded，列出方舟模型 |
| 模型档案、GUI 档案、`ai tests start --wait` | 四级能力测试（network / auth_model / image_input / gui_contract）全部 passed |
| 虚拟桌面 + 计算器 + 绑定 + Session，`gui run --goal 计算 7+3 … --verification static_text = "‎10"` | **succeeded**；4 次点击（7、+、3、=）全部 `click confirmed`，每次都经 Runtime 的 act；目标校验 passed（verifier element-text-equals-v1，在新观察上）；随后读到显示 `7+3` / `10` |
| 同一 idempotency key 再 `gui run` | 返回同一个 runId（succeeded），不新建运行 |
| 不带开关重启测试副本，再 `gui run` | `CAPABILITY_MISMATCH`：真实 GUI 输入保持关闭 |
| 清理 | 销毁 Desktop（退出计算器）；删除 GUI 档案、模型档案、连接（API 密钥随之从钥匙串删除；剩下的 `idempotency-digest-key` 是服务自己的摘要密钥） |

## 已知限制 / 后续

- 产品默认不开启真实 GUI 输入；开启方式：`defaults write com.agentdesktop.app guiExecution -bool true`。是否默认开启需 Kevin 决定（DEV-SPEC 要求 G0 通过后才开放）。
- ai/1 与 runtime/1 目前是两个端点、两套退出码；CLI 方案 PR4 计划把 GUI 单元收进 runtime/1（`unit run`）。
- 元素校验文本包含 macOS 计算器的方向控制字符（U+200E），校验条件需原样匹配。
