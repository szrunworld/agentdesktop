#!/bin/bash
# Builds everything the #127 / #142 real-device acceptance needs, from one
# checkout that holds main plus both PR branches (tools come from this kit,
# the code under test from that checkout), into $OUT (default
# ~/orca/.ios-ci/accept-127-142). Touches no device and starts nothing.
#   scripts/iphone-acceptance/prepare.sh [OUT]
set -euo pipefail
KIT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$KIT/../.." && pwd)"
OUT="${1:-$HOME/orca/.ios-ci/accept-127-142}"
WT="$OUT/checkout"
mkdir -p "$OUT/ev"
git -C "$REPO" fetch -q origin
rm -rf "$WT"
git -C "$REPO" worktree add -f "$WT" --detach origin/main >/dev/null
git -C "$WT" merge -q --no-edit origin/iphone-fix-status-2   # #142
git -C "$WT" merge -q --no-edit origin/iphone-fix-paste      # #127
git -C "$WT" log --oneline -3 > "$OUT/ev/checkout.txt"
(cd "$WT/engine" && swift build -c release --product agentdesktop-cli)
cp "$WT/engine/.build/release/agentdesktop-cli" "$OUT/agentdesktop-cli"
rm -rf "$OUT/harness"; cp -R "$KIT/harness" "$OUT/harness"
sed -i '' "s#\.\./\.\./\.\./engine#$WT/engine#" "$OUT/harness/Package.swift"
(cd "$OUT/harness" && swift build -c release)
swiftc -O "$KIT/watch.swift" -o "$OUT/watch"
swiftc -O "$KIT/clip.swift" -o "$OUT/clip"
echo "ready in $OUT (checkout: $(head -1 "$OUT/ev/checkout.txt"))"
