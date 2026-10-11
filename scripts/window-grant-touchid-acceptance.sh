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
# Cleanup: the script records the online displays and your keychain search
# list first; at the end it destroys the Desktop, quits its own TextEdit and
# test host, restores the search list and deletes the test keychain, then
# checks each of these against the record. Any mismatch prints
# "CLEANUP FAILED (清理失败)" and exits 3, whatever the steps said; only
# "RESULT: PASS" means both the acceptance steps and the cleanup passed.
# Usage, from the repository:
#   scripts/bundle-app.sh && ALLOW_VIRTUAL_DISPLAY=1 scripts/window-grant-touchid-acceptance.sh
set -u
. "$(dirname "$0")/lib/process-identity.sh"
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
CONFIRM="$(dirname "$0")/window-grant-confirmation.py"
pass=0; fail=0
ok()  { echo "PASS  $*"; pass=$((pass + 1)); }
bad() { echo "FAIL  $*"; fail=$((fail + 1)); }
field() { python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    d = d[int(k)] if isinstance(d, list) else d.get(k) if isinstance(d, dict) else None
print("" if d is None else d)' "$1" "$2" 2>/dev/null; }

# What the machine looked like before the run. Cleanup is checked against it
# item by item (Kevin's ruling on #205, 1.4/1.5): a cleanup that cannot be
# shown to have worked fails the run, whatever the acceptance steps said.
displays() { swift - 2>/dev/null <<'SWIFT'
import CoreGraphics
var n: UInt32 = 0
CGGetOnlineDisplayList(0, nil, &n)
var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
CGGetOnlineDisplayList(n, &ids, &n)
print(ids.prefix(Int(n)).sorted().map(String.init).joined(separator: " "))
SWIFT
}
search_list() { security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//'; }
DISPLAYS_BEFORE=$(displays)
[ -n "$DISPLAYS_BEFORE" ] || { echo "cannot list the displays; stopping before anything was started"; exit 1; }
SEARCH_BEFORE=$(search_list)
[ -n "$SEARCH_BEFORE" ] || { echo "cannot read your keychain search list; stopping before anything was started"; exit 1; }
restore_search_list() {
    set --
    while IFS= read -r k; do set -- "$@" "$k"; done <<EOF
$SEARCH_BEFORE
EOF
    [ $# -gt 0 ] && security list-keychains -d user -s "$@"
}

cleanup() {
    rc=$?
    trap - EXIT
    cfail=0
    cbad() { echo "CLEANUP FAILED (清理失败): $*"; cfail=$((cfail + 1)); }
    echo "== cleanup"
    if [ -n "${DESK:-}" ]; then
        "$B" desktop destroy "$DESK" --format json > "$DIR/destroy.json" 2>&1 \
            || cbad "desktop destroy $DESK: $(cat "$DIR/destroy.json" 2>/dev/null)"
    fi
    proc_stop "${PROBE:-}" "${PROBE_ID:-}" || cbad "the probe TextEdit (pid $PROBE) is still running"
    proc_stop "${HOST:-}" "${HOST_ID:-}" || cbad "the test Agent Desktop (pid $HOST) is still running"
    # Launched but never identified (Codex on 037a804): nothing is stopped
    # without its recorded identity, so a survivor is a cleanup failure.
    if [ -n "${HOST:-}" ] && [ -z "${HOST_ID:-}" ] && kill -0 "$HOST" 2>/dev/null; then
        cbad "the test Agent Desktop was started (pid $HOST) but its identity was not recorded, so it was not stopped; quit it by hand"
    fi
    if [ -n "${PROBE_OPENED:-}" ] && [ -f "$DIR/textedit-before" ]; then
        left=$(pgrep -x TextEdit | sort | comm -13 "$DIR/textedit-before" - | tr '\n' ' ' | sed 's/ *$//')
        [ -z "$left" ] || cbad "TextEdit pid(s) $left started during the run and are still running; the script could not tell they were its own, so it left them; check by hand"
    fi
    restore_search_list || cbad "restoring the keychain search list failed"
    if [ -e "$KC" ]; then
        security delete-keychain "$KC" > "$DIR/kc.err" 2>&1 || cbad "deleting the test keychain: $(cat "$DIR/kc.err")"
    fi
    # The virtual display goes with its Desktop, at the latest with the host.
    i=0; while [ "$(displays)" != "$DISPLAYS_BEFORE" ] && [ $i -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
    now=$(displays)
    [ "$now" = "$DISPLAYS_BEFORE" ] || cbad "online displays are [$now], before the run [$DISPLAYS_BEFORE]"
    [ "$(search_list)" = "$SEARCH_BEFORE" ] || cbad "the keychain search list differs from before the run"
    rm -rf "$DIR"
    [ ! -e "$DIR" ] || cbad "$DIR could not be removed"
    if [ $cfail -gt 0 ]; then
        echo "RESULT: FAIL - cleanup failed ($cfail item(s) above); this run is not an acceptance pass"
        exit 3
    fi
    echo "cleanup verified: displays, the probe TextEdit, the test host and the keychain search list are as before; the test keychain and $DIR are gone"
    if [ $rc -eq 0 ]; then
        echo "RESULT: PASS - acceptance steps and cleanup both passed"
    else
        echo "RESULT: FAIL - acceptance steps did not pass (exit $rc)"
    fi
    exit $rc
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

rm -rf "$DIR"; mkdir -p "$DIR"
security create-keychain -p "$(uuidgen)" "$KC"
security set-keychain-settings "$KC"
restore_search_list
export AGENTDESKTOP_ENDPOINT="$EP" AGENTDESKTOP_KEYCHAIN="$KC"

echo "== start Agent Desktop (test copy)"
AGENTDESKTOP_SOCKET="$DIR/side.sock" "$APP/Contents/MacOS/Agent Desktop" > "$DIR/host.log" 2>&1 &
HOST=$!
HOST_ID=$(proc_record "$HOST" "$APP/Contents/MacOS/Agent Desktop") || HOST_ID=""
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
PROBE_OPENED=1
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
PROBE_ID=$(proc_identity "$PROBE")
[ -n "$PROBE_ID" ] || { bad "cannot record the probe's identity"; PROBE=""; exit 1; }
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
python3 "$CONFIRM" "$B" windows request --desktop "$DESK" --app com.apple.TextEdit --window "$WIN" --allow observe --duration 10m \
    > "$DIR/grant.json" || { bad "window grant did not complete: $(cat "$DIR/grant.json")"; exit 1; }
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
python3 "$CONFIRM" "$B" windows request --desktop "$DESK" --app com.apple.TextEdit --window "$WIN" --allow observe,act > "$DIR/deny.json"
grep -q user_denied "$DIR/deny.json" && ok "refused (user_denied)" || bad "deny: $(cat "$DIR/deny.json")"
grep -q user_denied "$DIR/deny.json" || exit 1
"$B" windows request --desktop "$DESK" --app com.apple.TextEdit --window "$WIN" --allow observe --format json > "$DIR/cool.json"
grep -q window_grant_cooldown "$DIR/cool.json" && ok "asking again at once is refused without a prompt" || bad "cooldown: $(cat "$DIR/cool.json")"

echo "== 4. the CLI gives up its window grant: confirm in the window, approve with Touch ID or your password"
python3 "$CONFIRM" "$B" windows revoke "$WG" > "$DIR/revoke.json" \
    || { bad "revoke did not complete: $(cat "$DIR/revoke.json")"; exit 1; }
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
echo "acceptance steps: passed $pass, failed $fail (the result comes after the cleanup check)"
[ $fail -eq 0 ] && [ $pass -eq 15 ]
