#!/bin/bash
# Sign and notarize an already-built bundle; never substitute a local identity.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
: "${DEVELOPER_ID_IDENTITY:?set the Developer ID Application signing identity}"
: "${TEAM:?set the expected Team ID}"
: "${APP_PROVISION_PROFILE:?set the Developer ID profile for com.agentdesktop.app}"
: "${CLI_PROVISION_PROFILE:?set the Developer ID profile for com.agentdesktop.app.agentdesktop}"
: "${NOTARY_KEYCHAIN_PROFILE:?set the notarytool keychain profile}"
[[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]] || { echo 'invalid Team ID' >&2; exit 1; }
APP="${1:?pass Agent Desktop.app}"
CLI="$APP/Contents/Resources/bin/agentdesktop"
[[ -f "$CLI" && ! -L "$CLI" ]] || { echo 'expected a fresh bundle with an unwrapped CLI' >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# Restricted keychain entitlements need a profile in an app-like wrapper.
# The existing CLI path remains a relative symlink into that sealed wrapper.
WRAPPER="$APP/Contents/Helpers/AgentDesktopCLI.app"
for spec in app cli; do
    if [[ "$spec" == app ]]; then
        profile="$APP_PROVISION_PROFILE"; identifier=com.agentdesktop.app
    else
        profile="$CLI_PROVISION_PROFILE"; identifier=com.agentdesktop.app.agentdesktop
    fi
    security cms -D -i "$profile" > "$TMP/$spec.profile.plist"
    python3 - "$TMP/$spec.profile.plist" "$TMP/$spec.entitlements.plist" "$TEAM" "$identifier" <<'PY'
import datetime, plistlib, sys
profile_path, output, team, identifier = sys.argv[1:]
with open(profile_path, 'rb') as f: p = plistlib.load(f)
e = p.get('Entitlements', {})
expected = team + '.' + identifier
group = team + '.com.agentdesktop.client-credential'
assert team in p.get('TeamIdentifier', []), 'profile team mismatch'
assert p.get('ExpirationDate', datetime.datetime.min) > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None), 'profile expired'
assert e.get('com.apple.application-identifier') == expected, 'profile must explicitly authorize this application identifier'
assert any(g == group or (g.endswith('*') and group.startswith(g[:-1])) for g in e.get('keychain-access-groups', [])), 'profile does not authorize the product credential group'
assert not e.get('get-task-allow'), 'development profile is not a release profile'
with open(output, 'wb') as f:
    plistlib.dump({'com.apple.application-identifier': expected,
                  'com.apple.developer.team-identifier': team,
                  'keychain-access-groups': [group]}, f)
PY
done
mkdir -p "$WRAPPER/Contents/MacOS"
cp "$CLI" "$WRAPPER/Contents/MacOS/agentdesktop"
python3 - "$WRAPPER/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as f:
    plistlib.dump({'CFBundleIdentifier': 'com.agentdesktop.app.agentdesktop',
                  'CFBundleExecutable': 'agentdesktop', 'CFBundlePackageType': 'APPL',
                  'CFBundleName': 'AgentDesktopCLI', 'CFBundleVersion': '1'}, f)
PY
cp "$CLI_PROVISION_PROFILE" "$WRAPPER/Contents/embedded.provisionprofile"
cp "$APP_PROVISION_PROFILE" "$APP/Contents/embedded.provisionprofile"
codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_IDENTITY" \
    --entitlements "$TMP/cli.entitlements.plist" "$WRAPPER"
rm "$CLI"
ln -s ../../Helpers/AgentDesktopCLI.app/Contents/MacOS/agentdesktop "$CLI"
codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_IDENTITY" \
    --entitlements "$TMP/app.entitlements.plist" "$APP"
codesign --verify --strict --deep "$APP"
ditto -c -k --keepParent "$APP" "$TMP/notarize.zip"
xcrun notarytool submit "$TMP/notarize.zip" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
"$ROOT/scripts/verify-release-signing.sh" "$APP"
