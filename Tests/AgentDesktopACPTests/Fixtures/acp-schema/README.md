# Vendored ACP schema (lane T)

Byte copies of the official Agent Client Protocol schema for the version
this build speaks (docs/acp/02-protocol-version.md). Tests validate every
message the v1 encoder emits against `v1/schema.json`.

| File | Source | SHA-256 |
| --- | --- | --- |
| `v1/schema.json` | https://raw.githubusercontent.com/agentclientprotocol/agent-client-protocol/1c2b84c785c923ed283a4e7ea3badb2422596418/schema/v1/schema.json | 3c17bd6385d90cf672d8a661fddc359d73422cf8b8ce6865213d25cfd4c0eca7 |
| `v1/meta.json` | https://raw.githubusercontent.com/agentclientprotocol/agent-client-protocol/1c2b84c785c923ed283a4e7ea3badb2422596418/schema/v1/meta.json | 061edb6efa8fb2aa2792459a86ec7268de5fe665bba48b2ffe7939df01481f88 |

- Repository: agentclientprotocol/agent-client-protocol, `main` at
  `1c2b84c785c923ed283a4e7ea3badb2422596418` (2026-10-08T02:00:23Z).
- Release: `schema-v1.24.1` (2026-09-30), protocol version `1`, stable
  surface only (`schema.unstable.json` is not vendored and not used).
- v2 (`schema-v2.0.0-alpha.7`) is an upstream draft and is not vendored.

To update: download both files at a new commit, replace them, update this
table (`shasum -a 256`), and run `swift test --filter AgentDesktopACPTests`.
