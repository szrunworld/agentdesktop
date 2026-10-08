#!/bin/bash
# Make a stale Runtime socket for ACP-T03-04: the file exists and is a
# socket, but nothing listens on it. Only under /tmp/adt-*.
#
#   scripts/acp/stale-socket.sh [/tmp/adt-q-unreachable/stale.runtime.sock]
set -eu
path="${1:-/tmp/adt-q-unreachable/stale.runtime.sock}"
case "$path" in /tmp/adt-*) ;; *) echo "only under /tmp/adt-*"; exit 2 ;; esac
mkdir -m 700 -p "$(dirname "$path")"
rm -f "$path"
python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$path"
echo "$path"
