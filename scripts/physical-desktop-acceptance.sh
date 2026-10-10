#!/bin/sh
# Physical Window Desktop on window grants (#143 on #205): real-machine
# security acceptance with the user's own Touch ID (or password).
# docs/architecture/physical-window-desktop.md §7; record in
# docs/acceptance/physical-desktop/window-grants-acceptance.md.
#
# Runs against a test copy (/tmp/adt-pd-acc), never the product endpoint; the
# CLI keeps its credential in a throwaway keychain file there, never the login
# keychain. It opens ONE Chess window of its own (a new instance, in the
# background) and quits only that instance at the end; it reads that window
# and sends it one Escape key, nothing else. No other app is touched.
#
# Attaching a display is reserved to the owner (A4: a paired app gets
# permission_denied / owner_only); since Kevin's ruling of 2026-10-10 the
# owner does it in the Agent Desktop window (docs/security/owner-display-attach.md).
# So, at step 2:
#   - without PD_DESKTOP the script first checks the paired CLI cannot attach
#     a display itself, then WAITS for you to open your main display to
#     "pd-cli" in the test copy's window (Desktops › 开放我的显示器 › 批准… ›
#     Touch ID), up to WAIT seconds (default 300);
#   - with PD_DESKTOP=d_... (a physical Desktop you already opened to pd-cli
#     in the test copy) steps 3-8 run against it straight away.
# It creates no virtual display. The test copy shows its main window on
# your main display so you can do the owner's steps there.
#
# Finding the probe window needs Screen Recording for the terminal you run
# this from.
#
# In the Agent Desktop window, with your own Touch ID or password (nothing here
# clicks or authenticates for you):
#   1. pairing "pd-cli"                          -> 批准, then Touch ID
#   2. Desktops › 开放我的显示器 › main display + pd-cli › 开放…
#                                                 -> check the display and pd-cli, 批准…, then Touch ID
#   3. window grant for the Chess window          -> check: Chess, "这是你自己屏幕上的真实窗口",
#                                                    查看 + 操作, no 保存; then 批准 and Touch ID
#   6. a second window grant                      -> 拒绝
#   7. pd-cli giving up its window grant          -> 批准, then Touch ID
# Usage, from the repository:
#   scripts/bundle-app.sh && scripts/physical-desktop-acceptance.sh                 (step 2 waits for you in the window)
#   PD_DESKTOP=d_... scripts/physical-desktop-acceptance.sh                         (a Desktop you already opened to pd-cli)
set -u
APP="${APP:-build/Agent Desktop.app}"
DIR=/tmp/adt-pd-acc
EP="$DIR/side.runtime.sock"
KC="$DIR/test.keychain-db"
B="$APP/Contents/Resources/bin/agentdesktop"
CONFIRM="$(dirname "$0")/window-grant-confirmation.py"
CHESS=com.apple.Chess
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
    [ -n "${DESK:-}" ] && [ -z "${OWNED:-}" ] && "$B" desktop destroy "$DESK" --format json > /dev/null 2>&1
    # Only the processes this script started, while their pid still has the
    # start time recorded at launch (a pid may be reused).
    if [ -n "${PROBE:-}" ] && [ -n "${PROBE_START:-}" ] && [ "$(ps -o lstart= -p "$PROBE" 2>/dev/null)" = "$PROBE_START" ]; then
        kill "$PROBE" 2>/dev/null
    fi
    if [ -n "${HOST:-}" ] && [ -n "${HOST_START:-}" ] && [ "$(ps -o lstart= -p "$HOST" 2>/dev/null)" = "$HOST_START" ]; then
        kill "$HOST" 2>/dev/null
    fi
    [ -s "$DIR/search-list" ] && restore_search_list
    security delete-keychain "$KC" 2>/dev/null
    # The run's evidence is kept outside the test copy.
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

echo "== start Agent Desktop (test copy)"
AGENTDESKTOP_SOCKET="$DIR/side.sock" AGENTDESKTOP_MAIN_WINDOW=1 "$APP/Contents/MacOS/Agent Desktop" > "$DIR/host.log" 2>&1 &
HOST=$!
HOST_START=$(ps -o lstart= -p "$HOST" 2>/dev/null)
i=0; while [ ! -S "$EP" ] && [ $i -lt 60 ]; do sleep 0.5; i=$((i + 1)); done
[ -S "$EP" ] && ok "Runtime listening at $EP" || { bad "Runtime did not start"; exit 1; }

echo "== 1. pair the CLI: confirm in the window, approve with Touch ID or your password"
"$B" agents pair --name pd-cli --capabilities observe,act,desktop.manage --desktops "${PD_DESKTOP:-created}" --apps "$CHESS" \
    --wait-timeout 180 --format json > "$DIR/pair.json"
CLI_ID=$(field "$DIR/pair.json" data.clientId)
[ -n "$CLI_ID" ] && ok "CLI paired as $CLI_ID" || { bad "pairing: $(cat "$DIR/pair.json")"; exit 1; }

