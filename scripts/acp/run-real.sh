#!/bin/bash
# Run the fake editor against the real ACP entry (layer L2, e2e-runbook §五).
#
#   scripts/acp/run-real.sh <profile> <out-dir> [scenario-name ...]
#     profile: agentdesktop-dev (swift build product) | agentdesktop-acp (bundled CLI)
#
# Refuses to run unless AGENTDESKTOP_ENDPOINT points at a side instance under
# /tmp/adt-*: the product endpoint is never used for tests. Profiles carry
# their own endpoint; this variable must agree with it.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
fe="$here/fake-editor"
profile="${1:-}"; out="${2:-}"
[ -n "$profile" ] && [ -n "$out" ] || { echo "usage: $0 <profile> <out-dir> [scenario ...]"; exit 2; }
shift 2

case "${AGENTDESKTOP_ENDPOINT:-}" in
  /tmp/adt-*) ;;
  *) echo "AGENTDESKTOP_ENDPOINT must be a side instance under /tmp/adt-* (got '${AGENTDESKTOP_ENDPOINT:-}')"; exit 2 ;;
esac
pf="$fe/profiles/$profile.json"
[ -f "$pf" ] || { echo "no profile $pf"; exit 2; }
grep -q "\"AGENTDESKTOP_ENDPOINT\": \"$AGENTDESKTOP_ENDPOINT\"" "$pf" \
  || { echo "profile $profile names a different endpoint than AGENTDESKTOP_ENDPOINT; edit one of them"; exit 2; }
[ -S "$AGENTDESKTOP_ENDPOINT" ] || { echo "no socket at $AGENTDESKTOP_ENDPOINT: start the side instance first (e2e-runbook §二)"; exit 2; }

if [ "$profile" = "agentdesktop-dev" ]; then
  (cd "$repo" && swift build --product agentdesktop-acp-dev) || { echo "swift build failed"; exit 2; }
fi
(cd "$fe" && npm ci --silent --no-audit --no-fund && npx tsc -p .) || { echo "fake editor build failed"; exit 2; }

args=()
if [ $# -eq 0 ]; then
  for f in "$fe"/scenarios/*.json; do args+=(--scenario "$f"); done
else
  for s in "$@"; do args+=(--scenario "$fe/scenarios/$s.json"); done
fi
node "$fe/dist/fake-editor.js" --profile "$pf" "${args[@]}" --out "$out"
