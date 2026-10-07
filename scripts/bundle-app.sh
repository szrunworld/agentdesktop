#!/bin/bash
# Build the product host and wrap it in "build/Agent Desktop.app".
#
# The bundle holds, with their provenance in Contents/Resources/build.json:
#   Contents/MacOS/Agent Desktop            the host (Sources/AgentDesktop)
#   Contents/Resources/libexec/2ndscreen    the engine's CLI, built from the pinned
#                                           2ndscreen release in the dependency graph
#   Contents/Resources/bin/2ndscreen        the supported command line: the CLI bound
#                                           to this product's endpoint and runtime
#   Contents/Resources/bin/agentdesktop     the same command under the product's name
#
# Beside the bundle, after signing: "Agent Desktop-<build>.zip" (ditto, keeps
# the .app) and "Agent Desktop-<build>.manifest.json" with the sha256 of every
# file as shipped and of the archive. build.json inside the bundle records the
# build inputs before signing; the manifest records what is distributed.
#
# Not in the bundle, by decision (docs/boundaries.md): Android tools (adb,
# scrcpy) and the task runtime. The task runtime joins once a 2ndscreen
# release can be installed without business skills (roadmap C01); until
# then `2ndscreen task` reports the runtime as not installed.
#
# The bundle gives the app a stable identity, so macOS attributes the Screen
# Recording and Accessibility grants to Agent Desktop. It is signed with a
# self-signed certificate kept in a dedicated keychain
# (~/Library/Keychains/agentdesktop-signing.keychain-db, created on first
# run); macOS ties grants to the certificate, so they survive rebuilds. The
# release pipeline replaces this with the Developer ID identity (roadmap A04).
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Agent Desktop.app"
BUNDLE_ID="com.agentdesktop.app"
VERSION="0.1.0"          # CFBundleShortVersionString: the product's own line, apart from the engine's
BUILD_LABEL="0.1.0-dev"  # what the product calls this build

cd "$ROOT"

# A release build consumes the engine exactly as resolved. Refuse local
# overrides: an editable checkout (swift package edit) or a Packages/ dir.
if [[ -d "$ROOT/Packages" ]]; then
    echo "error: Packages/ holds a local override of a dependency; builds use the pinned release only" >&2
    exit 1
fi
if [[ -f .build/workspace-state.json ]] && grep -q '"edited"' .build/workspace-state.json; then
    echo "error: a dependency is in edit mode (swift package unedit to leave it)" >&2
    exit 1
fi

# The engine is compiled exactly as pinned: resolve first, then refuse a
# checkout at another commit or with any change (work tree, index, untracked).
swift package resolve
ENGINE_REVISION="$(/usr/bin/python3 -c 'import json,sys; p=[x for x in json.load(open("Package.resolved"))["pins"] if x["identity"]=="2ndscreen"][0]; print(p["state"]["revision"])')"
ENGINE_VERSION="$(/usr/bin/python3 -c 'import json,sys; p=[x for x in json.load(open("Package.resolved"))["pins"] if x["identity"]=="2ndscreen"][0]; print(p["state"].get("version","")) ')"
"$ROOT/scripts/check-engine-checkout.sh" "$ROOT/.build/checkouts/2ndscreen" "$ENGINE_REVISION"

swift build -c release
swift build -c release --product 2ndscreen
BIN_DIR="$(swift build -c release --show-bin-path)"
BIN="$BIN_DIR/AgentDesktop"
CLI="$BIN_DIR/2ndscreen"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin" "$APP/Contents/Resources/libexec"
cp "$BIN" "$APP/Contents/MacOS/Agent Desktop"
cp "$CLI" "$APP/Contents/Resources/libexec/2ndscreen"
# The supported command line is the CLI bound to this product: its endpoint
# (Sources/AgentDesktop/HostRole.swift; a caller testing a side instance may
# choose another socket) and its own task runtime directory, always. The
# engine's CLI would otherwise fall back to the runtime inside a running
# 2ndscreen.app, mixing that host's runtime with this product; bound to a
# directory that does not exist yet, `task` and the MCP tools that spawn it
# refuse instead. The MCP server runs the same executable with this
# environment, so its task tools are bound the same way.
cat > "$APP/Contents/Resources/bin/2ndscreen" <<'WRAPPER'
#!/bin/bash
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
: "${SECONDSCREEN_SOCKET:=$HOME/Library/Application Support/AgentDesktop/control.sock}"
export SECONDSCREEN_SOCKET
export SECONDSCREEN_TASK_RUNTIME="$here/../task-runtime"
exec "$here/../libexec/2ndscreen" "$@"
WRAPPER
chmod 755 "$APP/Contents/Resources/bin/2ndscreen"
ln -s 2ndscreen "$APP/Contents/Resources/bin/agentdesktop"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>Agent Desktop</string>
    <key>CFBundleDisplayName</key><string>Agent Desktop</string>
    <key>CFBundleExecutable</key><string>Agent Desktop</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
