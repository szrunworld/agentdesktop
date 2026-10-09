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
- 迁移日志 `migration-log.jsonl`（0600）：每个被改写的文件记**两行**。改写前一行 `status: "intent"`，带 sessionId、条目数、用户条目清洗数、Agent 条目改写数和保留数、标题是否重置；改写后一行 `status: "completed"`、`status: "failed"`（带错误码）或 `status: "uncertain"`（已改名、持久化未确认）。**只有 `completed` 才表示该文件已完成迁移**；只有 `intent`、没有后续 `completed` 的，表示未完成（可能是改写失败，也可能是写 `completed` 时出错）。`completed` 只会在改名和所在目录都已 fsync 之后才写。日志**不记录任何原文**。这个日志只有测试读取，产品、清理、恢复、审计代码都不读。
- 顺序：每个文件先把 `intent` 行写入并 fsync，再改写文件（临时文件 fsync、改名、目录 fsync），最后写 `completed`；**`intent` 写不进去，整个迁移立即停止**，这个文件和之后的文件都不改写。日志以半行结尾时不再追加，迁移保持未完成，需要人工处理。
- 失败处理（Kevin 2026-10-09）。原则：普通文件的失败可以局部隔离；会影响事务日志可信度的失败，必须全局停止。

  | 失败类型 | 处理 |
  |---|---|
  | 写 `intent` 失败 | 立即停止整个迁移 |
  | 单个文件改写失败，结果明确（改名前失败） | 记 `failed`，继续处理后续文件，整体不标为完成 |
  | 单个文件改写结果不确定（已改名，之后打开目录或目录 fsync 失败） | 记 `uncertain`；之后不再自动处理这个文件，留给人工 |
  | 写 `completed`、`failed` 或 `uncertain` 记录失败 | 立即停止整个迁移 |
  | 日志读不了、有无法解析的行、状态不是 intent/completed/failed/uncertain 之一、`file` 不是 history/binding、`sessionId` 不合法（与会话文件名同一套校验，不能为空）、不是普通文件 | 不开始迁移，等人工核实（末尾的半行由追加检查处理：不再追加；缺少状态的行按 intent 处理） |
  | 旧文件里的会话 ID 与文件名不一致 | 不处理，留给人工（阻断记录按会话 ID 对应文件，对不上就无法可靠挡住）；迁移不算完成 |
  | 某文件最后一条记录是孤立的 `intent`（结果从未记录下来） | 与 `uncertain` 相同：不自动处理，留给人工；只要还有这样的文件，迁移就不算完成 |

  一次追加如果报告失败（包括新建日志后目录 fsync 失败），刚写入的那一行会被截掉，不会留下孤立的 `intent` 挡住一个没被改动过的文件；截断不成功时，这个 store 不再写日志。

  **`uncertain` 和孤立 `intent` 的人工处理**：确认该文件的实际内容（是否已是 format 2，是否含原文）后，在日志末尾为同一文件手工追加一行 `completed`（已确认迁移）；如果内容需要重新迁移，追加一行 `failed`。只要这个文件的最后一条记录不再是 `uncertain`，下次读写会话时就会按常规规则处理它。
- 任何疑问都让迁移保持"未完成"，下次读写时重试：目录读不了、文件打不开（文件已被删除除外）、对应的绑定文件读不了（只有绑定文件确实不存在时，才把它当成"没有 Run"）、编码失败、改写失败。在此期间，读取 format 1 文件时会在内存里清洗。
- 边角情况：
  - 某个文件改写失败时，它保持 format 1，错误另记一行日志；在内存里清洗后返回，不会原样返回；同一个 store 下次读写时就会重试。
  - 无法解码的文件会被跳过（和以前一样不会被读取）。
  - 绑定文件确实不存在时，历史里所有状态行都按"不属于本会话"清除。
  - 旧版本写下的其他状态句式（比如"任务 <run>：…"、"结果待核实"），不在严格匹配的格式里，会被清除。这是故意选择的安全默认。
  - 迁移完成后，第二个 store 实例不再改写，也不再写日志。
- **限制：原地改写只保证当前可访问的历史文件已经脱敏，不等于安全擦除。** 旧内容可能还留在 APFS 快照、Time Machine 备份或存储介质的旧数据块里。验收和对外说明只能写"当前历史文件已脱敏"，不得写"所有历史副本均不可恢复"。

## 三、真实测试只连测试自己启动的 Runtime

