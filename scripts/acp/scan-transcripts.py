#!/usr/bin/env python3
"""Scan fake-editor transcripts for agent-initiated editor calls (ACP-T05-03).

    scripts/acp/scan-transcripts.py <dir> [<dir> ...]

Every transcript.jsonl under the given directories is read. A frame the
agent wrote ("dir": "in") that carries a method is a request or
notification from the agent to the editor. The fake editor never declares
fs or terminal (clientCapabilities fs.* false, terminal false), so any
fs/* or terminal/* call is a violation. Prints a JSON summary; exit 1 on a
violation, 2 when no transcript was found.
"""
import json
import sys
from collections import Counter
from pathlib import Path

FORBIDDEN = ("fs/", "terminal/")


def main(dirs):
    files = [p for d in dirs for p in sorted(Path(d).rglob("transcript.jsonl"))]
    if not files:
        print(json.dumps({"error": "no transcript.jsonl found", "dirs": dirs}))
        return 2
    methods, hits, frames, declared = Counter(), [], 0, Counter()
    for f in files:
        for line in f.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            e = json.loads(line)
            m = e.get("msg")
            if e.get("dir") == "out" and isinstance(m, dict) and m.get("method") == "initialize":
                caps = (m.get("params") or {}).get("clientCapabilities") or {}
                fs = caps.get("fs") or {}
                declared["fs" if fs.get("readTextFile") or fs.get("writeTextFile") else "no-fs"] += 1
                declared["terminal" if caps.get("terminal") else "no-terminal"] += 1
            if e.get("dir") != "in" or not isinstance(m, dict):
                continue
            frames += 1
            meth = m.get("method")
            if isinstance(meth, str):
                methods[meth] += 1
                if meth.startswith(FORBIDDEN):
                    hits.append({"file": str(f), "ms": e.get("ms"), "method": meth})
    print(json.dumps({"transcripts": len(files), "agentFrames": frames, "agentMethods": dict(methods),
                      "initializeDeclared": dict(declared), "violations": hits}, ensure_ascii=False, indent=1))
    return 1 if hits else 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1:]))
