#!/bin/bash
# Regression cases for verify-engine-source-map.sh, each in a throwaway copy
# of the engine directories, the source map and the script.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fresh() {
    rm -rf "$TMP/repo"
    mkdir -p "$TMP/repo/Sources" "$TMP/repo/Tests" "$TMP/repo/scripts" "$TMP/repo/docs/migration"
    cp -R "$ROOT/Sources/Engine" "$TMP/repo/Sources/"
    cp -R "$ROOT/Tests/Engine" "$TMP/repo/Tests/"
    cp "$HERE/verify-engine-source-map.sh" "$TMP/repo/scripts/"
    cp "$ROOT/docs/migration/source-map.csv" "$TMP/repo/docs/migration/"
}
expect() {  # expect accept|reject NAME
    local want="$1" name="$2"
    if "$TMP/repo/scripts/verify-engine-source-map.sh" >/dev/null 2>&1; then got=accept; else got=reject; fi
    if [[ "$got" == "$want" ]]; then echo "ok   $name"; else echo "FAIL $name: wanted $want, got $got"; FAILED=1; fi
}
FAILED=0
MAP="$TMP/repo/docs/migration/source-map.csv"
CORE="$TMP/repo/Sources/Engine/SecondScreenCore"

fresh; expect accept "the migrated engine as committed"
fresh; echo "// edit" >> "$CORE/Images.swift"; expect reject "a copied file edited"
fresh; echo "// edit" >> "$CORE/Images.swift"
/usr/bin/sed -i '' 's#^\(Sources/Engine/SecondScreenCore/Images.swift,.*\),copied,none,#\1,modified,local fix for the test,#' "$MAP"
expect accept "an edited file recorded as modified with a reason"
fresh; echo "// edit" >> "$CORE/Images.swift"
/usr/bin/sed -i '' 's#^\(Sources/Engine/SecondScreenCore/Images.swift,.*\),copied,none,#\1,modified,none,#' "$MAP"
expect reject "an edited file recorded as modified without a reason"
fresh; echo "// new" > "$CORE/Stray.swift"; expect reject "a file without a row"
fresh; rm "$CORE/Images.swift"; expect reject "a row whose file is gone"
fresh; /usr/bin/sed -i '' '1s/,sha256,/,hash,/' "$MAP"; expect reject "a map without the sha256 column"

[[ $FAILED == 0 ]] || exit 1
