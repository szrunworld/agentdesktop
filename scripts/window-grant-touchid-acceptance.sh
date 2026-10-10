#!/bin/sh
# Window grants: real end-to-end acceptance with the user's own Touch ID (or
# password). docs/security/window-grants.md; Kevin's ruling B of 2026-10-09.
#
# Runs against a test copy (/tmp/adt-wg-acc), never the product endpoint; the
# CLI keeps its credential in a throwaway keychain file there, never the login
# keychain. The script opens ONE TextEdit window of its own (a new instance,
# in the background, on a file in /tmp/adt-wg-acc) and quits only that
# instance at the end; it never touches any other window.
#
# Finding the probe window by its title needs Screen Recording for the
# terminal you run this from; without it the script stops at that step.
#
# It needs one Desktop to grant a window on. Physical Desktops stay off in the
# product (#145), so the only Desktop is a virtual one, which creates a
# virtual display. Because of the WindowServer history, the script does that
# only when you set ALLOW_VIRTUAL_DISPLAY=1 yourself.
#
# In the Agent Desktop window, with your own Touch ID or password (nothing here
# clicks or authenticates for you):
#   1. pairing "wg-cli"                         -> 批准, then Touch ID
#   2. window grant for "wg-probe-A.txt"         -> check the window shown (title wg-probe-A.txt,
#                                                   TextEdit, "只授权这一个窗口", 查看 only, no 保存),
#                                                   then 批准 and Touch ID
#   3. a second window grant                     -> 拒绝
#   4. wg-cli giving up its window grant         -> 批准, then Touch ID
# Usage, from the repository:
#   scripts/bundle-app.sh && ALLOW_VIRTUAL_DISPLAY=1 scripts/window-grant-touchid-acceptance.sh
set -u
[ "${ALLOW_VIRTUAL_DISPLAY:-}" = 1 ] || {
    echo "This acceptance creates one virtual display (a virtual Desktop) for the window grant."
    echo "Set ALLOW_VIRTUAL_DISPLAY=1 to run it; nothing was started."
    exit 2
}
APP="${APP:-build/Agent Desktop.app}"
DIR=/tmp/adt-wg-acc
EP="$DIR/side.runtime.sock"
KC="$DIR/test.keychain-db"
B="$APP/Contents/Resources/bin/agentdesktop"
pass=0; fail=0
ok()  { echo "PASS  $*"; pass=$((pass + 1)); }
bad() { echo "FAIL  $*"; fail=$((fail + 1)); }
field() { python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    d = d[int(k)] if isinstance(d, list) else d.get(k) if isinstance(d, dict) else None
print("" if d is None else d)' "$1" "$2" 2>/dev/null; }

cleanup() {
    [ -n "${DESK:-}" ] && "$B" desktop destroy "$DESK" --format json > /dev/null 2>&1
    # Only the very process this script started: same pid and same start
    # time as recorded at launch (Codex on 8e9eb9d: the pid may be reused).
    if [ -n "${PROBE:-}" ] && [ -n "${PROBE_START:-}" ] && [ "$(ps -o lstart= -p "$PROBE" 2>/dev/null)" = "$PROBE_START" ]; then
        kill "$PROBE" 2>/dev/null
    fi
    # The test host too, only while its pid still has the recorded start time.
    if [ -n "${HOST:-}" ] && [ -n "${HOST_START:-}" ] && [ "$(ps -o lstart= -p "$HOST" 2>/dev/null)" = "$HOST_START" ]; then
        kill "$HOST" 2>/dev/null
    fi
    [ -s "$DIR/search-list" ] && restore_search_list
    security delete-keychain "$KC" 2>/dev/null
    rm -rf "$DIR"
}
trap cleanup EXIT

rm -rf "$DIR"; mkdir -p "$DIR"
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

echo "== start Agent Desktop (test copy)"
AGENTDESKTOP_SOCKET="$DIR/side.sock" "$APP/Contents/MacOS/Agent Desktop" > "$DIR/host.log" 2>&1 &
HOST=$!
HOST_START=$(ps -o lstart= -p "$HOST" 2>/dev/null)
i=0; while [ ! -S "$EP" ] && [ $i -lt 60 ]; do sleep 0.5; i=$((i + 1)); done
[ -S "$EP" ] && ok "Runtime listening at $EP" || { bad "Runtime did not start"; exit 1; }

echo "== 1. pair the CLI: confirm in the window, approve with Touch ID or your password"
"$B" agents pair --name wg-cli --capabilities observe,act,desktop.manage --desktops created --apps com.apple.TextEdit \
    --wait-timeout 180 --format json > "$DIR/pair.json"
CLI_ID=$(field "$DIR/pair.json" data.clientId)
[ -n "$CLI_ID" ] && ok "CLI paired as $CLI_ID" || { bad "pairing: $(cat "$DIR/pair.json")"; exit 1; }

echo "== the probe window: one TextEdit instance of this script's own"
echo "window grant acceptance probe" > "$DIR/wg-probe-A.txt"
# Only a TextEdit process that did not exist before this launch is ours: the
# script inspects and quits that one and no other (Codex on 7629d6b).
pgrep -x TextEdit | sort > "$DIR/textedit-before"
open -n -g -a TextEdit "$DIR/wg-probe-A.txt" || { bad "open TextEdit failed"; exit 1; }
i=0; PROBE=""
while [ -z "$PROBE" ] && [ $i -lt 40 ]; do
    sleep 0.5; i=$((i + 1))
    pgrep -x TextEdit | sort > "$DIR/textedit-after"
    NEW=$(comm -13 "$DIR/textedit-before" "$DIR/textedit-after")
    [ "$(printf '%s\n' "$NEW" | grep -c .)" -gt 1 ] && { bad "more than one new TextEdit started; stopping without touching any"; exit 1; }
    PROBE="$NEW"
done
[ -n "$PROBE" ] && ok "probe TextEdit pid $PROBE (new, started by this script)" || { bad "no new TextEdit"; exit 1; }
PROBE_START=$(ps -o lstart= -p "$PROBE" 2>/dev/null)
[ -n "$PROBE_START" ] || { bad "cannot read the probe's start time"; PROBE=""; exit 1; }
WIN=$(swift - "$PROBE" 2>/dev/null <<'SWIFT'
import CoreGraphics
let pid = Int32(CommandLine.arguments[1])!
for _ in 0..<40 {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    if let w = list.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
                              && (($0[kCGWindowName as String] as? String) ?? "").contains("wg-probe-A") }) {
        print(w[kCGWindowNumber as String] as! Int); exit(0)
    }
    usleep(250_000)
}
exit(1)
SWIFT
)
[ -n "$WIN" ] && ok "probe window $WIN" || { bad "probe window not found"; exit 1; }

