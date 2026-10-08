#!/bin/bash
# Self-test of the fake editor (docs/acp/tests/README.md §四).
#
#   scripts/acp/selftest.sh [out-dir]
#
# 1. echo profile, all scenarios        → every scenario PASS (exit 0)
# 2. official SDK example agent, subset → every scenario PASS (exit 0)
# 3. echo agent with one planted bug    → the matching scenario FAILs (exit 1)
#
# Step 3 proves the assertions bite. Exit 0 only if all three hold. Nothing
# here talks to AgentDesktop, a Runtime endpoint or the user's screen.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
fe="$here/fake-editor"
out="${1:-$(mktemp -d /tmp/adt-acp-selftest.XXXXXX)}"
mkdir -p "$out"

cd "$fe" || exit 2
npm ci --silent --no-audit --no-fund || { echo "npm ci failed"; exit 2; }
npx tsc -p . || { echo "tsc failed"; exit 2; }

run() { node "$fe/dist/fake-editor.js" "$@"; }
all=()
for f in "$fe"/scenarios/*.json; do all+=(--scenario "$f"); done
failed=0

echo "== 1. echo agent, all scenarios"
run --profile "$fe/profiles/echo.json" "${all[@]}" --out "$out/echo"
rc=$?; echo "exit=$rc"; [ $rc -eq 0 ] || failed=1

echo "== 2. SDK example agent"
sdk=()
# t06/t07/t08/t14/scene B need session/load or a second identity, which the
# example agent does not have: they report BLOCKED. t05 runs separately below.
for s in t01-valid-requests t01b-pipelining t02-malformed-frames t02b-oversize-frame t02c-oversize-then-continue t03-stdio-close t04-version t12-cancel t16-approval scene-d-approval-unavailable \
         t06-session-lifecycle t07-foreign-session t08-concurrent-sessions t14-scoped-disconnect scene-b-scoped-disconnect; do
  sdk+=(--scenario "$fe/scenarios/$s.json")
done
run --profile "$fe/profiles/sdk-example.json" "${sdk[@]}" --out "$out/sdk-example"
rc=$?; echo "exit=$rc"; [ $rc -eq 0 ] || failed=1

# Known finding: the example agent does not claim promptCapabilities.image
# but runs an image-only prompt anyway. T05 must report that (FAIL), which
# is also a real-agent check that the probe works.
run --profile "$fe/profiles/sdk-example.json" --scenario "$fe/scenarios/t05-capabilities.json" --out "$out/sdk-example-t05" > "$out/sdk-example-t05.txt"
rc=$?; cat "$out/sdk-example-t05.txt"
if [ $rc -eq 1 ] && grep -q 'image prompt not claimed but accepted' "$out/sdk-example-t05.txt"; then
  echo "expected finding reproduced (exit=$rc)"
else
  echo "UNEXPECTED t05 result on the example agent (exit=$rc)"; failed=1
fi

echo "== 3. planted bugs must be caught"
while read -r mutant scenario; do
  run --profile "$fe/profiles/echo.json" --env "QTEST_ECHO_MUTANT=$mutant" \
      --scenario "$fe/scenarios/$scenario.json" --out "$out/mutant-$mutant" > "$out/mutant-$mutant.txt"
  rc=$?
  if [ $rc -eq 1 ] && grep -q '^FAIL' "$out/mutant-$mutant.txt"; then
    echo "caught   $mutant by $scenario"
  else
    echo "MISSED   $mutant by $scenario (exit=$rc)"; cat "$out/mutant-$mutant.txt"; failed=1
  fi
done <<'EOF'
allow-when-unavailable scene-d-approval-unavailable
allow-always t16-approval
ignore-cancel t12-cancel
no-owner-check t07-foreign-session
cross-talk t08-concurrent-sessions
overclaim t05-capabilities
continue-after-reconnect t14-scoped-disconnect
stdout-noise t01-valid-requests
replay-user-as-agent t06b-load-ordering
EOF

echo "evidence: $out"
exit $failed
