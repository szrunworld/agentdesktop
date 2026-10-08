#!/bin/bash
# Zed manual step, part 2 of 2 (docs/acp/tests/e2e-runbook.md §三.1).
#
#   scripts/acp/zed-capture/collect.sh [capture-dir]
#       summarise and redact the capture inside the capture directory
#       (<cap>/redacted/); does not touch the repository
#   scripts/acp/zed-capture/collect.sh --to-evidence [capture-dir]
#       coordinator only: also copy <cap>/redacted/ to
#       docs/acp/tests/evidence/zed-initialize-<date>/
#   scripts/acp/zed-capture/collect.sh --cleanup [capture-dir]
#       delete the capture directory (after --to-evidence)
#
# The raw .bin files stay in /tmp: they hold the user's paths. Evidence
# keeps their sizes and SHA-256 so the redacted frames can be tied to them.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
mode=summary
case "${1:-}" in
  --to-evidence) mode=evidence; shift ;;
  --cleanup) mode=cleanup; shift ;;
esac
cap="${1:-$(cat /tmp/adt-zed-capture.last 2>/dev/null)}"
case "$cap" in /tmp/adt-zed-capture-*) ;; *) echo "no capture directory (got '$cap')"; exit 2 ;; esac
[ -d "$cap" ] || { echo "$cap does not exist"; exit 2; }

if [ "$mode" = cleanup ]; then
  pgrep -f "$cap/zed-data" >/dev/null && { echo "Zed still runs with this profile; quit it first"; exit 1; }
  rm -rf "$cap" && rm -f /tmp/adt-zed-capture.last && echo "removed $cap"
  exit 0
fi

if pgrep -f "/Applications/Zed.app/Contents/MacOS/zed" >/dev/null; then
  echo "note: a Zed process is still running; frames written after this point are not included"
fi

node "$here/redact.mjs" "$cap" "$repo" || exit 1

if [ "$mode" = evidence ]; then
  dest="$repo/docs/acp/tests/evidence/zed-initialize-$(date +%Y-%m-%d)"
  mkdir -p "$dest" && cp -R "$cap/redacted/." "$dest/" && echo "copied to ${dest#$repo/}"
fi
