#!/bin/sh
# Runs every experiment (all model traffic goes to the local scripted mock; no real model
# calls, no network egress beyond 127.0.0.1). ~15 min. Evidence: runs/<id>/, summary: runs/SUMMARY.md
cd "$(dirname "$0")"
rm -rf runs
run() { env "$@" >/dev/null 2>&1; }
for a in ${AGENTS:-claude codex gemini}; do
  for l in a b c; do
    run npx tsx src/harness.ts $a $l
    run ADT_POLICY=allow-all npx tsx src/harness.ts $a $l
  done
  run ADT_EGRESS_PROBE=1 npx tsx src/harness.ts $a b
  run ADT_CANCEL=1 npx tsx src/harness.ts $a b
done
run ADT_POLICY=allow-all ADT_TOOLS_OFF=1 npx tsx src/harness.ts claude b
run ADT_POLICY=allow-all ADT_TOOLS_OFF=1 npx tsx src/harness.ts gemini b
npx tsx src/net-allowlist-demo.ts >/dev/null
npx tsx src/summarize.ts
