# 事件订阅（PR2e / A5 的 events.subscribe）验收记录（2026-10-08）

依据 `docs/architecture/runtime-api-v1-freeze.md` §4。

## 自动化测试

`swift test`：359 项全部通过，退出码 0；新增的事件流测试连续跑 3 次均通过。

新增 RuntimeEventStreamTests：

| 测试 | 断言 |
| --- | --- |
| aGlobalSubscriptionPushesEveryRunsEventsInOrderAndRefusesOtherRequests | 真实 socket 上的全局订阅：每帧符合 EventFrame，游标严格递增且不重复；订阅中的连接上其他请求返回 conflict（reason subscribed）；`events.unsubscribe` 后连接恢复请求模式；从某个游标恢复订阅，不丢也不重 |
| aRunStreamStartsAtTheBeginningAndClosesAfterTheRunEnds | 单个 Run 的流默认从序号 1 开始；Run 结束、事件推完后服务端关闭连接，最后一帧是 run.ended；订阅不改变 Run 的结果 |
| closingAStreamStopsNoRunAndAControlConnectionCannotBecomeOne | 持有未结束 Delegated Run 的控制连接上订阅，返回 conflict（reason control_connection）；观察者断开后，该 Run 仍是 running |
| aPrincipalSeesOnlyItsOwnRunsAndAStaleCursorIsSaidSo | 其他主体收不到别人的 Run 事件，也订阅不了别人的 Run（not_found）；超出存储范围的游标返回 events_cursor_expired；owner 能看到全部 |

CLI：`events watch` 的参数映射；jsonl 格式允许用于 `events watch`；`--format json` 与非法 `--after` 不发起连接。

## 真机结果（测试副本 /tmp/adt-acc，计算器）

| 用例 | 结果 |
| --- | --- |
| `events watch --format jsonl` 全局订阅；同时另一个终端执行 `session exec`，子进程里做一次 observe | 依次收到 run.started → run.finishing → run.quiescent → run.ended，游标 5→8 连续 |
| `events watch --run <id>` 盯一个 5 秒的 exec Run | 从序号 1 开始输出 4 个事件；Run 结束后流自动关闭，退出码 0 |
| 在 Run 进行中 kill 全局观察者 | Run 照常 ended/success（exit 0），不受影响 |
| `events watch --after 6` | 收到游标 7–12，不丢不重 |
| `events watch --after 9999` | events_cursor_expired，退出码 5 |

清理：退出计算器、销毁 Desktop、停止测试副本、删除 /tmp/adt-acc。未触碰产品 endpoint。

## 发现并修复

CLI 原来只允许 `run events` 使用 `--format jsonl`，导致 `events watch --format jsonl` 被拒。已放开，并补了测试。

## 留给后续

- Python/TS SDK、MCP 的订阅接口随 #29 跟进。
- 主窗口会在进程内直接读 RunStore 或使用本订阅，由 UI 线决定。