echo "== a Desktop for the grant (virtual: physical Desktops stay off)"
"$B" desktop create --format json > "$DIR/desk.json"
DESK=$(field "$DIR/desk.json" data.desktopId)
[ -n "$DESK" ] && ok "Desktop $DESK" || { bad "desktop create: $(cat "$DIR/desk.json")"; exit 1; }

echo "== before any grant: the app sees none of TextEdit's windows"
"$B" window list --all --format json > "$DIR/list0.json"
[ "$(field "$DIR/list0.json" data.windows.0.windowId)" = "" ] && ok "window list is empty" || bad "window list: $(cat "$DIR/list0.json")"

echo "== 2. ask for the probe window (查看 only): check what the window shows, then 批准 and Touch ID"
"$B" windows request --desktop "$DESK" --app com.apple.TextEdit --window "$WIN" --allow observe --duration 10m \
    --format json > "$DIR/grant.json"
WG=$(field "$DIR/grant.json" data.windowGrantId)
[ -n "$WG" ] && ok "window grant $WG" || bad "window grant: $(cat "$DIR/grant.json")"
[ "$(field "$DIR/grant.json" data.window.windowId)" = "$WIN" ] && ok "it is the probe window" || bad "granted another window"
"$B" window list --all --format json > "$DIR/list1.json"
python3 -c 'import json,sys
ws=json.load(open(sys.argv[1]))["data"]["windows"]
sys.exit(0 if [w["windowId"] for w in ws]==[int(sys.argv[2])] else 1)' "$DIR/list1.json" "$WIN" \
    && ok "window list shows exactly the granted window" || bad "window list: $(cat "$DIR/list1.json")"

echo "== the seals stay: binding the user's window onto the virtual Desktop is still refused"
"$B" window bind --desktop "$DESK" --pid "$PROBE" --window "$WIN" --format json > "$DIR/bind.json"
grep -q bind_requires_grant "$DIR/bind.json" && ok "bind refused (bind_requires_grant)" || bad "bind: $(cat "$DIR/bind.json")"

echo "== 3. ask again: press 拒绝 in the window"
"$B" windows request --desktop "$DESK" --app com.apple.TextEdit --window "$WIN" --allow observe,act --format json > "$DIR/deny.json"
grep -q user_denied "$DIR/deny.json" && ok "refused (user_denied)" || bad "deny: $(cat "$DIR/deny.json")"
"$B" windows request --desktop "$DESK" --app com.apple.TextEdit --window "$WIN" --allow observe --format json > "$DIR/cool.json"
grep -q window_grant_cooldown "$DIR/cool.json" && ok "asking again at once is refused without a prompt" || bad "cooldown: $(cat "$DIR/cool.json")"

echo "== 4. the CLI gives up its window grant: confirm in the window, approve with Touch ID or your password"
"$B" windows revoke "$WG" --format json > "$DIR/revoke.json" || true   # its connection is cut: the reply may not arrive
"$B" windows list --all --format json > "$DIR/after.json"
python3 -c 'import json,sys
gs=json.load(open(sys.argv[1]))["data"]["windowGrants"]
sys.exit(0 if any(g["windowGrantId"]==sys.argv[2] and g["state"]=="revoked" for g in gs) else 1)' "$DIR/after.json" "$WG" \
    && ok "the window grant is revoked" || bad "after revoke: $(cat "$DIR/after.json")"
"$B" window list --all --format json > "$DIR/list2.json"
[ "$(field "$DIR/list2.json" data.windows.0.windowId)" = "" ] && ok "the window is gone from its list" || bad "window list: $(cat "$DIR/list2.json")"

echo "== audit (decisions only; no window titles)"
sqlite3 -readonly "$DIR/side.runtime/hub.sqlite" "SELECT at, client_id, method, decision, reason FROM auth_events WHERE decision IN ('asked','confirmed','granted','revoked','ended','cut','denied') ORDER BY rowid" | tail -25
sqlite3 -readonly "$DIR/side.runtime/hub.sqlite" "SELECT count(*) FROM auth_events WHERE reason LIKE '%wg-probe%'" | grep -qx 0 \
    && ok "no window title in the audit" || bad "a window title is in the audit"
grep "AgentDesktop confirmation" "$DIR/host.log" || true
echo "passed $pass, failed $fail"
[ $fail -eq 0 ] && [ $pass -eq 15 ]
