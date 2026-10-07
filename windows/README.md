# AgentDesktop for Windows — contract layer

C# counterpart of the Swift `AgentDesktopContracts` target (spec §03.3, T13). It speaks AI/GUI contract v1 with the same semantics and wire values:

- `StrictJson` / `JsonValue`: refuses duplicate keys, nesting deeper than 64, invalid UTF-8, lone surrogates, numbers that overflow and trailing data; keeps member order; encodes one line, byte for byte like Swift.
- `SchemaRegistry`: JSON Schema 2020-12 subset covering every keyword in `contracts/ai-gui/v1`; unknown keywords are refused at load; `format` (date-time, uuid, uri) is asserted.
- `ContractBundle`: the two schemas and the 32-operation catalog, embedded straight from `contracts/ai-gui/v1` (no copies).
- `Envelope`, `FrameReader`, `RpcRouter`: 1 MiB frames including LF, v1 vs legacy routing, UNSUPPORTED_SCHEMA / UNSUPPORTED_COMMAND, requestId correlation, refusals that are themselves valid `ErrorResponse` envelopes (`details.reasonCode`, `details.fieldErrors`), results checked against `<command>_result`.

This is not G6. The Windows native runtime, DPAPI credentials, the NamedPipe endpoint and the AI/GUI services are not here yet.

## Build and test

The SDK is pinned in `global.json` (.NET 10.0.401, latest patch). It builds and tests on macOS, Linux and Windows; nothing here calls Windows APIs.

```
dotnet test windows/AgentDesktop.sln
```

`tests/.../Fixtures/cross-platform-envelope.json` lists frames the Swift and C# layers must judge identically; the Swift test suite reads the same file.
