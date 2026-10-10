# 中性示例 Agent（`examples/neutral-agent`）

一个不属于任何产品的最小外部 Agent，用 Python SDK（`sdks/python/agentdesktop_client`）走完外部 Agent 的完整生命周期，并把每一步的回执打印成一行 JSON：

```
handshake → 配对（pair）→ 等主人在 Agent Desktop 窗口批准 → 列 Desktop
         → 观察（observe）→ 动作（act，可选）→ 断开 → 重连
```

只依赖 Python 3.9+ 标准库和仓库里的 SDK，不需要安装任何东西。

## 运行

```bash
# 推荐先在测试副本上做只读检查：只握手、配对、列 Desktop、断开、重连
AGENTDESKTOP_SOCKET=/tmp/adt-a7/side.sock \
  python3 examples/neutral-agent/neutral_agent.py --list-only

# 完整流程：观察授权里的第一个 Desktop，不发送任何输入
python3 examples/neutral-agent/neutral_agent.py --desktops created

# 显式要求一个动作（只发一次，不重试）
python3 examples/neutral-agent/neutral_agent.py --desktop-id d_123 --act click:el_3 --request-id demo-click-1
```

Runtime 的位置依次取：`--endpoint`、`AGENTDESKTOP_SOCKET`、`AGENTDESKTOP_ENDPOINT`、已安装产品的 `~/Library/Application Support/AgentDesktop/runtime.sock`。

| 参数 | 含义 |
| --- | --- |
| `--credential-file` | 凭据文件，默认当前目录下的 `neutral-agent.credential.json`。不存在时先配对，批准后以 0600 写入；存在时直接使用，不再配对 |
| `--name` / `--publisher` | 配对时在确认窗口里显示的名字（自报，窗口会如实标注） |
| `--capabilities` / `--desktops` / `--apps` | 配对请求的授权范围，逗号分隔；默认只要 `observe,act` |
| `--desktop-id` | 观察哪个 Desktop；默认授权里可见的第一个。不在授权里的 Desktop 不会被触碰 |
| `--act` | 可选的一个动作：`key:escape`、`click:el_3`、`press:el_3`。**不给就不发送任何输入** |
| `--request-id` | 动作的 requestId。结果不确定时用它查询（`request.show`），不要重发 |
| `--list-only` | 只做握手和列表（测试副本上的只读检查） |
| `--no-pair` | 没有凭据时不发起配对，直接报 `pairing_required` |

## 输出

每步一行，形如：

```
[handshake] {"apiVersion": "agentdesktop.runtime/1", "instanceId": "rt_…", "principal": {"role": "unpaired", …}, "product": "AgentDesktop"}
[pair.start] {"pairingId": "pair_…", "shortCode": "123456"}
[pair.approved] {"clientId": "app:…", "mode": "0600", "savedTo": "neutral-agent.credential.json"}
[connect] {"clientId": "app:…", "principal": {"role": "paired", …}}
[desktops] [{"desktopId": "d_…", "name": "…", "state": "ready"}]
[session.open] {"desktopId": "d_…", "sessionId": "s_…"}
[observe] {"elements": 12, "sample": […], "snapshotId": "obs_…"}
[act:skipped] {"reason": "no --act given; no input was sent"}
[disconnect] {"clientId": "app:…"}
[reconnect] {"clientId": "app:…", "desktops": 1, "sameClient": true}
```

配对码会同时打印到 stderr，请在 Agent Desktop 窗口里核对后再批准。

## 拒绝与错误

这些情况只有用户能解决，示例会说明原因并以退出码 3 结束，**不重试动作**：

| 错误码 | 含义与处理 |
| --- | --- |
| `pairing_required` | 还没配对（或用了 `--no-pair`）。重新运行并在确认窗口批准 |
| `permission_denied` | 配对被拒绝或过期，或操作只属于 AgentDesktop 的主人 |
| `grant_missing` | 授权里没有这项能力、这个 Desktop 或这个 App；在 Agent Desktop 窗口里修改授权 |
| `grant_expired` | 授权过期，请续期 |
| `client_revoked` | 这个 Agent 已被移除，旧凭据永久失效；删除凭据文件后重新配对 |
| `runtime_offline` | 没有找到 Runtime |

`request_acceptance_unknown`（动作发出后连接断开，不知道是否生效）退出码为 1，并提示用 requestId 查询，同样不重发。

## 安全说明

- 凭据文件只有用户级别的保护（同一用户的进程都能读）。签名 App 应把凭据放进钥匙串，见 `docs/security/a4-identity.md`。
- 示例只在授权范围内工作：Runtime 按当前授权检查每个请求，示例自己也不会去碰列表之外的 Desktop。
- 断开连接后，这条连接发起的短 Run 随之结束，不会再有输入。

## 测试

测试用一个假的 Runtime（Unix socket），不连接真实 Runtime，不碰任何窗口：

```bash
python3 -m unittest discover -s examples/neutral-agent -v
```
