#!/bin/bash
# Refuse to build from an engine checkout that is not exactly the pinned
# release: a different commit, changes in the work tree or the index, or
# untracked files. Usage: check-engine-checkout.sh CHECKOUT PINNED_REVISION
# Exits 0 when the checkout is pristine, 1 with a reason otherwise.
set -euo pipefail
CHECKOUT="$1"
PINNED="$2"
[[ -d "$CHECKOUT/.git" || -f "$CHECKOUT/.git" ]] || { echo "error: $CHECKOUT is not a git checkout" >&2; exit 1; }
HEAD_REV="$(git -C "$CHECKOUT" rev-parse HEAD)"
if [[ "$HEAD_REV" != "$PINNED" ]]; then
    echo "error: the engine checkout is at $HEAD_REV, not the pinned $PINNED" >&2
    exit 1
fi
# --porcelain lists work tree changes, staged changes and untracked files alike.
CHANGES="$(git -C "$CHECKOUT" status --porcelain --untracked-files=all)"
if [[ -n "$CHANGES" ]]; then
    echo "error: the engine checkout has local changes; builds use the pinned release as published:" >&2
    echo "$CHANGES" >&2
    exit 1
fi
