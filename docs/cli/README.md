# agentdesktop：命令行、MCP 与 SDK

所有入口说同一套 Runtime API（`agentdesktop.runtime/1`，契约在 `contracts/runtime/v1/`），由宿主里的同一个 Runtime 执行。入口本身不执行任何输入：控制权、快照复核、请求账本、停止都在 Runtime。

## 连接哪个 Runtime

| 顺序 | 来源 |
| --- | --- |
| 1 | `--endpoint PATH`（SDK：构造参数） |
| 2 | `AGENTDESKTOP_ENDPOINT` |
| 3 | `session exec` 的上下文文件（`AGENTDESKTOP_CONTEXT`）里的 endpoint |
| 4 | 已安装产品：`~/Library/Application Support/AgentDesktop/runtime.sock` |

AI/GUI 服务（`agentdesktop.ai/1`）在同目录的 `ai.sock`；`agentdesktop ai|gui|rpc` 默认连它。

## 典型流程（CLI）

```bash
agentdesktop runtime start
D=$(agentdesktop desktop create --size 1280x800 --format json | jq -r .data.desktopId)
PID=$(agentdesktop app launch --desktop $D --bundle-id com.apple.calculator --format json | jq -r .data.process.pid)
agentdesktop window bind --desktop $D --pid $PID
S=$(agentdesktop session open --desktop $D --format json | jq -r .data.sessionId)
O=$(agentdesktop observe --session $S --image-output shot.png --format json)
SNAP=$(echo "$O" | jq -r .data.snapshotId)
E7=$(echo "$O" | jq -r '.data.elements[] | select(.label=="7") | .id')
agentdesktop act click --session $S --snapshot $SNAP --element $E7
agentdesktop session close $S && agentdesktop desktop destroy $D
```

- 写命令（create/destroy/launch/bind/unbind/session open/close/act/run cancel）都有 requestId；`--request-id` 自定，未给时 CLI 生成并在发送前记到 `~/Library/Application Support/AgentDesktop/cli/requests.jsonl`。不确定是否生效时用 `agentdesktop request show <id>` 回查，或用同一个 `--request-id` 重试——Runtime 只会执行一次。
- 只给 Desktop 也可以：`agentdesktop observe --desktop $D`、`agentdesktop act click --desktop $D --snapshot $SNAP --element $E7`。act 只给 `--desktop` 时，Runtime 使用本客户端在这个 Desktop 上最早打开、仍未关闭的 Session，没有就按 `session.open` 的规则新开一个（同样要 act 能力、同样的授权检查）；输入始终在某个 Session 里发出。回执里的 `sessionId`（文本输出里的 `session`）就是它；Desktop 上有打开的 Session 时 `desktop destroy` 会被拒绝，需要先 `agentdesktop session close <sessionId>`。这次 act 失败时，为它新开的 Session 会被关掉（除非期间已被别的 act 复用）。
- 输出格式：`--format text`（默认）、`--format json`（stdout 上恰好一个 JSON 对象，即 Runtime 的响应信封）、`--format jsonl`（只用于 `run events` 和 `events watch` 这类事件流，每行一个事件；其他命令只有一个结果，用 `json`，给 jsonl 会以参数错误拒绝）。
- `act` 必须带快照，并在一个 Session 内执行（`--session`、`--desktop` 或 `session exec` 的上下文）；目标变化（窗口移动、重新绑定、进程重启、元素被新读取重编号）会被拒绝且不发送输入（`stale_observation`）。
- 连续脚本用 `session exec`：外壳持有 Run 和控制权，子程序里的 `agentdesktop` 自动加入该 Run；外壳退出或被杀，后续输入被阻断。

```bash
agentdesktop session exec --desktop $D -- /bin/zsh ./agent-flow.sh
```

- `run show/events/wait/cancel`：`cancel` 立即受理；`--wait` 等到输入确认静止；`wait` 与 Ctrl-C 只停止本地等待，不改变 Run。
- 退出码：0 完成，2 参数，3 Runtime 不在线，4 权限，5 冲突，6 版本/能力，7 已知失败，8 等待超时，9 结果未知（`ai|gui|rpc` 命令组沿用 AI/GUI 规范的退出码）。

