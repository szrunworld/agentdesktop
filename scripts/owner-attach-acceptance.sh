#!/bin/sh
# Owner display attach (docs/security/owner-display-attach.md): real-machine
# acceptance with the user's own Touch ID (or password). Record in
# docs/acceptance/physical-desktop/owner-attach-acceptance.md.
#
# Runs against a test copy (/tmp/adt-oa-acc) whose main window is shown on
# your main display, never the product endpoint; the CLI keeps its
# credential in a throwaway keychain file there. It pairs ONE test CLI
# ("oa-cli"), proves that CLI cannot attach a display by itself, then waits
# for YOU to open your main display to it in the test copy's window, checks
# the CLI still sees no window, and waits for you to take it back. Nothing
# is bound, captured or typed; no virtual display is created; no other app
# is touched.
#
# In the test copy's window and the system prompts, with your own Touch ID
# or password (nothing here clicks or authenticates for you):
#   1. pairing "oa-cli"                                   -> 批准, then Touch ID
#   3. Desktops › 开放我的显示器 › main display + oa-cli › 开放…
#      check the confirmation: display name/id/resolution, 已证实为物理显示器,
#      oa-cli, "开放后它看不到任何窗口"         -> 批准…, then Touch ID
#   6. Desktops › that Desktop › 开放给的程序 › 全部收回并解除挂接
# Usage, from the repository:
#   scripts/bundle-app.sh && scripts/owner-attach-acceptance.sh
set -u
. "$(dirname "$0")/lib/process-identity.sh"
APP="${APP:-build/Agent Desktop.app}"
DIR=/tmp/adt-oa-acc
EP="$DIR/side.runtime.sock"
KC="$DIR/test.keychain-db"
B="$APP/Contents/Resources/bin/agentdesktop"
WAIT="${WAIT:-300}"
pass=0; fail=0
ok()  { echo "PASS  $*"; pass=$((pass + 1)); }
bad() { echo "FAIL  $*"; fail=$((fail + 1)); }
field() { python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    d = d[int(k)] if isinstance(d, list) else d.get(k) if isinstance(d, dict) else None
print("" if d is None else d)' "$1" "$2" 2>/dev/null; }

cleanup() {
    if [ -n "${HOST:-}" ]; then
        proc_stop "$HOST" "${HOST_ID:-}" || true
        proc_left "$HOST" "${HOST_ID:-}" "the test Agent Desktop"
    fi
    [ -s "$DIR/search-list" ] && restore_search_list
    security delete-keychain "$KC" 2>/dev/null
    [ -d "$DIR" ] && { mkdir -p "$DIR.evidence"; cp "$DIR"/*.json "$DIR.evidence/" 2>/dev/null; }
    rm -rf "$DIR"
}
trap cleanup EXIT

rm -rf "$DIR" "$DIR.evidence"; mkdir -p "$DIR"
security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//' > "$DIR/search-list"
[ -s "$DIR/search-list" ] || { echo "cannot read your keychain search list; stopping without touching it"; exit 1; }
restore_search_list() {
    set --
    while IFS= read -r k; do set -- "$@" "$k"; done < "$DIR/search-list"
    [ $# -gt 0 ] && security list-keychains -d user -s "$@"
}
security create-keychain -p "$(uuidgen)" "$KC"
security set-keychain-settings "$KC"
restore_search_list
export AGENTDESKTOP_ENDPOINT="$EP" AGENTDESKTOP_KEYCHAIN="$KC"
DISPLAYS_BEFORE=$(system_profiler SPDisplaysDataType 2>/dev/null | grep -c "Resolution:")

echo "== start Agent Desktop (test copy) with its main window on your main display"
AGENTDESKTOP_SOCKET="$DIR/side.sock" AGENTDESKTOP_MAIN_WINDOW=1 "$APP/Contents/MacOS/Agent Desktop" > "$DIR/host.log" 2>&1 &
HOST=$!
HOST_ID=$(proc_record "$HOST" "$APP/Contents/MacOS/Agent Desktop") || HOST_ID=""
[ -n "$HOST_ID" ] || { bad "cannot record the test host's identity (pid $HOST)"; exit 1; }
i=0; while [ ! -S "$EP" ] && [ $i -lt 60 ]; do sleep 0.5; i=$((i + 1)); done
[ -S "$EP" ] && ok "Runtime listening at $EP" || { bad "Runtime did not start"; exit 1; }

echo "== 1. pair the CLI: confirm in the window, approve with Touch ID or your password"
"$B" agents pair --name oa-cli --capabilities observe,act,desktop.manage --desktops created --apps com.apple.Chess \
    --wait-timeout 180 --format json > "$DIR/pair.json"
CLI_ID=$(field "$DIR/pair.json" data.clientId)
[ -n "$CLI_ID" ] && ok "CLI paired as $CLI_ID" || { bad "pairing: $(cat "$DIR/pair.json")"; exit 1; }

echo "== 2. a paired app cannot list or attach displays"
"$B" displays list --format json > "$DIR/list-paired.json"
grep -q owner_only "$DIR/list-paired.json" && ok "displays list refused (owner_only)" || bad "displays list: $(cat "$DIR/list-paired.json")"
"$B" displays attach --display 1 --client "$CLI_ID" --format json > "$DIR/attach-paired.json"
grep -q owner_only "$DIR/attach-paired.json" && ok "displays attach refused (owner_only)" || bad "displays attach: $(cat "$DIR/attach-paired.json")"
"$B" desktop create --name oa --physical --format json > "$DIR/create-paired.json"
grep -q owner_only "$DIR/create-paired.json" && ok "desktop create --physical refused (owner_only)" || bad "desktop create: $(cat "$DIR/create-paired.json")"
"$B" desktop list --format json > "$DIR/list0.json"
[ "$(field "$DIR/list0.json" data.desktops.0.desktopId)" = "" ] && ok "no Desktop yet" || bad "desktops: $(cat "$DIR/list0.json")"

echo "== 3. in the test copy's window: Desktops › 开放我的显示器 › your main display + oa-cli › 开放… › 批准… › Touch ID"
echo "      (waiting up to $WAIT s for the CLI to see a physical Desktop)"
DESK=""; i=0
while [ -z "$DESK" ] && [ $i -lt "$WAIT" ]; do
    sleep 2; i=$((i + 2))
    "$B" desktop list --format json > "$DIR/list1.json" 2>/dev/null
    DESK=$(python3 -c 'import json,sys
for d in json.load(open(sys.argv[1]))["data"]["desktops"]:
    if d.get("kind") == "physical": print(d["desktopId"]); break' "$DIR/list1.json" 2>/dev/null)
done
[ -n "$DESK" ] && ok "the CLI sees physical Desktop $DESK (opened by you)" || { bad "no physical Desktop reached the CLI within $WAIT s"; exit 1; }
"$B" desktop show "$DESK" --format json > "$DIR/desk.json"
[ "$(field "$DIR/desk.json" data.kind)" = physical ] && ok "kind physical" || bad "kind: $(cat "$DIR/desk.json")"
[ "$(field "$DIR/desk.json" data.binding)" = "" ] && ok "no binding" || bad "binding: $(field "$DIR/desk.json" data.binding)"

echo "== 4. opened, but no window: list is empty, binding any window of yours is refused"
"$B" window list --all --format json > "$DIR/windows.json"
[ "$(field "$DIR/windows.json" data.windows.0.windowId)" = "" ] && ok "window list is empty" || bad "window list: $(cat "$DIR/windows.json")"
# Any on-screen window of yours, by id only; nothing is read from it.
ANY=$(swift - 2>/dev/null <<'SWIFT'
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
if let w = list.first(where: { ($0[kCGWindowLayer as String] as? Int) == 0 }) {
    print("\(w[kCGWindowOwnerPID as String] as! Int32) \(w[kCGWindowNumber as String] as! Int)")
}
SWIFT
)
if [ -n "$ANY" ]; then
    "$B" window bind --desktop "$DESK" --pid "${ANY% *}" --window "${ANY#* }" --format json > "$DIR/bind.json"
    grep -q bind_requires_grant "$DIR/bind.json" && ok "bind refused (bind_requires_grant)" || bad "bind: $(cat "$DIR/bind.json")"
else
    echo "SKIP  no on-screen window to try binding (Screen Recording for this terminal?)"
fi
DISPLAYS_MID=$(system_profiler SPDisplaysDataType 2>/dev/null | grep -c "Resolution:")
[ "$DISPLAYS_BEFORE" = "$DISPLAYS_MID" ] && ok "display count unchanged ($DISPLAYS_MID)" || bad "displays $DISPLAYS_BEFORE -> $DISPLAYS_MID"

echo "== 5. in the window the display now shows 已挂接 (can be shared again); still one Desktop"
"$B" desktop list --format json > "$DIR/list2.json"
[ "$(field "$DIR/list2.json" data.desktops.1.desktopId)" = "" ] && ok "still one Desktop" || bad "desktops: $(cat "$DIR/list2.json")"

echo "== 6. in the window: Desktops › $DESK › 开放给的程序 › 全部收回并解除挂接 (waiting up to $WAIT s)"
i=0; GONE=""
while [ -z "$GONE" ] && [ $i -lt "$WAIT" ]; do
    sleep 2; i=$((i + 2))
    "$B" desktop show "$DESK" --format json > "$DIR/show-after.json" 2>/dev/null
    grep -q '"not_found"\|grant_missing\|client_revoked\|connection' "$DIR/show-after.json" && GONE=1
done
[ -n "$GONE" ] && ok "the Desktop is out of the CLI's reach" || bad "the CLI still sees $DESK after $WAIT s"

echo "== 7. nothing created, audit names no window content"
DISPLAYS_AFTER=$(system_profiler SPDisplaysDataType 2>/dev/null | grep -c "Resolution:")
[ "$DISPLAYS_BEFORE" = "$DISPLAYS_AFTER" ] && ok "display count unchanged ($DISPLAYS_AFTER)" || bad "displays $DISPLAYS_BEFORE -> $DISPLAYS_AFTER"
sqlite3 -readonly "$DIR/side.runtime/hub.sqlite" "SELECT at, client_id, method, decision, reason FROM auth_events WHERE method LIKE 'hub.displays%' OR decision IN ('asked','confirmed','granted','revoked','ended','cut') ORDER BY rowid" > "$DIR/audit.txt"
tail -20 "$DIR/audit.txt"
grep -q "hub.displays.attach|granted\|hub.displays.attach.*granted" "$DIR/audit.txt" && ok "audit: attach granted" || bad "audit lacks attach granted"
grep -q "hub.displays.detach" "$DIR/audit.txt" && ok "audit: detach recorded" || bad "audit lacks detach"
cp "$DIR/audit.txt" "$DIR/audit.json" 2>/dev/null
echo "passed $pass, failed $fail"
[ $fail -eq 0 ]