cat > "$APP/Contents/Resources/build.json" <<JSON
{
  "product": "Agent Desktop",
  "bundleId": "$BUNDLE_ID",
  "version": "$VERSION",
  "build": "$BUILD_LABEL",
  "builtAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "source": "$(git rev-parse --verify -q HEAD || echo unknown)$([[ -z "$(git status --porcelain --untracked-files=all 2>/dev/null)" ]] || echo -dirty)",
  "swift": "$(swift --version 2>&1 | head -1)",
  "engine": {
    "package": "https://github.com/szrunworld/2ndscreen.git",
    "version": "$ENGINE_VERSION",
    "revision": "$ENGINE_REVISION"
  },
  "inputs": {
    "note": "sha256 of the build products before the bundle's signature; the files as shipped are listed in the distribution manifest beside the archive",
    "Contents/MacOS/Agent Desktop": "$(sha "$BIN")",
    "Contents/Resources/libexec/2ndscreen": "$(sha "$CLI")"
  },
  "taskRuntime": null,
  "android": null
}
JSON

KEYCHAIN="$HOME/Library/Keychains/agentdesktop-signing.keychain-db"
KEYCHAIN_PASSWORD="agentdesktop-local-signing"  # guards only this throwaway signing key
CERT_NAME="Agent Desktop Local Signing"

find_identity() {
    security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null \
        | awk -v cn="$CERT_NAME" 'index($0, "\"" cn "\"") { print $2; exit }'
}

if [[ ! -f "$KEYCHAIN" ]]; then
    security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
    security set-keychain-settings "$KEYCHAIN"  # no auto-lock
fi
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"

IDENTITY="$(find_identity)"
if [[ -z "$IDENTITY" ]]; then
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    cat > "$TMP/req.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$CERT_NAME
[ext]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
    # The system LibreSSL writes a PKCS#12 that `security import` accepts.
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/req.cnf" 2>/dev/null
    /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
        -out "$TMP/id.p12" -passout "pass:$KEYCHAIN_PASSWORD" -name "$CERT_NAME"
    security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$KEYCHAIN_PASSWORD" -T /usr/bin/codesign >/dev/null
    # Let codesign use the key without a GUI prompt.
    security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
    IDENTITY="$(find_identity)"
fi
[[ -n "$IDENTITY" ]] || { echo "error: could not create the local signing identity" >&2; exit 1; }

# codesign only finds identities in keychains on the search list, so add the
# signing keychain for the duration of the signature and then restore the list.
ORIGINAL_KEYCHAINS=()
while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    ORIGINAL_KEYCHAINS+=("$(eval "printf '%s' $line")")
done < <(security list-keychains -d user)
restore_keychains() { security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}"; }
security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" "$KEYCHAIN"
# Nested code is signed before the bundle that seals it.
if ! codesign --force --keychain "$KEYCHAIN" --sign "$IDENTITY" --identifier "$BUNDLE_ID.cli" "$APP/Contents/Resources/libexec/2ndscreen" \
    || ! codesign --force --keychain "$KEYCHAIN" --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"; then
    restore_keychains
    exit 1
fi
restore_keychains
codesign --verify --strict "$APP"

# What must not be in a product bundle (docs/boundaries.md).
if find "$APP" \( -name adb -o -name scrcpy-server -o -path '*/Resources/android*' -o -path '*/task-runtime/skills/boss*' \) | grep -q .; then
    echo "error: the bundle carries Android tools or business skills" >&2
    exit 1
fi

# What is distributed: the signed bundle as an archive that keeps the .app,
# and a manifest of every file as shipped plus the archive itself. Written
# beside the bundle, never inside it: the seal covers Contents/Resources.
ARCHIVE="$ROOT/build/Agent Desktop-$BUILD_LABEL.zip"
MANIFEST="$ROOT/build/Agent Desktop-$BUILD_LABEL.manifest.json"
rm -f "$ARCHIVE" "$MANIFEST"
ditto -c -k --keepParent "$APP" "$ARCHIVE"
{
    echo "{"
    echo "  \"product\": \"Agent Desktop\", \"build\": \"$BUILD_LABEL\", \"bundleId\": \"$BUNDLE_ID\","
    echo "  \"engine\": { \"version\": \"$ENGINE_VERSION\", \"revision\": \"$ENGINE_REVISION\" },"
    echo "  \"archive\": { \"name\": \"$(basename "$ARCHIVE")\", \"sha256\": \"$(sha "$ARCHIVE")\" },"
    echo "  \"files\": {"
    first=1
    while IFS= read -r f; do
        rel="${f#"$APP/"}"
        [[ $first == 1 ]] || echo ","
        first=0
        printf '    "%s": "%s"' "$rel" "$(sha "$f")"
    done < <(find "$APP" -type f | LC_ALL=C sort)
    echo
    echo "  },"
    echo "  \"links\": {"
    first=1
    while IFS= read -r f; do
        rel="${f#"$APP/"}"
        [[ $first == 1 ]] || echo ","
        first=0
        printf '    "%s": "%s"' "$rel" "$(readlink "$f")"
    done < <(find "$APP" -type l | LC_ALL=C sort)
    echo
    echo "  }"
    echo "}"
} > "$MANIFEST"
echo "built $APP ($BUILD_LABEL on 2ndscreen $ENGINE_VERSION $ENGINE_REVISION)"
echo "archive $ARCHIVE"
echo "manifest $MANIFEST"
