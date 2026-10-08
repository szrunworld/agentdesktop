# ai-gui-foundation 最终验收记录（合 main 前，2026-10-08）

基线：**`f0f382728fae1a06708785d4d1a43662b76861ea`**（Merge PR #94），即 #94 合入后的 foundation HEAD。

结论：本地门槛全部通过。**仍有两项未满足**：
- GitHub CI：额度用完，foundation 的 push 和 PR #2 的 checks 都是 startup_failure；
- 主窗口 Settings 的人工操作。

按 Kevin 的裁决，PR #2 保持 HOLD，不合入 main，也不绕过 required checks。

## 环境

| 项 | 值 |
| --- | --- |
| 机器 | Apple M4，arm64 |
| 系统 | macOS 15.1（24B2083） |
| 工具链 | Apple Swift 6.0.3（swiftlang-6.0.3.1.10）。CI 用的是 6.1.2，本地无法覆盖 |
| 检出方式 | 新建 worktree，干净检出 f0f3827，没有任何构建缓存 |
| 执行时间 | 2026-10-08 17:3x（北京时间） |

## Kevin 列出的门槛

| 验收项目 | 要求 | 结果 |
| --- | --- | --- |
| PR #94 | 已合入 foundation | ✅ f0f3827 |
| macOS 产品测试 | 全部通过 | ✅ `swift test` 退出码 0，**470 项通过**（2 项是需要真实模型密钥的 Live model 用例，按设计跳过） |
| Swift Engine 测试 | 全部通过 | ✅ `swift test --package-path engine` 退出码 0，**217 项通过** |
| CLI 真机冒烟 | 通过 | ✅ 见下文 |
| 主窗口 Settings | 人工操作一次，确认 AI 服务正常 | ⏳ **未做**：需要 Kevin 本人操作，见文末步骤 |
| 打包完整性 | 不依赖旧 Contracts 资源包 | ✅ 包里没有任何 `.bundle`；宿主二进制中 `.bundle` / `AgentDesktopContracts` 的引用为 0 |
| GitHub CI | foundation push 和 PR #2 checks 全绿 | ❌ **未满足**：f0f3827 的 macOS 和 windows 工作流都是 `startup_failure`（Actions 额度） |
| Runtime 契约 | macOS 只保留统一的 runtime/1 实现 | ✅ 宿主和 CLI 二进制中 `agentdesktop.ai/1` 均为 0 处；Sources 里没有任何 ai/1 或 `ai-gui/v1` 引用；没有 `AgentDesktopContracts` 模块；只监听一个 socket |

## 本地 CI（按 `.github/workflows/macos.yml` 逐步执行，退出码直接取，没有经过管道）

| 步骤 | 退出码 | 耗时 |
| --- | --- | --- |
| `swift package resolve`（之后 `.build/checkouts` 为空，没有 Package.resolved，没有网络下载） | 0 | 2 s |
| `swift build -c release`（从零构建） | 0 | 84 s |
| `swift test` | 0 | 215 s |
| `swift test --package-path engine` | 0 | 66 s |
| `scripts/bundle-app.sh`（build.json 中 source = f0f3827…） | 0 | 5 s |
| `scripts/verify-archive.sh` | 0 | 1 s |
| `scripts/verify-command-surface.py` | 0 | <1 s |
| Core is local / codesign（App 与 CLI）/ help / version / `runtime_offline` 退出码 3 | 0 | 2 s |

同一提交在开发 worktree（有缓存）上也跑过一遍，结果相同。

## CLI 真机冒烟（上面干净构建的 App，测试副本 /tmp/adt-final）

| 检查 | 结果 |
| --- | --- |
| `runtime capabilities` | 64 个方法，其中 ai.* 27 个；有 `gui` 字段 |
| 建 Desktop → 启动计算器 → 绑定 → 开会话 → `observe --image-output` | 图像 396×700，原点等于窗口位置（G0：只截绑定窗口）；coverage 中截图和 AX 都 complete；27 个元素 |
| `act click` 数字 7 | 已送达，`businessResult: not_evaluated` |
| `wait --element-present` | 满足 |
| `run list` | act 的 Run 状态为 ended / success |
| `ai capabilities` / `ai connections list` | 都成功，返回 runtime/1 应答 |
| `runtime stop-all` → act → `runtime enable-input` | admission 变为 stopped；act 被拒（input_disabled，notSent）；之后恢复 enabled |
| 副本目录 | 只有 `side.runtime.sock`；除我自己的日志和截图外，没有对组或其他用户开放的文件 |

清理：关闭会话，退出计算器，销毁 Desktop，停止副本，删除目录。

## 今天合入 foundation、与合 main 相关的变更（按顺序）

#47 A0（本地引擎，只留一个 Runtime 入口）· #51 G0（窗口一致性）· #60 AX 隔离 · #69 SEC-01 · #70 审计持久化 · #77（测试不碰用户屏幕）· #84 PR2b-1（单一端点）· #94 PR2b-2（删除 ai/1，Contracts 并入 Protocol，幂等语义修正）。各自的验收记录在 `docs/acceptance/`。

## 待 Kevin 完成：主窗口 Settings 人工检查

测试副本只在后台运行，没有主窗口；产品实例会读写你的真实配置和钥匙串。按约定我不碰产品实例，所以这一项需要你本人操作：

1. 用 f0f3827 的构建启动 Agent Desktop（`scripts/bundle-app.sh` 之后打开 `build/Agent Desktop.app`，或直接用归档包）。
2. 打开主窗口 → Settings → AI 相关页面。
3. 确认连接列表能正常加载（空列表也算）；新建一条测试连接，地址可以随便填，例如 `https://example.invalid/v1`，确认保存成功、列表里出现、没有显示密钥；然后删除它。
4. 打开 GUI 运行发起页，确认能显示支持的动作和验证谓词（这些来自 `runtime.capabilities` 的 `gui` 字段）。

## GitHub CI

额度恢复后，需要在最终 HEAD 上重新跑 foundation 的 push 和 PR #2 的 checks。如果额度问题持续，另行申请用本地验收替代，届时附上本记录的完整日志和 SHA 对应关系，由 Kevin 明确批准例外。