echo "== 2. the physical Desktop"
if [ -z "${PD_DESKTOP:-}" ]; then
    # A paired app may not attach a display (A4, owner only): nothing is attached.
    "$B" desktop create --name pd-acc --physical --format json > "$DIR/create-paired.json"
    if grep -q owner_only "$DIR/create-paired.json"; then
        ok "a paired app cannot attach a display (owner_only)"
    else
        bad "a paired app attached a display or got another answer: $(cat "$DIR/create-paired.json")"; exit 1
    fi
    echo "      in the test copy's window: Desktops › 开放我的显示器 › your main display + pd-cli › 开放… › 批准… › Touch ID"
    echo "      (waiting up to $WAIT s for pd-cli to see a physical Desktop)"
    i=0
    while [ -z "${PD_DESKTOP:-}" ] && [ $i -lt "$WAIT" ]; do
        sleep 2; i=$((i + 2))
        "$B" desktop list --format json > "$DIR/list-wait.json" 2>/dev/null
        PD_DESKTOP=$(python3 -c 'import json,sys
for d in json.load(open(sys.argv[1]))["data"]["desktops"]:
    if d.get("kind") == "physical": print(d["desktopId"]); break' "$DIR/list-wait.json" 2>/dev/null)
    done
    [ -n "${PD_DESKTOP:-}" ] || { bad "no physical Desktop reached pd-cli within $WAIT s"; exit 1; }
fi
"$B" desktop show "$PD_DESKTOP" --format json > "$DIR/desk.json"
DESK=$(field "$DIR/desk.json" data.desktopId)
[ -n "$DESK" ] || { bad "PD_DESKTOP $PD_DESKTOP: $(cat "$DIR/desk.json")"; exit 1; }
ok "physical Desktop $DESK (opened by you)"
OWNED=1   # yours: this script never destroys it
[ "$(field "$DIR/desk.json" data.kind)" = physical ] && ok "kind physical" || bad "kind: $(cat "$DIR/desk.json")"

echo "== the probe window: one Chess instance of this script's own"
pgrep -x Chess | sort > "$DIR/chess-before"
open -n -g -b "$CHESS" || { bad "open Chess failed"; exit 1; }
i=0; PROBE=""
while [ -z "$PROBE" ] && [ $i -lt 40 ]; do
    sleep 0.5; i=$((i + 1))
    pgrep -x Chess | sort > "$DIR/chess-after"
    NEW=$(comm -13 "$DIR/chess-before" "$DIR/chess-after")
    [ "$(printf '%s\n' "$NEW" | grep -c .)" -gt 1 ] && { bad "more than one new Chess started; stopping without touching any"; exit 1; }
    PROBE="$NEW"
done
[ -n "$PROBE" ] && ok "probe Chess pid $PROBE (new, started by this script)" || { bad "no new Chess"; exit 1; }
PROBE_START=$(ps -o lstart= -p "$PROBE" 2>/dev/null)
[ -n "$PROBE_START" ] || { bad "cannot read the probe's start time"; PROBE=""; exit 1; }
WIN=$(swift - "$PROBE" 2>/dev/null <<'SWIFT'
import CoreGraphics
let pid = Int32(CommandLine.arguments[1])!
for _ in 0..<40 {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    if let w = list.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }) {
        print(w[kCGWindowNumber as String] as! Int); exit(0)
    }
    usleep(250_000)
}
exit(1)
SWIFT
)
[ -n "$WIN" ] && ok "probe window $WIN" || { bad "probe window not found"; exit 1; }

echo "== before any grant: nothing of Chess is visible or bindable"
"$B" window list --all --format json > "$DIR/list0.json"
[ "$(field "$DIR/list0.json" data.windows.0.windowId)" = "" ] && ok "window list is empty" || bad "window list: $(cat "$DIR/list0.json")"
"$B" window bind --desktop "$DESK" --pid "$PROBE" --window "$WIN" --format json > "$DIR/bind0.json"
grep -q bind_requires_grant "$DIR/bind0.json" && ok "bind refused (bind_requires_grant)" || bad "bind: $(cat "$DIR/bind0.json")"

echo "== 3. ask for the Chess window (查看 + 操作, no 保存): check the window shown, then 批准 and Touch ID"
python3 "$CONFIRM" "$B" windows request --desktop "$DESK" --app "$CHESS" --window "$WIN" --allow observe,act --duration 10m > "$DIR/grant.json"
WG=$(field "$DIR/grant.json" data.windowGrantId)
[ -n "$WG" ] && ok "window grant $WG" || { bad "window grant: $(cat "$DIR/grant.json")"; exit 1; }
[ "$(field "$DIR/grant.json" data.window.windowId)" = "$WIN" ] && ok "it is the probe window" || bad "granted another window"

