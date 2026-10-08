# 产物按 ID 取（PR2c）验收记录（2026-10-08）

依据 `docs/architecture/runtime-api-v1-freeze.md` §5：observe 不再返回文件路径；客户端只能凭 `artifactId` 经 `artifact.show` / `artifact.read` 取得，且只能取到自己产生的（owner 可以取全部）。

## 自动化测试

`swift test`：355 项全部通过，退出码 0。新增：

- RuntimeArtifactTests
  - 截图按 ID 给出、分块读回：Observation 中没有 `path`，也不含存储目录；`artifact.show` 与 observe 给出的 sha256、byteSize 一致；按 2 字节分块读回后哈希一致；offset 越界时返回 invalid_argument。
  - 其他客户端看不到、ID 不能逃出存储目录：另一个主体读 show/read 都返回 not_found，owner 能读；`art_..`、`../art_1`、`art_1.meta` 等 ID 一律无效。
  - 产物与其记录文件均为 0600。
- CLI
  - `--image-output` 走 show + 两次 read，拿到 70 万字节的完整内容；
  - 哈希不符时不写文件，退出码 7。

## 真机结果（测试副本 /tmp/adt-acc，计算器）

| 用例 | 结果 |
| --- | --- |
| `observe --image-output` | image 只有 artifactId / mediaType / 3840×2160 / byteSize 15,124,165 / sha256，没有 path，整个结果里不出现存储目录；保存的文件大小与哈希一致，权限 0600，PNG 文件头 |
| `artifact get <id> --out` | 约 30 块读完 15 MB，耗时 3.0 秒，与第一次保存的文件逐字节相同 |
| `artifact show <id>` | 元数据正确 |
| 带 `../` 的 ID | 在 Schema 校验阶段被拒（schema_invalid） |
| 不存在的 ID | not_found |
| 存储目录 | `<id>.png` 与 `<id>.meta.json` 均为 0600 |

清理：关闭会话、退出计算器、销毁 Desktop、停止测试副本、删除 /tmp/adt-acc。未触碰产品 endpoint。

## 留给后续

- MCP 的 observe 工具与 Python/TS SDK 随 PR #29 rebase 时改用 artifact.read（MCP 可直接返回 image content）。
- 15 MB 的 4K 截图分块读需要约 3 秒。等 Explorer 的模型输入改走裁剪后的小图产物时，再评估是否需要提供缩略图。
