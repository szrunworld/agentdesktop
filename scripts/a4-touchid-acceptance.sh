#!/bin/sh
# A4 real end-to-end acceptance with the user's own Touch ID (or password).
# Kevin 2026-10-09: required before #137 merges.
#
# Runs against a test copy (/tmp/adt-a4-acc), never the product endpoint; the
# CLI keeps its credentials in a throwaway keychain file there, never the login
# keychain. In the Agent Desktop window, with your own Touch ID or password
# (nothing here clicks or authenticates for you):
#   1. pairing "acc-cli"            -> 批准, then Touch ID
#   2. pairing "acc-victim"         -> 批准, then Touch ID
#   3. acc-victim revoking itself   -> 批准, then Touch ID
#   4. pairing "acc-deny"           -> 拒绝
#   5. pairing "acc-cancel"         -> 批准, then cancel the Touch ID prompt
#   6. pairing "acc-timeout"        -> do not answer (it ends by itself after 120 s)
# Everything else is checked by the script. Usage, from the repository:
#   scripts/bundle-app.sh && scripts/a4-touchid-acceptance.sh
# For development bundles: step 6 expects the CLI to be refused sensitive
# management (its code is not verified before S4). On a release candidate
# (Developer ID CLI) that step is expected to differ.
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
    [ -s "$DIR/search-list" ] && restore_search_list
    security delete-keychain "$KC" 2>/dev/null
    rm -rf "$DIR"
}
trap cleanup EXIT

rm -rf "$DIR"; mkdir -p "$DIR"
# Your keychain search list, kept exactly (one path per line, spaces allowed).
security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//' > "$DIR/search-list"
[ -s "$DIR/search-list" ] || { echo "cannot read your keychain search list; stopping without touching it"; exit 1; }
restore_search_list() {
    set --
    while IFS= read -r k; do set -- "$@" "$k"; done < "$DIR/search-list"
    [ $# -gt 0 ] && security list-keychains -d user -s "$@"
}
security create-keychain -p "$(uuidgen)" "$KC"
security set-keychain-settings "$KC"                  # no auto-lock during the run
restore_search_list                                   # create-keychain may have added itself
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
grep -rl "adt1_" "$DIR" --exclude=test.keychain-db* > /dev/null 2>&1 && bad "a token is in a plain file" || ok "still no token in any file"

echo "== 6. a granted operation with the paired CLI"
AGENTDESKTOP_PROFILE=victim "$B" desktop list --format json > "$DIR/list.json" && ok "desktop list as $V_ID" || bad "desktop list: $(cat "$DIR/list.json")"
"$B" agents list --format json > "$DIR/agents-list.json"
grep -q unverified_identity "$DIR/agents-list.json" && ok "sensitive management refused to unverified code (R1)" || bad "agents list: $(cat "$DIR/agents-list.json")"

echo "== 7a. the unverified CLI may not revoke another client (R1): refused without asking"
"$B" agents revoke "$V_ID" --format json > "$DIR/revoke-other.json"
grep -q unverified_identity "$DIR/revoke-other.json" && ok "revoking another client refused (unverified_identity)" || bad "revoke other: $(cat "$DIR/revoke-other.json")"
echo "== 7b. the victim gives up its own access: confirm in the window, approve with Touch ID or your password"
AGENTDESKTOP_PROFILE=victim "$B" agents revoke "$V_ID" --format json > "$DIR/revoke.json" || true   # its own connection is cut: no reply expected
AGENTDESKTOP_PROFILE=victim "$B" desktop list --format json > "$DIR/after.json"
grep -q client_revoked "$DIR/after.json" && ok "the old credential is refused (client_revoked)" || bad "after revoke: $(cat "$DIR/after.json")"

pair_expect() { # name expected-audit-reason prompt
    echo "== $3"
    AGENTDESKTOP_PROFILE="$1" "$B" agents pair --name "$1" --capabilities observe --wait-timeout 200 --format json > "$DIR/$1.json"
    grep -q '"ok":true' "$DIR/$1.json" && bad "$1 was granted" || ok "$1 not granted"
    sqlite3 -readonly "$DIR/side.runtime/hub.sqlite" "SELECT reason FROM auth_events WHERE method='hub.pairing.start' AND decision='denied' ORDER BY rowid DESC LIMIT 1" \
        | grep -q "$2" && ok "$1 audited as $2" || bad "$1 audit is not $2"
}
sleep 61   # the cooldown after a refusal is per program
pair_expect acc-deny user_denied "8. press 拒绝 in the window"
sleep 61
pair_expect acc-cancel user_cancelled "9. press 批准…, then cancel the Touch ID / password prompt"
sleep 61
pair_expect acc-timeout confirmation_timeout "10. do not answer; wait about two minutes"

echo "== audit (decisions only)"
sqlite3 -readonly "$DIR/side.runtime/hub.sqlite" "SELECT at, client_id, method, decision, reason FROM auth_events WHERE decision IN ('asked','confirmed','approved','revoked','cut','denied') ORDER BY rowid" | tail -20
echo "== host log (confirmation steps)"
grep "AgentDesktop confirmation" "$DIR/host.log" || true

echo "passed $pass, failed $fail"
[ $fail -eq 0 ]