echo "== 4. bind in place, observe: the window alone, transient, no screen image"
"$B" window bind --desktop "$DESK" --pid "$PROBE" --window "$WIN" --format json > "$DIR/bind.json"
[ "$(field "$DIR/bind.json" data.binding.windowId)" = "$WIN" ] && ok "bound in place" || bad "bind: $(cat "$DIR/bind.json")"
SID=$(field "$("$B" session open --desktop "$DESK" --format json > "$DIR/session.json"; echo "$DIR/session.json")" data.sessionId)
"$B" observe --session "$SID" --format json > "$DIR/observe.json"
[ "$(field "$DIR/observe.json" data.target.windowId)" = "$WIN" ] && ok "observed the granted window" || bad "observe: $(cat "$DIR/observe.json")"
[ "$(field "$DIR/observe.json" data.image.transient)" = True ] && ok "image is transient (no persist)" || bad "image: $(field "$DIR/observe.json" data.image)"
# The image itself must be the window: its size is the window frame at the
# display's scale and its origin is the window's (a whole-display capture
# would have the display's size and origin), and no leftover screen crop.
python3 -c 'import json,sys
o=json.load(open(sys.argv[1]))["data"]; d=json.load(open(sys.argv[2]))["data"]
img, f = o["image"], o["target"]["windowFrame"]; scale = 2 if d["screen"]["hiDPI"] else 1
same = (img["width"], img["height"]) == (int(f["width"]*scale), int(f["height"]*scale)) \
   and (img["transform"]["originX"], img["transform"]["originY"]) == (f["x"], f["y"])
small = img["width"] < d["screen"]["width"]*scale or img["height"] < d["screen"]["height"]*scale
sys.exit(0 if same and small else 1)' "$DIR/observe.json" "$DIR/desk.json" \
    && ! find "$DIR" -name '*.screen.png' | grep -q . \
    && ok "the image is the window alone (size = window frame x scale, origin = window origin), not the display" \
    || bad "image is not the window alone: $(field "$DIR/observe.json" data.image) frame $(field "$DIR/observe.json" data.target.windowFrame)"

echo "== 5. one Escape key to the granted window"
SNAP=$(field "$DIR/observe.json" data.snapshotId)
"$B" act key --key escape --session "$SID" --snapshot "$SNAP" --format json > "$DIR/act.json"
[ "$(field "$DIR/act.json" data.delivery)" = dispatched ] && ok "Escape dispatched to the window" || bad "act: $(cat "$DIR/act.json")"

echo "== 6. ask again: press 拒绝 in the window"
python3 "$CONFIRM" "$B" windows request --desktop "$DESK" --app "$CHESS" --window "$WIN" --allow observe,act,persist > "$DIR/deny.json"
grep -q user_denied "$DIR/deny.json" && ok "refused (user_denied)" || bad "deny: $(cat "$DIR/deny.json")"

echo "== 7. the CLI gives up its window grant: confirm in the window, approve with Touch ID or your password"
python3 "$CONFIRM" "$B" windows revoke "$WG" > "$DIR/revoke.json" || true   # its connection is cut: the reply may not arrive
"$B" windows list --all --format json > "$DIR/after.json"
python3 -c 'import json,sys
gs=json.load(open(sys.argv[1]))["data"]["windowGrants"]
sys.exit(0 if any(g["windowGrantId"]==sys.argv[2] and g["state"]=="revoked" for g in gs) else 1)' "$DIR/after.json" "$WG" \
    && ok "the window grant is revoked" || bad "after revoke: $(cat "$DIR/after.json")"
SID2=$(field "$("$B" session open --desktop "$DESK" --format json > "$DIR/session2.json"; echo "$DIR/session2.json")" data.sessionId)
"$B" observe --session "$SID2" --format json > "$DIR/observe2.json"
grep -q window_grant_missing "$DIR/observe2.json" && ok "observe refused after revoke" || bad "observe after revoke: $(cat "$DIR/observe2.json")"

echo "== 8. nothing created, audit names no window content"
DISPLAYS_AFTER=$(system_profiler SPDisplaysDataType 2>/dev/null | grep -c "Resolution:")
[ "$DISPLAYS_BEFORE" = "$DISPLAYS_AFTER" ] && ok "display count unchanged ($DISPLAYS_AFTER)" || bad "displays $DISPLAYS_BEFORE -> $DISPLAYS_AFTER"
sqlite3 -readonly "$DIR/side.runtime/hub.sqlite" "SELECT at, client_id, method, decision, reason FROM auth_events WHERE decision IN ('asked','confirmed','granted','used','revoked','ended','cut','denied') ORDER BY rowid" > "$DIR/audit.json"
tail -25 "$DIR/audit.json"
sqlite3 -readonly "$DIR/side.runtime/hub.sqlite" "SELECT count(*) FROM auth_events WHERE reason LIKE '%Chess%' OR reason LIKE '%国际象棋%'" | grep -qx 0 \
    && ok "no window title or app name in the audit" || bad "window content is in the audit"
echo "passed $pass, failed $fail"
[ $fail -eq 0 ] && [ $pass -ge 20 ]
