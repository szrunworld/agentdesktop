#!/bin/bash
# Zed manual step, part 1 of 2 (docs/acp/tests/e2e-runbook.md §三.1).
#
#   scripts/acp/zed-capture/setup.sh            build, prepare, launch an isolated Zed
#   scripts/acp/zed-capture/setup.sh --print    only print the agent_servers snippet
#
# Never touches ~/.config/zed or ~/Library/Application Support/Zed: Zed is
# started with --user-data-dir, which (Zed 1.23.2, crates/paths) moves both
# the data directory and the config directory (<dir>/config/settings.json).
# The agent is the dev entry in --demo mode (no Runtime, no GUI input),
# wrapped by capture-agent.mjs, which records every frame under
# /tmp/adt-zed-capture-<time>/.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
zed_cli="${ZED_CLI:-$(command -v zed || echo /opt/homebrew/bin/zed)}"
node_bin="$(node -p 'require("fs").realpathSync(process.execPath)' 2>/dev/null)" || { echo "node is required"; exit 2; }
dev="$repo/.build/debug/agentdesktop-acp-dev"
cap="/tmp/adt-zed-capture-$(date +%Y%m%d-%H%M%S)"
name="AgentDesktop (dev demo)"

snippet() {
  # $1: capture dir
  cat <<EOF
{
  "agent_servers": {
    "$name": {
      "type": "custom",
      "command": "$node_bin",
      "args": ["$here/capture-agent.mjs"],
      "env": {
        "ADT_ZED_CAPTURE_DIR": "$1/frames",
        "ADT_AGENT_COMMAND": "[\\"$dev\\", \\"--demo\\", \\"--state-dir\\", \\"$1/acp-state\\"]"
      }
    }
  }
}
EOF
}

if [ "${1:-}" = "--print" ]; then
  echo "# Add this to an ISOLATED Zed settings file only (setup.sh does it for you):"
  snippet "$cap"
  exit 0
fi

echo "== 1/4 Zed"
"$zed_cli" --version || { echo "Zed CLI not found at $zed_cli"; exit 2; }
# Zed on macOS allows one running instance per user and release channel,
# whatever the data directory, so a running Zed would swallow the launch.
if pgrep -f "/Applications/Zed.app/Contents/MacOS/zed" >/dev/null; then
  echo "Zed is running. Please quit it (Cmd-Q in Zed), then run this script again."
  echo "(Your own Zed settings and windows are not changed; they come back the next time you open Zed.)"
  exit 1
fi

echo "== 2/4 build the dev entry"
(cd "$repo" && swift build --product agentdesktop-acp-dev) || { echo "swift build failed"; exit 2; }
[ -x "$dev" ] || { echo "no $dev"; exit 2; }

echo "== 3/4 isolated Zed profile in $cap"
mkdir -m 700 "$cap" "$cap/zed-data" "$cap/zed-data/config" "$cap/frames" "$cap/acp-state" "$cap/project" || exit 2
snippet "$cap" > "$cap/zed-data/config/settings.json"
chmod 600 "$cap/zed-data/config/settings.json"
echo "# AgentDesktop Zed capture test project (empty on purpose)" > "$cap/project/README.md"
echo "$cap" > /tmp/adt-zed-capture.last

echo "== 4/4 launch Zed (isolated)"
"$zed_cli" --user-data-dir "$cap/zed-data" -n "$cap/project" || { echo "Zed launch failed"; exit 2; }

cat <<EOF

Zed is open with a separate, empty profile. In that window:
  1. Open the Agent panel (Cmd-?  or  View → Agent Panel).
  2. New Thread (+) → choose "$name".
  3. Type /help and press Enter. Wait for the reply.
  4. Quit Zed (Cmd-Q).
Then run:  scripts/acp/zed-capture/collect.sh
EOF
