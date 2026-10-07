#!/bin/bash
# Regression cases for check-engine-checkout.sh, each in a throwaway repo.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/check-engine-checkout.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

fresh() {
    rm -rf "$TMP/repo"
    git init -q -b main "$TMP/repo"
    echo a > "$TMP/repo/Package.swift"
    git -C "$TMP/repo" add -A
    git -C "$TMP/repo" commit -q -m one
    git -C "$TMP/repo" rev-parse HEAD
}
expect() {  # expect accept|reject NAME
    local want="$1" name="$2"
    if "$CHECK" "$TMP/repo" "$PIN" 2>/dev/null; then got=accept; else got=reject; fi
    if [[ "$got" == "$want" ]]; then echo "ok   $name"; else echo "FAIL $name: wanted $want, got $got"; FAILED=1; fi
}
FAILED=0

PIN="$(fresh)"; expect accept "pristine checkout at the pinned commit"
PIN="$(fresh)"; echo b >> "$TMP/repo/Package.swift"; expect reject "work tree change"
PIN="$(fresh)"; echo b >> "$TMP/repo/Package.swift"; git -C "$TMP/repo" add -A; expect reject "staged change"
PIN="$(fresh)"; echo c > "$TMP/repo/Extra.swift"; expect reject "untracked source file"
PIN="$(fresh)"; git -C "$TMP/repo" commit -q --allow-empty -m two; expect reject "checkout at another commit"
PIN="$(fresh)"; mkdir -p "$TMP/repo/Sources/X"; echo c > "$TMP/repo/Sources/X/New.swift"; expect reject "untracked file in a new directory"

[[ $FAILED == 0 ]] || exit 1