`ACPTestRuntimeChild` 负责启动和回收子进程，`ACPTestPinnedTransport` 负责在每条连接上核对对端身份。

1. **独立目录：** 每次启动都用 `mkdtemp` 新建 `/tmp/adt-acp-<pid>-XXXXXX`，权限 0700。子进程只拿到 `AGENTDESKTOP_SOCKET=<目录>/side.sock`，其余 `AGENTDESKTOP_*` 环境变量全部清掉。
2. **进程由测试掌握：** 用 `posix_spawn` 启动，清空继承来的信号屏蔽；`POSIX_SPAWN_CLOEXEC_DEFAULT` 让子进程不继承任何描述符，stdin 指向 /dev/null，只保留 stdout/stderr。测试持有 pid，只有测试自己调用 `waitpid` 回收；子进程被回收之前，它的 pid 不可能被别的进程占用。
3. **启动即确认可识别：** 启动后立刻通过 `task_name_for_pid` + `TASK_AUDIT_TOKEN` 确认内核能识别这个子进程。识别不了就终止子进程、启动失败（fail closed）。
4. **连接后、发出任何字节前，按顺序检查：**
   - 路径必须正好是该子进程的 endpoint，并通过 `ACPTestEndpointGuard`（socket 类型、属主是当前用户、不是符号链接或硬链接、不在产品目录）；
   - 用 `LOCAL_PEERPID` 和 `LOCAL_PEERTOKEN` 读取对端，两者必须一致；
   - `getpeereid` 必须是当前用户；
   - `child.owns(pid)`：pid 相同，且子进程尚未被回收；
   - 在内核给出的 Unix socket 表里（`proc_listallpids` + `PROC_PIDFDSOCKETINFO`，路径先按目录 realpath 规范化），绑定在该 endpoint 上的进程只有这个子进程；
   - 对端程序路径必须读得到，且不在 AgentDesktop 产品的 app 包内（按 bundle id `com.agentdesktop.app` 判断，不论安装位置；不再按"是否在 /Applications 下"判断，因为 CI 的 Python 就装在 /Applications 下的 Xcode 包里）；
   - 能读到内核的进程列表，且对端没有在产品目录下绑定 socket。不再使用 lsof：它在不同 macOS 版本上 NAME 列的格式不一样，CI 上曾因此把合法子进程误拒。

   任何一项不满足就关闭连接并拒绝。
5. **没有 PID 回退：** 没有子进程就拒绝（fail closed）。外部传入的 endpoint 或 PID 都不再被接受。
6. **握手后再核对一层：** 握手之后再检查 Runtime 自报的 endpoint（`ACPTestVerifiedClient`）。这只是第二层，不作为身份依据。
7. **中断后的清理：** /tmp 下的测试目录都带进程号（`adt-acp-<pid>-…`、`adt-ptest-<pid>-…`、`adt-curtest-*-<pid>-…`）。之后某次运行时，会清掉进程已不存在的同名规则目录；只删当前用户的普通目录，不跟随符号链接。删除前还要求：没有任何进程在该目录下绑定 socket（读不到 socket 表就全部保留）；目录本身和**第一层**条目两小时内没有修改（mtime）。**检查范围只到第一层，不扫描整个目录树**（Kevin 2026-10-09：本轮不做递归扫描）。已知限制：更深层的修改（例如子 Runtime 写入 `side.runtime/` 下的记录）看不到，保护正在使用的目录靠的是 socket 检查；如果以后证明深层文件在没有活跃 socket 时仍可能被使用，需要重新评估。
8. **清理范围：** `stop()` 回收子进程，并删除它自己的目录，前提是 realpath 以 `/private/tmp/adt-acp-` 开头。不碰其他任何路径。

起保护作用的是"pid 相同 + 尚未回收 + endpoint 只由子进程持有"这三条，**不依赖 pidversion**。内核给出的对端审计令牌，是按查询时持有该 pid 的进程现场生成的（b9 实测：exec 之后上报的是新版本号），所以拿 pidversion 做比较没有意义，代码里已删除。

`LOCAL_PEERPID` 记录的是 socket 创建时的 pid。如果一个更早持有同一 pid 的进程先建好监听 socket，把它交给别的进程后退出，之后我们的子进程恰好拿到这个 pid，单看 pid 会误判。endpoint 持有者检查要求这个 socket 名下只有子进程，正是为了堵这种情况。

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
- 内核 socket 表读不到；
- 没有子进程。

这些测试统计对端实际收到的字节数，每个拒绝场景都断言为 0。