- 物理 Desktop（你自己的显示器）只能由 Agent Desktop 主窗口开放给已配对的程序（Desktops › 开放我的显示器，Touch ID 确认）；`agentdesktop displays list|attach|detach` 映射到同样的 `hub.displays.*` 方法，但 socket 上的 CLI 是已配对客户端，会得到 `permission_denied / owner_only`，只在测试副本里有用。开放之后程序仍看不到任何窗口，每个窗口都要 `agentdesktop windows request` 并由用户 Touch ID 确认。

## MCP

`agentdesktop mcp` 在 stdio 上提供 MCP 工具（`desktop_create`、`app_launch`、`window_bind`、`session_open`、`observe`、`act_click`/`act_type`/`act_key`/`act_scroll`/`act_press`、`wait_for_element`、`run_show`、`run_cancel`、`request_show` 等）。`observe` 返回缩小后的截图，`act_*` 的 `x,y` 是这张图的像素，服务端换算回快照坐标。整个 MCP 会话用一条 Runtime 连接，客户端退出后它发起的输入全部停止。

Claude Code 配置示例：

```bash
claude mcp add agentdesktop -- "/Applications/Agent Desktop.app/Contents/Resources/bin/agentdesktop" mcp
```

### 只操作一个 Desktop：`--desktop-id`

`agentdesktop mcp --desktop-id <id>` 把这个 MCP 服务限定在一个 Desktop 上，即使配对 App 的授权覆盖了更多 Desktop：

- 不提供 `desktop_create`；调用它会被拒绝。
- 工具参数里的 `desktopId` 可以省略，省略时用这个 Desktop；写了别的 `desktopId` 一律拒绝（`permission_denied`，reason `desktop_out_of_scope`，未发出任何请求）。
- `sessionId`、`runId` 指向别的 Desktop 时同样拒绝（先经 Runtime 查出它属于哪个 Desktop；查不到就按查询的错误返回，不放行）。`request_show` 只返回记录在这个 Desktop 上的请求（别的 Desktop 的、以及没有记录 Desktop 的，如 `desktop.create`，一律拒绝）；`desktop_list` 只列这一个。
- `observe`、`wait_for_element` 可以不带 `sessionId`，直接作用于这个 Desktop。
- `app_list`、`window_list`、`runtime_status` 不属于某个 Desktop，照常可用（是否可见仍由授权决定）。

不给 `--desktop-id` 时行为不变。

```bash
claude mcp add agentdesktop-work -- "/Applications/Agent Desktop.app/Contents/Resources/bin/agentdesktop" mcp --desktop-id d_123
```

## Python SDK（`sdks/python`）

```python
from agentdesktop_client import RuntimeClient

with RuntimeClient() as c:
    d = c.create_desktop("demo", (1280, 800))["desktopId"]
    pid = c.launch(d, "com.apple.calculator")["process"]["pid"]
    c.bind_window(d, pid)
    with c.session(d) as s:
        o = s.observe()
        seven = next(e["id"] for e in o["elements"] if e["label"] == "7")
        s.click(o["snapshotId"], element=seven, request_id="calc-7")
    c.destroy_desktop(d)
```

在 `session exec` 里运行时，`c.session()` 不带参数即使用 exec 的 Session，动作自动进入 exec 的 Run。

## TypeScript SDK（`sdks/typescript`，Node ≥ 22.18）

```ts
import { RuntimeClient } from "@agentdesktop/client";
const c = new RuntimeClient();
const { desktopId } = await c.createDesktop({ name: "demo", width: 1280, height: 800 });
const s = await c.session(desktopId as string);
const o = await s.observe();
await s.click(o.snapshotId as string, { element: "el_7" }, "calc-7");
await s.close();
await c.destroyDesktop(desktopId as string);
c.close();
```
