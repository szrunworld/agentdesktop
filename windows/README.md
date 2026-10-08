# AgentDesktop for Windows — contract layer and configuration

C# counterpart of the Swift `AgentDesktopContracts` target (spec §03.3, T13). It speaks AI/GUI contract v1 with the same semantics and wire values:

- `StrictJson` / `JsonValue`: refuses duplicate keys, nesting deeper than 64, invalid UTF-8, lone surrogates, numbers that overflow and trailing data; keeps member order; encodes one line, byte for byte like Swift.
- `SchemaRegistry`: JSON Schema 2020-12 subset covering every keyword in `contracts/ai-gui/v1`; unknown keywords are refused at load; `format` (date-time, uuid, uri) is asserted.
- `ContractBundle`: the two schemas and the 32-operation catalog, embedded straight from `contracts/ai-gui/v1` (no copies).
- `Envelope`, `FrameReader`, `RpcRouter`: 1 MiB frames including LF, v1 vs legacy routing, UNSUPPORTED_SCHEMA / UNSUPPORTED_COMMAND, requestId correlation, refusals that are themselves valid `ErrorResponse` envelopes (`details.reasonCode`, `details.fieldErrors`), results checked against `<command>_result`.

## AgentDesktop.AI: configuration and credentials

C# counterpart of the Swift `AgentDesktopAI/Config` (T03/T04), same semantics:

- `ConfigStore`: SQLite (WAL, migrations; Microsoft.Data.Sqlite with the native library pinned at SQLitePCLRaw 2.1.13, above the release GHSA-2m69-gcr7-jv3q flags). Immutable revisions for connections, model profiles and GUI profiles; `expectedRevision` CAS answering CONFIG_CONFLICT with `currentRevision`; tombstones and reference protection; a default pointer with its own revision; cursors bound to their filter; at most one fallback, no self reference or cycle; idempotency per caller, command and key with an HMAC digest (local key kept in the credential store).
- `ICredentialStore`: `DpapiCredentialStore` (Windows; DPAPI CurrentUser, one file per secret in a directory whose ACL grants only the current user, inheritance cut; throws `PlatformNotSupportedException` elsewhere) and `InMemoryCredentialStore` (tests, injectable failures). Create and rotate follow pending → secret → activate → outbox; a revoked identity never resolves; recovery removes orphan secrets and replays the outbox.
- `EndpointPolicy`: https, or http to an explicit loopback host when the local option is on (localhost must resolve only to loopback); no userinfo, query, fragment or a base ending in chat/completions.
- `ConfigApplicationService`: the 21 configuration commands as `RpcRouter` handlers.

`tests/AgentDesktop.AI.Tests/Fixtures/cross-platform-config.json` is a 32-step configuration script both services must run with the same outcomes.

This is not G6. The Windows native runtime, the NamedPipe endpoint, the model service and the GUI services are not here yet. DPAPI is exercised only by the windows-latest CI job.

## Build and test

The SDK is pinned in `global.json` (.NET 10.0.401, latest patch). It builds and tests on macOS, Linux and Windows; the DPAPI test is skipped off Windows with its reason shown.

```
dotnet test windows/AgentDesktop.sln
```

`tests/.../Fixtures/cross-platform-envelope.json` lists frames the Swift and C# layers must judge identically; the Swift test suite reads the same file.
