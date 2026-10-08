#!/bin/bash
# Check the migrated engine against its source map (docs/migration/source-map.csv).
#
# - every row's targetPath exists;
# - a row whose decision is "copied" still has the bytes it was copied with:
#   its sha256 and its git blob id both match (an edit needs a row with
#   decision "modified" and the reason in semanticChanges);
# - every file under Sources/Engine and Tests/Engine has exactly one row, so
#   nothing enters the engine directories without recorded provenance.
#
# Exits 0 when all hold, 1 listing every problem otherwise. Needs only
# /usr/bin/python3; no network, no engine checkout.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MAP="${1:-$ROOT/docs/migration/source-map.csv}"
exec /usr/bin/python3 - "$ROOT" "$MAP" <<'PY'
import csv, hashlib, os, sys

root, path = sys.argv[1], sys.argv[2]
required = ["targetPath", "sourceRepo", "sourceTag", "sourceCommit", "sourcePath", "blob",
            "sha256", "decision", "semanticChanges", "tests", "license"]
problems = []
with open(path, newline="") as fh:
    reader = csv.DictReader(fh)
    missing = [c for c in required if c not in (reader.fieldnames or [])]
    if missing:
        print(f"error: {path} lacks columns: {', '.join(missing)}", file=sys.stderr)
        sys.exit(1)
    rows = list(reader)

seen = {}
copied = 0
for n, row in enumerate(rows, start=2):
    target = row["targetPath"]
    if target in seen:
        problems.append(f"line {n}: {target} is listed twice (also line {seen[target]})")
        continue
    seen[target] = n
    file = os.path.join(root, target)
    if not os.path.isfile(file):
        problems.append(f"line {n}: {target} does not exist")
        continue
    decision = row["decision"]
    if decision == "copied":
        data = open(file, "rb").read()
        sha = hashlib.sha256(data).hexdigest()
        blob = hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()
        if sha != row["sha256"]:
            problems.append(f"line {n}: {target} sha256 {sha} != recorded {row['sha256']}")
        elif blob != row["blob"]:
            problems.append(f"line {n}: {target} blob {blob} != recorded {row['blob']}")
        else:
            copied += 1
    elif decision == "modified":
        if not row["semanticChanges"].strip() or row["semanticChanges"].strip() == "none":
            problems.append(f"line {n}: {target} is modified but semanticChanges gives no reason")
    else:
        problems.append(f"line {n}: {target} has unknown decision {decision!r}")

for top in ("Sources/Engine", "Tests/Engine"):
    for dirpath, _, names in os.walk(os.path.join(root, top)):
        for name in names:
            if name == ".DS_Store":
                continue
            rel = os.path.relpath(os.path.join(dirpath, name), root)
            if rel not in seen:
                problems.append(f"{rel} is not in the source map")

if problems:
    for p in problems:
        print(f"error: {p}", file=sys.stderr)
    sys.exit(1)
print(f"source map ok: {len(rows)} rows, {copied} byte-identical copies, {len(rows) - copied} modified")
PY
