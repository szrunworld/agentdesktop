# 本次迁入的验证记录

范围：AgentDesktop 原生核心的同仓来源保全、活动代码清理、构建和产品身份。源为 `da5677c2`，目标原基线为 `91cfd09`。

| 检查 | 结果 |
| --- | --- |
| 22 个原产品文件恢复 | Git blob、字节与模式逐项匹配目标基线；树为 `fc75fdb4102ddf09f39f41bbc671fcd6a89eebb8` |
| 233 个源文件完整导入 | 原字节和模式保留；远端导入树与本地树均为 `9615b6a03a0b463ae494d8439fb38c7ec849d143` |
| 七个源 PR | 固定 head、patch SHA-256 与可达性均记录，均未自动应用 |
| 本地 package / 当前入口守卫 | `scripts/check-local-engine.sh` 通过 |
| Shell 与 Python 静态检查 | 构建脚本 bash 语法、验证脚本 Python 编译及 `git diff --check` 通过 |
| macOS App、CLI、Swift 测试与归档 | 由本迁入 PR 的 macOS CI 验证；不借用原仓或 PR2 结果 |
| Windows 原生后端 | 由 Windows native backend CI 验证；模型密钥不可用时跳过项须单列 |
| CLI/MCP 表面 | CI 对真实打包 binary 运行 initialize、tools/list、帮助与旧入口拒绝检查；不投递桌面动作 |
| 真机执行 | 本次未重新运行。历史证据不扩大到新 Runtime；G0/T01、目标重验、并发、宿主并用与停止仍待对应验收 |

本地环境没有 Apple SDK 或 Windows，不能据静态检查宣称目标系统编译/真机通过。PR 的提交与实际检查记录是平台结果依据。

旧 TS 运行器及其专属 Bridge 不再编译或维护，历史测试只作为原生语义接管的依据。未把删除旧入口描述为原生控制权和停止语义已等价接管。
