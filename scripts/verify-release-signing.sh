#!/bin/sh
# A4 S4 release gate (Kevin 2026-10-09: a release blocker). A release build of
# Agent Desktop and its bundled agentdesktop CLI must be Developer ID signed,
# with a Team ID, the hardened runtime, library validation, no entitlement that
# lets other code run inside them, and be notarized. Without this, the CLI is
# only "same_user" to the Runtime (its code identity cannot be bound) and the
# keychain items it creates can be planted by another process.
#
# Not run by CI on development bundles (they are self-signed); run it on the
# release candidate:  scripts/verify-release-signing.sh "build/Agent Desktop.app"
set -u
APP="${1:-build/Agent Desktop.app}"
CLI="$APP/Contents/Resources/bin/agentdesktop"
fail=0
check() { # path
    info=$(codesign -dv --verbose=4 "$1" 2>&1)
    team=$(printf '%s\n' "$info" | sed -n 's/^TeamIdentifier=//p')
    auth=$(printf '%s\n' "$info" | sed -n 's/^Authority=//p' | head -1)
    if [ -z "$team" ] || [ "$team" = "not set" ]; then echo "FAIL $1: no Team ID"; fail=1; fi
    case "$auth" in "Developer ID Application:"*) ;; *) echo "FAIL $1: not Developer ID signed ($auth)"; fail=1;; esac
    printf '%s\n' "$info" | grep -q 'flags=.*runtime' || { echo "FAIL $1: hardened runtime is off"; fail=1; }
    ents=$(codesign -d --entitlements :- "$1" 2>/dev/null)
    for e in com.apple.security.cs.allow-dyld-environment-variables com.apple.security.cs.disable-library-validation \
             com.apple.security.get-task-allow; do
        printf '%s' "$ents" | grep -q "$e" && { echo "FAIL $1: entitlement $e lets other code run inside it"; fail=1; }
    done
    codesign --verify --strict --deep "$1" 2>/dev/null || { echo "FAIL $1: signature does not verify"; fail=1; }
}
check "$APP"
check "$CLI"
spctl -a -vv -t exec "$APP" 2>&1 | grep -q "source=Notarized Developer ID" || { echo "FAIL $APP: not notarized (spctl)"; fail=1; }
[ $fail -eq 0 ] && echo "OK release signing: Developer ID, Team ID, hardened runtime, no injection entitlements, notarized"
exit $fail
