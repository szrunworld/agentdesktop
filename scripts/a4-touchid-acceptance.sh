#!/bin/sh
# A4 real end-to-end acceptance with the user's own Touch ID (or password).
# Kevin 2026-10-09: required before #137 merges.
#
# Runs against a test copy (/tmp/adt-a4-acc), never the product endpoint; the
# CLI keeps its credentials in a throwaway keychain file there, never the login
# keychain. You approve three requests in the Agent Desktop window:
#   1. pairing "acc-cli"     (the CLI that will do the revocation)
#   2. pairing "acc-victim"  (the client that will be revoked)
#   3. revoking acc-victim
# Everything else is checked by the script. Usage, from the repository:
#   scripts/bundle-app.sh && scripts/a4-touchid-acceptance.sh
set -u
APP="${APP:-build/Agent Desktop.app}"
DIR=/tmp/adt-a4-acc
EP="$DIR/side.runtime.sock"
KC="$DIR/test.keychain-db"
B="$APP/Contents/Resources/bin/agentdesktop"
pass=0; fail=0
ok()  { echo "PASS  $*"; pass=$((pass + 1)); }
bad() { echo "FAIL  $*"; fail=$((fail + 1)); }

cleanup() {
    [ -n "${HOST:-}" ] && kill "$HOST" 2>/dev/null
    security delete-keychain "$KC" 2>/dev/null
    rm -rf "$DIR"
}
trap cleanup EXIT

rm -rf "$DIR"; mkdir -p "$DIR"
SEARCH=$(security list-keychains -d user | tr -d '"' | xargs)
security create-keychain -p "$(uuidgen)" "$KC"
security list-keychains -d user -s $SEARCH            # keep your search list as it was
export AGENTDESKTOP_ENDPOINT="$EP" AGENTDESKTOP_KEYCHAIN="$KC"

echo "== 1. start Agent Desktop (test copy)"
AGENTDESKTOP_SOCKET="$DIR/side.sock" "$APP/Contents/MacOS/Agent Desktop" > "$DIR/host.log" 2>&1 &
HOST=$!
i=0; while [ ! -S "$EP" ] && [ $i -lt 60 ]; do sleep 0.5; i=$((i + 1)); done
[ -S "$EP" ] && ok "Runtime listening at $EP" || { bad "Runtime did not start"; exit 1; }

echo "== 2-4. pair the CLI: confirm in the window, approve with Touch ID or your password"
"$B" agents pair --name acc-cli --capabilities observe,desktop.manage --desktops created --wait-timeout 180 --format json > "$DIR/pair-cli.json"
CLI_ID=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["data"]["clientId"])' "$DIR/pair-cli.json" 2>/dev/null)
[ -n "$CLI_ID" ] && ok "CLI paired as $CLI_ID" || bad "CLI pairing: $(cat "$DIR/pair-cli.json")"

echo "== 5. the credential is in the keychain, in no file"
security find-generic-password -s com.agentdesktop.client-credential -a "$EP|cli" "$KC" > /dev/null 2>&1 \
    && ok "keychain item for $EP|cli exists" || bad "no keychain item"
grep -rl "adt1_" "$DIR" --exclude=test.keychain-db* > /dev/null 2>&1 && bad "a token is in a plain file" || ok "no token in any file"

echo "== now pair a second client that will be revoked (approve again)"
AGENTDESKTOP_PROFILE=victim "$B" agents pair --name acc-victim --capabilities observe,desktop.manage --desktops created --wait-timeout 180 --format json > "$DIR/pair-victim.json"
V_ID=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["data"]["clientId"])' "$DIR/pair-victim.json" 2>/dev/null)
[ -n "$V_ID" ] && ok "victim paired as $V_ID" || bad "victim pairing: $(cat "$DIR/pair-victim.json")"

echo "== 6. a granted operation with the paired CLI"
AGENTDESKTOP_PROFILE=victim "$B" desktop list --format json > "$DIR/list.json" && ok "desktop list as $V_ID" || bad "desktop list: $(cat "$DIR/list.json")"
"$B" agents list --format json > "$DIR/agents-list.json"
grep -q unverified_identity "$DIR/agents-list.json" && ok "sensitive management refused to unverified code (R1)" || bad "agents list: $(cat "$DIR/agents-list.json")"

echo "== 7. revoke the victim: confirm in the window, approve with Touch ID or your password"
"$B" agents revoke "$V_ID" --format json > "$DIR/revoke.json" && ok "revoked $V_ID" || bad "revoke: $(cat "$DIR/revoke.json")"
AGENTDESKTOP_PROFILE=victim "$B" desktop list --format json > "$DIR/after.json"
grep -q client_revoked "$DIR/after.json" && ok "the old credential is refused (client_revoked)" || bad "after revoke: $(cat "$DIR/after.json")"

echo "== audit (decisions only)"
sqlite3 -readonly "$DIR/side.runtime/hub.sqlite" "SELECT at, client_id, method, decision, reason FROM auth_events WHERE decision IN ('asked','confirmed','approved','revoked','cut','denied') ORDER BY rowid" | tail -20
echo "== host log (confirmation steps)"
grep "AgentDesktop confirmation" "$DIR/host.log" || true

echo "passed $pass, failed $fail"
[ $fail -eq 0 ]
