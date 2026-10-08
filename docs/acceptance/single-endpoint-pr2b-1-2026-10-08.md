# 单一端点（A2 / PR2b-1）验收记录（2026-10-08）

## 内容

- 宿主不再启动 `ai.sock`。AI 服务的 27 个 `ai.*` 方法在 Runtime 端点上以 runtime/1 信封提供。
- 合同里这些方法标为 `servedBy: ai-service`；`gui.runs.*` 标为过渡保留，A6 时删除。
- 桥接（`AgentDesktopService/RuntimeBridge`）：
  - 把 runtime/1 调用转成 ai/1 请求，交给主窗口用的同一个 router；
  - requestId 即幂等键；
  - 错误按冻结文档 §6 映射成小写码，原码放在 `details.aiCode`；
  - 调用方身份取自连接（owner → `uid:<uid>` 作用域），不看参数。
- `runtime.capabilities` 增加可选字段 `gui`，取代 ai/1 的同名方法。
- Runtime 增加扩展方法注册：要求先握手；遵守订阅连接的限制；AI 服务未启动时返回 capability_missing。
- CLI 的 `rpc` / `ai` / `gui` 命令组改为连接 Runtime 端点，在客户端内部完成 ai/1 ↔ runtime/1 的转换，命令用法不变。

## 自动化测试

`swift test`：455 项全部通过，退出码 0。新增 SingleEndpointTests：
- ai.* 在 Runtime 端点上应答；同一 requestId 写两次只算一次；响应里没有密钥；错误映射正确（`not_found` 带 `aiCode`，参数错误为 `invalid_argument`）。
- 一个 capabilities 应答里同时列出 ai.*、gui.runs.*、Runtime 自己的方法和 `gui` 字段，并符合 Schema。
- AI 服务未启动时返回 capability_missing；未握手时返回 handshake_required。

合同测试：Runtime 自己的方法与 `RuntimeMethod` 一一对应；servedBy 的方法正好等于 ai/1 的全部操作（`runtime.capabilities` 除外），引用都能在 ai-gui/v1 中解析；已撤销的名字只能以 transitional 状态出现，并注明删除它的 PR。

## 真机（测试副本 /tmp/adt-a2）

| 检查 | 结果 |
| --- | --- |
| 副本目录里的 socket | **只有 `side.runtime.sock`**，没有 ai.sock |
| `runtime capabilities` | 64 个方法，其中 ai.* 27 个；有 `gui` 字段 |
| `agentdesktop ai capabilities` | ok，返回 GUI 后端能力（从 `gui` 字段取） |
| `ai connections list` | ok，空列表 |
| `ai connections create --credential-stdin`，用同一个幂等键执行两次 | 两次都 ok，connectionId 相同；列表里只有 1 条；输出不含密钥 |
| `ai connections get --id conn_missing` | NOT_FOUND，退出码 4 |
| 密钥落盘位置 | 只在副本自己的 `test-credentials/cred_*` 文件里（0600）；ai.sqlite、请求账本和输出中都没有 |

清理：停止副本，删除目录。
