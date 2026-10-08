# 12 · 历史记录隐私与真实测试隔离（#141）

依据：Kevin 对 #141 的安全裁决（2026-10-09）；b9 两轮独立复审。本文件只描述 ACP 模块和测试基础设施，不是生产 Runtime 身份方案。

## 一、会话历史里保存什么

| 内容 | 实时显示（编辑器） | 落盘（`<sid>.history.json`） |
|---|---|---|
| 用户输入原文 | 编辑器自己显示 | 永不保存；固定占位「（此处为用户输入，内容不保存）」 |
| 未知命令提示 | 「没有 /词 这个命令」 | 「没有这个命令。」 |
| 参数校验问题 | 逐条列出 | 只存「/命令 的输入不符合要求，未创建任务。」 |
| Runtime 的提问 | 原文（经脱敏） | 「任务 X 需要你的回答（问题内容不保存）」 |
| Runtime 拒绝 | 只显示白名单错误码 | 同左 |
| `/runs`、`/status` 的参数 | 不是本会话的 Run 一律拒绝，不回显 | 同左 |
| 任务受理、状态、结果、时间线 | 显示 | 保留（经 `ACPRedactor`）；Run 事件从 Runtime 重新回放 |
| 会话标题（`<sid>.json`） | — | 只有命令目录里存在的命令才用规范命令名，其余一律「对话」 |

存储层自己也会把 `kind == user` 的内容写成占位，不依赖上层。重新打开带用户输入的会话时，会显示一条说明（不落盘）：原文没有保存，任务状态、动作结果和时间线照常保留。

## 二、旧历史（format 1）迁移

- 时机：每个 `ACPFileSessionStore` 实例第一次读写时执行一次，在目录锁（`.lock` + flock）内原地改写，revision 不变。
- 用户条目一律换成占位。
- Agent 条目只去掉回显（`ACPHistoryScrub`），其余保留：
  - 未知命令；
  - 参数校验问题；
  - 提问；
  - 旧版拒绝原文；
  - `/runs` 里不属于本会话的 id 行。
- 标题一律改为「对话」。
- 迁移日志 `migration-log.jsonl`（0600）：每个文件一行，记录 sessionId、条目数、用户条目清洗数、Agent 条目改写数和保留数、标题是否重置、错误码。**不记录任何原文。**
- 边角情况：
  - 某个文件改写失败时，它保持 format 1，错误写进日志；之后每次读取都在内存里按同样规则清洗，不会原样返回；下一个 store 实例会重试。
  - 无法解码的文件会被跳过（和以前一样不会被读取）。
  - 绑定文件丢失时，历史里所有 `/runs` id 行都按"不属于本会话"处理。
  - 迁移完成后，第二个 store 实例不再改写，也不再写日志。
- **限制：原地改写只保证当前可访问的历史文件已经脱敏，不等于安全擦除。** 旧内容可能还留在 APFS 快照、Time Machine 备份或存储介质的旧数据块里。验收和对外说明只能写"当前历史文件已脱敏"，不得写"所有历史副本均不可恢复"。

## 三、真实测试只连测试自己启动的 Runtime

`ACPTestRuntimeChild` 负责启动和回收子进程，`ACPTestPinnedTransport` 负责在每条连接上核对对端身份。

1. **独立目录：** 每次启动都用 `mkdtemp` 新建 `/tmp/adt-acp-XXXXXX`，权限 0700。子进程只拿到 `AGENTDESKTOP_SOCKET=<目录>/side.sock`，其余 `AGENTDESKTOP_*` 环境变量全部清掉。
2. **进程由测试掌握：** 用 `posix_spawn` 启动，并清空继承来的信号屏蔽。测试持有 pid，只有测试自己调用 `waitpid` 回收；子进程被回收之前，它的 pid 不可能被别的进程占用。
3. **启动即取身份：** 启动后立刻通过 `task_name_for_pid` + `TASK_AUDIT_TOKEN` 读取子进程的审计令牌，记下 pidversion。取不到就终止子进程、启动失败。
4. **连接后、发出任何字节前，按顺序检查：**
   - 路径必须正好是该子进程的 endpoint，并通过 `ACPTestEndpointGuard`（socket 类型、属主是当前用户、不是符号链接或硬链接、不在产品目录）；
   - 用 `LOCAL_PEERPID` 和 `LOCAL_PEERTOKEN` 读取对端，两者必须一致；
   - `getpeereid` 必须是当前用户；
   - `child.owns(pid, pidversion)`：pid 相同、pidversion ≥ 启动时记下的值、子进程尚未被回收；
   - 对端程序路径必须读得到，且不在 `/Applications`；
   - `lsof -b -nP -U -F pn` 能正常运行，且对端没有在产品目录下绑定 socket。

   任何一项不满足就关闭连接并拒绝。
5. **没有 PID 回退：** 没有子进程就拒绝（fail closed）。外部传入的 endpoint 或 PID 都不再被接受。
6. **握手后再核对一层：** 握手之后再检查 Runtime 自报的 endpoint（`ACPTestVerifiedClient`）。这只是第二层，不作为身份依据。
7. **清理范围：** `stop()` 回收子进程，并删除它自己的目录，前提是 realpath 以 `/private/tmp/adt-acp-` 开头。不碰其他任何路径。

pidversion 用"≥"而不是"="：exec 会让 pidversion 增大（例如 `/usr/bin/python3` 跳板会再 exec 一次）。比子进程启动时更早的同 pid 持有者，pidversion 一定更小。

### 运行方式

```sh
swift build --product AgentDesktopApp
ACP_TEST_RUNTIME_BINARY="$(swift build --show-bin-path)/AgentDesktopApp" \
  swift test --filter RuntimeBridgeSmokeTests
```

不设 `ACP_TEST_RUNTIME_BINARY` 时，Real 测试跳过。传输层的专项测试用 python 替身子进程，在任何机器上都会运行（`CurPinnedTransportTests`）：

- 正常连接；
- 其他进程占用 socket；
- 子进程退出后（未回收 / 已回收）路径被复用；
- 路径检查后 socket 被替换；
- 其他路径；
- 产品持有者；
- lsof 失败；
- 没有子进程。

这些测试统计对端实际收到的字节数，每个拒绝场景都断言为 0。
