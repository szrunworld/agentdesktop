#!/bin/bash
# Release smoke: check a distributed archive the way a new user meets it.
#
#   scripts/release-smoke.sh ZIP MANIFEST [--release] [--report FILE]
#
# 1. The archive matches its manifest (scripts/verify-archive.sh).
# 2. It unpacks into a fresh 0700 directory under /tmp; the unpacked bundle's
#    signature still verifies; its signing level is reported. With --release
#    the Developer ID gate (scripts/verify-release-signing.sh) must pass too.
# 3. The packaged command surface (scripts/verify-command-surface.py).
# 4. The CLI's build provenance equals the manifest's source revision.
# 5. The unpacked host starts as a side instance (AGENTDESKTOP_SOCKET in that
#    directory, never the product endpoint) and the CLI, with a fresh empty
#    keychain of its own (never the login keychain), sees what a new user
#    sees before pairing:
#      - doctor: the handshake names this host and this build; its failures
#        are only missing OS permissions;
#      - runtime capabilities: every method the frozen contract marks
#        implemented is served; nothing outside the contract is served;
#      - runtime status, desktop list and desktop create are refused with
#        pairing_required (exit 4): an unpaired client reads nothing and
#        creates nothing.
# 6. The side instance stops on SIGTERM; its directory is removed only after
#    the process has exited.
#
# Not covered here (needs a person or a signed build): pairing confirmation in
# the Agent Desktop window, Screen Recording / Accessibility grants on a clean
# account, Gatekeeper on a downloaded (quarantined) archive, Desktop creation
# and input. docs/release/README.md lists where each is checked.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHIVE=""; MANIFEST=""; RELEASE=0; REPORT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --release) RELEASE=1; shift ;;
        --report) REPORT="$2"; shift 2 ;;
        -*) echo "unknown option $1" >&2; exit 2 ;;
        *) if [[ -z "$ARCHIVE" ]]; then ARCHIVE="$1"; elif [[ -z "$MANIFEST" ]]; then MANIFEST="$1"; else echo "too many arguments" >&2; exit 2; fi; shift ;;
    esac
done
[[ -n "$ARCHIVE" && -n "$MANIFEST" ]] || { echo "usage: release-smoke.sh ZIP MANIFEST [--release] [--report FILE]" >&2; exit 2; }
ARCHIVE="$(cd -- "$(dirname -- "$ARCHIVE")" && pwd)/$(basename -- "$ARCHIVE")"
MANIFEST="$(cd -- "$(dirname -- "$MANIFEST")" && pwd)/$(basename -- "$MANIFEST")"

# sun_path holds 104 bytes: keep the directory short.
DIR="$(mktemp -d /tmp/adt-rel-XXXXXX)"
chmod 700 "$DIR"
HOST_PID=""
cleanup() {
    if [[ -n "$HOST_PID" ]] && kill -0 "$HOST_PID" 2>/dev/null; then
        kill -TERM "$HOST_PID" 2>/dev/null || true
        for _ in $(seq 1 100); do kill -0 "$HOST_PID" 2>/dev/null || break; sleep 0.1; done
        kill -0 "$HOST_PID" 2>/dev/null && kill -KILL "$HOST_PID" 2>/dev/null || true
    fi
    rm -rf "$DIR"
}
trap cleanup EXIT

step() { printf '== %s\n' "$*"; }

step "archive matches manifest"
"$ROOT/scripts/verify-archive.sh" "$ARCHIVE" "$MANIFEST"

step "unpack into $DIR"
ditto -x -k "$ARCHIVE" "$DIR/unpacked"
APP="$DIR/unpacked/Agent Desktop.app"
CLI="$APP/Contents/Resources/bin/agentdesktop"
[[ -x "$APP/Contents/MacOS/Agent Desktop" && -x "$CLI" ]] || { echo "error: the archive lacks the host or the CLI" >&2; exit 1; }
codesign --verify --strict "$APP"
# After the Developer ID change the CLI path is a relative link into
# Contents/Helpers; check the code it resolves to.
codesign --verify --strict "$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$CLI")"
TEAM="$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
AUTHORITY="$(codesign -dv --verbose=2 "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
FLAGS="$(codesign -dv "$APP" 2>&1 | sed -n 's/^CodeDirectory .*flags=\([^ ]*\).*/\1/p')"
if spctl -a -t exec "$APP" >/dev/null 2>&1; then GATEKEEPER=accepted; else GATEKEEPER=rejected; fi
ARCHS="$(lipo -archs "$APP/Contents/MacOS/Agent Desktop")"
CLI_ARCHS="$(lipo -archs "$CLI")"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
echo "signed by: $AUTHORITY; team: ${TEAM:-none}; flags: $FLAGS; Gatekeeper: $GATEKEEPER"
echo "architectures: host $ARCHS, cli $CLI_ARCHS; minimum macOS $MIN_OS"
if [[ $RELEASE == 1 ]]; then
    step "release signing gate"
    "$ROOT/scripts/verify-release-signing.sh" "$APP"
fi

step "packaged command surface"
python3 "$ROOT/scripts/verify-command-surface.py" "$CLI"

# A keychain file of its own: the CLI finds no credential, as on a new
# account, and nothing is read from or written to the login keychain.
KEYCHAIN="$DIR/cli.keychain-db"
security create-keychain -p smoke "$KEYCHAIN"
export AGENTDESKTOP_KEYCHAIN="$KEYCHAIN"
unset AGENTDESKTOP_ENDPOINT AGENTDESKTOP_CONTEXT AGENTDESKTOP_PROFILE
EP="$DIR/side.runtime.sock"

