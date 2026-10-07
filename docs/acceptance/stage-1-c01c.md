# 阶段 1 验收记录：C01c 通用 runtime 跑中性任务

日期：2026-10-07 22:24。机器：开发者的 MacBook Pro（macOS 15，Apple silicon）。

## 组合

| 组件 | 来源 |
| --- | --- |
| task runtime | 2ndscreen 分支 c01b-generic-build（PR #65）`scripts/install-task-runtime.sh DEST --generic`：bin/node 22.23.2、main.mjs、worker.mjs、build.json；`build.json.inputs` 无任何 `src/boss/` 模块，无 skills 目录 |
| 屏幕与输入 | Agent Desktop 0.1.0-dev（产品仓 main 6b9ff7d）以测试副本运行：runtime 通过 `SECONDSCREEN_APP` 指向 `build/Agent Desktop.app`、`SECONDSCREEN_SOCKET` 指向独立 socket，自行拉起副本；`SECONDSCREEN_CLI` 为包内 `libexec/2ndscreen` |
| 业务 Agent | 无。一个中性 echo 包（agent.json：mode task、executor process、protocol agent-jsonl/1、应用 com.apple.calculator、profile calc-800x600 `mainWindowMinWidth` 150），bin/agent.mjs 收到 task_start 后 observe 一次、提交一个 item、task_finished succeeded |
| 模型 | 无 provider，无密钥 |
| 旧 2ndscreen.app | 未运行、未引用 |

## 过程与结果

```
task host start            → running, worker pid 51962
task submit neutral.echo press --input '{"waitMs":0,"note":"c01c"}'
                           → queued
（3 次轮询后）
task outcome TASK_ID       → state succeeded, items: [{itemId echo, status committed,
                              data {input {...}, observed "observation", window "Calculator"}}],
                              actions {total 0, refused 0, unknown 0}
task host stop             → stopped
```

worker.log：`neutral.echo 0.1.0: runs tasks on request` → `task … started on request` → `task … succeeded` → `stopping: signal` → `ended com.apple.calculator (pid 52527), launched for its agent`。

持久化：`tasks.db` 的 agent_tasks 表有一行 `succeeded | press | neutral.echo`，result_json 含上述 item。停止后 Agent Desktop 副本上没有工作屏，计算器已退出。

## 结论

通用构建的 runtime 在没有 BOSS 代码、没有模型密钥、没有仓库开发环境、没有旧 2ndscreen.app 的情况下，经真实 worker、agent 宿主和 JSONL 子进程跑完一个中性任务并留下持久化结果。这验证的是装配与进程链路；审批、预算、产物采纳和恢复仍按 C03 至 C05 分别验收。

## 过程中发现

- profile 没写 `mainWindowMinWidth` 时，runtime 按 `logicalWidth` 的比例判断主窗口，计算器 198 点宽的窗口被当作"不消失的小窗口"而报 `login_required`。首次任务因此失败；写入 150 后通过。中性参考 Agent 的 profile 要带这个字段，或 runtime 对小窗口应用改判定方式（记入 C06）。
- 任务失败且宿主停止后，runtime 启动的计算器留在了用户显示器上（第二次运行时发现 pid 49777 仍在）；任务成功的那次宿主停止时正确退出了它。失败路径的应用清理待核对（记入 C05 接管与恢复）。
- Unix socket 路径不能超过约 100 字节，runtime 的 `SECONDSCREEN_SOCKET` 放在深层临时目录时报 `socket path too long`；产品 endpoint 和测试 socket 都应放在短路径。
