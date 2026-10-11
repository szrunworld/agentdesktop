#!/bin/sh
# Self-test for process-identity.sh, without Agent Desktop or Touch ID:
#   scripts/lib/process-identity-selftest.sh
# Simulates a reused pid (the recorded identity no longer matches the process
# now at that pid) and checks that it is never signalled.
set -u
. "$(dirname "$0")/process-identity.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/proc-id-selftest.XXXXXX")
pass=0; fail=0
ok()  { echo "PASS  $*"; pass=$((pass + 1)); }
bad() { echo "FAIL  $*"; fail=$((fail + 1)); }
A=""; B=""; C=""
trap 'kill $A $B $C 2>/dev/null; rm -rf "$T"' EXIT

mkdir -p "$T/Test Host.app/Contents/MacOS"
printf '#include <unistd.h>\nint main(void){sleep(60);return 0;}\n' > "$T/s.c"
cc -o "$T/Test Host.app/Contents/MacOS/Test Host" "$T/s.c" || { echo "needs a C compiler (xcode-select --install)"; exit 2; }
EXE="$T/Test Host.app/Contents/MacOS/Test Host"

# 1. Recording waits until the pid runs the executable (the shell execs late).
sh -c 'sleep 1; exec "$0" 60' "$EXE" &
A=$!
A_ID=$(proc_record "$A" "$EXE") && case "$A_ID" in *" $EXE") ok "identity recorded after exec: $A_ID" ;; *) bad "recorded [$A_ID]" ;; esac \
    || bad "no identity recorded for pid $A"

# 2. A process that is not the recorded one keeps running: the recorded
#    identity (A) is applied to another pid (B), as if A's pid were reused.
"$EXE" &
B=$!
B_ID=$(proc_record "$B" "$EXE") || bad "no identity for B"
proc_same "$B" "$A_ID" && bad "B matched A's identity" || ok "another process does not match the recorded identity"
proc_stop "$B" "$A_ID" && ok "proc_stop reports the recorded process as gone" || bad "proc_stop failed"
kill -0 "$B" 2>/dev/null && ok "pid $B (not the recorded process) was not signalled" || bad "pid $B was killed"
msg=$(proc_left "$B" "$A_ID" "the test host")
case "$msg" in *"now belongs to another process"*"left alone"*) ok "explained: $msg" ;; *) bad "proc_left said [$msg]" ;; esac

# 3. Same pid, another executable: an identity with a different path does not match.
proc_same "$B" "$(echo "$B_ID" | sed 's|Test Host$|Other|')" && bad "a different executable matched" || ok "a different executable does not match"

# 4. The recorded process itself is stopped and waited for.
proc_stop "$A" "$A_ID" && ok "the recorded process was stopped" || bad "the recorded process survived"
kill -0 "$A" 2>/dev/null && bad "pid $A still exists" || ok "pid $A is gone"
[ -z "$(proc_left "$A" "$A_ID" "the test host")" ] && ok "nothing to explain for a stopped process" || bad "unexpected explanation"

# 5. Never identified: not signalled, and the script is told to quit it by hand.
"$EXE" &
C=$!
proc_stop "$C" "" && kill -0 "$C" 2>/dev/null && ok "an unidentified pid is not signalled" || bad "an unidentified pid was signalled"
case "$(proc_left "$C" "" "the test host")" in *"identity was not recorded"*) ok "unidentified process reported" ;; *) bad "no report for the unidentified process" ;; esac

# 6. A gone pid records nothing.
kill "$C"; wait "$C" 2>/dev/null
proc_record "$C" "$EXE" > /dev/null && bad "recorded a gone pid" || ok "a gone pid records nothing"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
