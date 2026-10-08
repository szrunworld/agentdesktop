#!/bin/bash
# Fail if the product silently returns to an external or partial engine checkout.
set -euo pipefail
ROOT="${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
ENGINE="$ROOT/engine"
refuse() { echo "error: $*" >&2; exit 1; }
[[ -d "$ENGINE" && ! -L "$ENGINE" && ! -e "$ENGINE/.git" ]] || refuse "engine/ must be source in this repository"
for path in Package.swift Sources/SecondScreenCore/InputEngine.swift Sources/SecondScreenRuntime/AgentRuntime.swift Sources/TarsAgent/Learning.swift Sources/TarsAgent/Procedure.swift Sources/ScreenCLI/main.swift Tests/TarsAgentTests/TarsAgentTests.swift windows/SecondScreen.sln optional/mobile/macos/AndroidMirror.swift; do
    [[ -f "$ENGINE/$path" ]] || refuse "missing local core: engine/$path"
done
grep -Fq '.package(path: "engine")' "$ROOT/Package.swift" || refuse "product must resolve the local package"
if grep -Eq 'package\(url:.*2ndscreen' "$ROOT/Package.swift"; then refuse "retired external engine dependency"; fi
if [[ -f "$ROOT/Package.resolved" ]] && grep -q '"2ndscreen"' "$ROOT/Package.resolved"; then refuse "retired engine pin"; fi
for path in Sources/ScreenCLI/AgentBridge.swift Sources/ScreenCLI/TaskCommand.swift Sources/TarsAgent/Bridge.swift Sources/SecondScreen/main.swift packages/task-runtime scripts/install-task-runtime.sh; do
    [[ ! -e "$ENGINE/$path" ]] || refuse "obsolete active entry: engine/$path"
done
echo "Local native core and current product entrypoints verified"
