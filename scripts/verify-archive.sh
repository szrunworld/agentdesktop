#!/bin/bash
# Check a distributed archive against its manifest: the archive's own hash,
# then every file inside the unpacked .app. Usage: verify-archive.sh ZIP MANIFEST
set -euo pipefail
ARCHIVE="$1"; MANIFEST="$2"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
/usr/bin/python3 - "$ARCHIVE" "$MANIFEST" "$TMP" <<'PY'
import hashlib, json, os, subprocess, sys
archive, manifest, tmp = sys.argv[1:4]
m = json.load(open(manifest))
def sha(p):
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''): h.update(chunk)
    return h.hexdigest()
bad = []
if sha(archive) != m['archive']['sha256']: bad.append('archive hash differs')
subprocess.run(['ditto', '-x', '-k', archive, tmp], check=True)
apps = [d for d in os.listdir(tmp) if d.endswith('.app')]
if len(apps) != 1: bad.append(f'expected one .app in the archive, found {apps}')
else:
    app = os.path.join(tmp, apps[0])
    shipped, links = {}, {}
    for root, _, files in os.walk(app):
        for f in files:
            p = os.path.join(root, f)
            rel = os.path.relpath(p, app)
            if os.path.islink(p): links[rel] = os.readlink(p)
            else: shipped[rel] = sha(p)
    for rel, want in m['files'].items():
        got = shipped.pop(rel, None)
        if got is None: bad.append(f'missing in archive: {rel}')
        elif got != want: bad.append(f'hash differs: {rel}')
    for rel in shipped: bad.append(f'not in manifest: {rel}')
    for rel, want in m.get('links', {}).items():
        got = links.pop(rel, None)
        if got is None: bad.append(f'missing link in archive: {rel}')
        elif got != want: bad.append(f'link target differs: {rel}')
    for rel in links: bad.append(f'link not in manifest: {rel}')
if bad:
    print('\n'.join('error: ' + b for b in bad), file=sys.stderr); sys.exit(1)
print(f"verified {len(m['files'])} files and {len(m.get('links', {}))} links in {os.path.basename(archive)}")
PY