step "provenance and side instance"
AGENTDESKTOP_SOCKET="$DIR/side.sock" "$APP/Contents/MacOS/Agent Desktop" > "$DIR/host.log" 2>&1 &
HOST_PID=$!
# runtime.capabilities is one of the few methods an unpaired client may call.
for _ in $(seq 1 200); do
    "$CLI" runtime capabilities --endpoint "$EP" --format json > "$DIR/capabilities.json" 2>/dev/null && break
    kill -0 "$HOST_PID" 2>/dev/null || { cat "$DIR/host.log" >&2; echo "error: the host exited" >&2; exit 1; }
    sleep 0.1
done
"$CLI" version --format json > "$DIR/version.json"
"$CLI" runtime capabilities --endpoint "$EP" --format json > "$DIR/capabilities.json"
set +e
"$CLI" runtime status --endpoint "$EP" --format json > "$DIR/status.json" 2>/dev/null; STATUS_EXIT=$?
"$CLI" doctor --endpoint "$EP" --format json > "$DIR/doctor.json"; DOCTOR_EXIT=$?
"$CLI" desktop list --endpoint "$EP" --format json > "$DIR/desktops.json" 2>/dev/null; DESKTOPS_EXIT=$?
"$CLI" desktop create --endpoint "$EP" --size 800x600 --format json > "$DIR/create.json" 2>/dev/null; CREATE_EXIT=$?
set -e

python3 - "$ROOT" "$DIR" "$MANIFEST" "$HOST_PID" "$DOCTOR_EXIT" "$STATUS_EXIT" "$DESKTOPS_EXIT" "$CREATE_EXIT" \
    "$TEAM" "$AUTHORITY" "$FLAGS" "$GATEKEEPER" "$ARCHS" "$CLI_ARCHS" "$MIN_OS" "${REPORT:-}" <<'PY'
import json, sys
(root, d, manifest, host_pid, doctor_exit, status_exit, desktops_exit, create_exit,
 team, authority, flags, gatekeeper, archs, cli_archs, min_os, report) = sys.argv[1:17]
load = lambda n: json.load(open(f'{d}/{n}.json'))
m = json.load(open(manifest))
version, caps, doctor = load('version'), load('capabilities'), load('doctor')
bad = []

# Provenance: the CLI and the running host were built from the manifest's revision.
src = m['engine']['source']
if version['data']['build']['source'] != src:
    bad.append(f"CLI build {version['data']['build']['source']} != manifest {src}")
identity = doctor.get('data', {}).get('identity') or {}
if str(identity.get('pid')) != host_pid:
    bad.append(f"the handshake names pid {identity.get('pid')}, not the side instance {host_pid}")
if identity.get('build', {}).get('source') != src:
    bad.append(f"Runtime build {identity.get('build', {}).get('source')} != manifest {src}")

# Public commands are backed by what the packaged Runtime really serves.
contract = {x['method'] for x in json.load(open(f'{root}/contracts/runtime/v1/methods.json'))['methods']
            if x['status'] == 'implemented'}
cdata = caps['data']
served = {x['method'] for x in cdata['interface']['methods']}
missing, extra = sorted(contract - served), sorted(served - contract)
if missing: bad.append(f'contract methods the Runtime does not serve: {missing}')
if extra: bad.append(f'Runtime serves methods outside the contract: {extra}')

# doctor answers; on a machine without the grants only permission checks fail.
checks = doctor.get('data', {}).get('checks', [])
failed = [c for c in checks if c['status'] == 'fail']
non_permission = [c for c in failed if c.get('code') != 'permission_denied']
if not checks: bad.append('doctor returned no checks')
if non_permission: bad.append(f'doctor failures besides permissions: {non_permission}')
if (doctor_exit == '0') != (not failed): bad.append(f'doctor exit {doctor_exit} does not match its checks')

# Before pairing: refused, nothing created.
def refused(name, code):
    try: r = load(name)
    except Exception as e: bad.append(f'{name}: no JSON answer ({e})'); return None
    got = r.get('error', {}).get('code')
    if r.get('ok') or got != 'pairing_required': bad.append(f'{name}: expected pairing_required, got {got or "ok"}')
    if code != '4': bad.append(f'{name}: exit {code}, expected 4')
    return got
refused('status', status_exit)
refused('desktops', desktops_exit)
refused('create', create_exit)

summary = {
    'archive': m['archive'], 'source': src,
    'signing': {'authority': authority, 'teamId': team or None, 'flags': flags, 'gatekeeper': gatekeeper},
    'architectures': {'host': archs.split(), 'cli': cli_archs.split()}, 'minimumMacOS': min_os,
    'runtime': {'pid': identity.get('pid'), 'apiVersion': identity.get('apiVersion'),
                'productVersion': identity.get('productVersion'), 'buildSource': identity.get('build', {}).get('source')},
    'methods': {'contract': len(contract), 'served': len(served)},
    'backend': {k: v for k, v in cdata.items() if k not in ('interface', 'apiVersion')},
    'doctor': {'exit': int(doctor_exit), 'checks': [{k: c.get(k) for k in ('id', 'status', 'code')} for c in checks]},
    'unpaired': {'runtime status': int(status_exit), 'desktop list': int(desktops_exit), 'desktop create': int(create_exit)},
    'problems': bad,
}
out = json.dumps(summary, ensure_ascii=False, indent=2)
print(out)
if report:
    open(report, 'w').write(out + '\n')
sys.exit(1 if bad else 0)
PY

step "stop the side instance"
kill -TERM "$HOST_PID"
for _ in $(seq 1 100); do kill -0 "$HOST_PID" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$HOST_PID" 2>/dev/null; then echo "error: the side instance did not exit within 10 s of SIGTERM" >&2; exit 1; fi
HOST_PID=""
[[ ! -S "$EP" ]] || echo "note: the side instance left its socket behind (taken over on next start)"
echo "release smoke passed"
