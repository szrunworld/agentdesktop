# AgentDesktop native core

This is a local package in AgentDesktop, maintained and released with the product. It is not a dependency on the retired source repository.

- `SecondScreenCore`: current native display, window, observation and input implementation.
- `SecondScreenRuntime`: current host service and desktop lifecycle.
- `TarsAgent`: reusable model, parser, planner, learning and procedure code.
- `ScreenCLI`: `agentdesktop-cli`, packaged as the public `agentdesktop` command.
- `windows`: existing C# backend and its tests, distinct from the new AI/GUI contract layer.
- `optional/mobile`: retained phone adapters; not enabled by the default product.

Internal identifiers remain implementation details. There is no old App product, Bridge command, TS task host, old CLI alias or old configuration fallback. Use root build scripts and [current architecture](../docs/architecture.md). The complete import and historical semantic tests remain available from this repository's source-import commit.
