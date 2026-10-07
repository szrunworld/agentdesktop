# 真实模型四层能力测试（2026-10-08）

| 项 | 值 |
| --- | --- |
| 执行 | `AGENTDESKTOP_LIVE_ARK=1 swift test --filter LiveModelTests`（本机 macOS 15，Swift 6.0.3） |
| 端点 | `https://ark.cn-beijing.volces.com/api/v3`，协议 openai_chat |
| 模型 | doubao-seed-2-1-lite-260915 |
| GUI 配置 | uitars_v1、normalized_1000、promptVersion uitars-prompt-1、parserVersion uitars-parser-1 |
| 素材 | synthetic_gui_v1（合成图，不截桌面） |
| 结果 | succeeded |
| 各层 | network passed（未带凭据探测得到 HTTP 401，证明可达）；auth_model passed；image_input passed；gui_contract passed（模型点击落在合成按钮内，经 codec 严格解析） |
| 模型调用 | 3 次，用量全部上报：输入 2792、输出 289、合计 3081 token，缺用量 0 |
| 桌面输入 | 0（performedDesktopInput=false） |
| 密钥 | 证据文件与输出中均不含 key（脚本断言） |

原始结果：[live-capability-ark-2026-10-08.json](live-capability-ark-2026-10-08.json)。

这证明 TRN-008 与 CFG-008 的四层测试在一个真实 UI-TARS 风格模型上可以通过，并且共享 AiService 的真实网络路径工作正常。它不证明真机 GUI 运行（MAC-001 需要原生执行后端，G0 未过），也不代表其他模型或端点兼容。
