#!/usr/bin/env python3
"""ACP-T18-04 (read-only variant): `agentdesktop mcp` against a side instance.

    scripts/acp/mcp-readonly-probe.py <agentdesktop-cli> <endpoint> <out-dir>

Only read-only tools are called (runtime_status, desktop_list, run_show and
request_show with ids that do not exist); nothing creates a Desktop, launches
an app or sends input. The endpoint must be a side instance under /tmp/adt-*.
Shows that every tool is one runtime/1 request answered by that endpoint:

1. tools/list: each tool name, recorded.
2. runtime_status through MCP reports identity.endpoint == <endpoint> and the
   same instanceId as `agentdesktop runtime status` run directly; the
   Runtime's connection count is higher while the MCP session is open.
3. lsof of the MCP process while it is open: its only unix socket.
4. The same tools with the endpoint pointed at a path where nothing listens:
   every call is an error (no other way in, no fallback to another socket).

Every read has a 10 s timeout. Writes <out-dir>/mcp-probe.json; exit 0 when
all checks hold, 1 otherwise, 2 on usage errors.
"""
import json
import os
import select
import subprocess
import sys
import time

TIMEOUT = 10.0
BOGUS_RUN = "run_qtest000000000000"
BOGUS_REQ = "req_qtest000000000000"


class MCP:
    def __init__(self, cli, endpoint, log):
        env = dict(os.environ, AGENTDESKTOP_ENDPOINT=endpoint)
        self.p = subprocess.Popen([cli, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, env=env)
        self.buf = b""
        self.n = 0
        self.log = log

    def call(self, method, params=None):
        self.n += 1
        msg = {"jsonrpc": "2.0", "id": self.n, "method": method, "params": params or {}}
        self.log.append({"dir": "out", "msg": msg})
        self.p.stdin.write((json.dumps(msg) + "\n").encode())
        self.p.stdin.flush()
        deadline = time.time() + TIMEOUT
        while time.time() < deadline:
            while b"\n" in self.buf:
                line, self.buf = self.buf.split(b"\n", 1)
                if not line.strip():
                    continue
                m = json.loads(line)
                self.log.append({"dir": "in", "msg": m})
                if m.get("id") == self.n:
                    return m
            r, _, _ = select.select([self.p.stdout], [], [], 0.2)
            if r:
                chunk = os.read(self.p.stdout.fileno(), 65536)
                if not chunk:
                    raise RuntimeError(f"mcp closed stdout during {method}")
                self.buf += chunk
        raise TimeoutError(f"no answer to {method} within {TIMEOUT} s")

    def tool(self, name, args=None):
        r = self.call("tools/call", {"name": name, "arguments": args or {}})
        res = r.get("result") or {}
        text = next((c.get("text") for c in res.get("content", []) if c.get("type") == "text"), None)
        try:
            body = json.loads(text) if text else None
        except ValueError:
            body = text
        return {"isError": res.get("isError"), "body": body, "rpcError": r.get("error")}

    def close(self):
        try:
            self.p.stdin.close()
            self.p.wait(timeout=TIMEOUT)
        except Exception:
            self.p.kill()
            self.p.wait()
        return self.p.returncode, self.p.stderr.read().decode(errors="replace")[:2000]


def cli_json(cli, endpoint, *args):
    out = subprocess.run([cli, *args, "--endpoint", endpoint, "--json"], capture_output=True, timeout=TIMEOUT)
    return json.loads(out.stdout.decode())


def main(cli, endpoint, out_dir):
    if not endpoint.startswith("/tmp/adt-"):
        print("endpoint must be a side instance under /tmp/adt-*")
        return 2
    os.makedirs(out_dir, exist_ok=True)
    rec, checks, log = {"endpoint": "<side>/" + os.path.basename(endpoint)}, [], []

    def check(name, ok, detail=""):
        checks.append({"check": name, "ok": bool(ok), "detail": detail})

    direct = cli_json(cli, endpoint, "runtime", "status")["data"]
    before = direct["status"]["connections"]
    m = MCP(cli, endpoint, log)
    try:
        init = m.call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                     "clientInfo": {"name": "qtest-mcp-probe", "version": "0.1.0"}})
        rec["initialize"] = {k: init["result"].get(k) for k in ("protocolVersion", "capabilities", "serverInfo")}
        tools = m.call("tools/list")["result"]["tools"]
        rec["tools"] = [t["name"] for t in tools]
        check("tools/list answers", len(tools) > 0, f"{len(tools)} tools")

        st = m.tool("runtime_status")
        ident = (st["body"] or {}).get("identity", {})
        check("runtime_status ok", st["isError"] is False, json.dumps(st)[:300])
        check("answered by the side endpoint", ident.get("endpoint") == endpoint, ident.get("endpoint", ""))
        check("same Runtime instance as the CLI", ident.get("instanceId") == direct["identity"]["instanceId"],
              f"mcp={ident.get('instanceId')} cli={direct['identity']['instanceId']}")
        during = cli_json(cli, endpoint, "runtime", "status")["data"]["status"]["connections"]
        check("MCP holds a Runtime connection", during > before, f"connections before={before} during={during}")
        lsof = subprocess.run(["lsof", "-a", "-U", "-p", str(m.p.pid)], capture_output=True, timeout=TIMEOUT).stdout.decode()
        unix_lines = [l for l in lsof.splitlines()[1:] if " unix " in l]
        rec["mcpUnixSockets"] = len(unix_lines)
        check("MCP process has exactly one unix socket", len(unix_lines) == 1, f"{len(unix_lines)} unix sockets")
        inet = subprocess.run(["lsof", "-a", "-i", "-p", str(m.p.pid)], capture_output=True, timeout=TIMEOUT).stdout.decode()
        check("MCP process has no network socket", inet.strip() == "", inet[:200])

        dl = m.tool("desktop_list")
        check("desktop_list ok and empty", dl["isError"] is False and dl["body"].get("desktops") == [], json.dumps(dl)[:300])
        rs = m.tool("run_show", {"runId": BOGUS_RUN})
        rec["run_show_bogus"] = rs
        check("run_show of an unknown run is a Runtime error", rs["isError"] is True, json.dumps(rs)[:300])
        rq = m.tool("request_show", {"requestId": BOGUS_REQ})
        rec["request_show_bogus"] = rq
        check("request_show of an unknown request is a Runtime error", rq["isError"] is True, json.dumps(rq)[:300])
        rec["calls"] = {"runtime_status": {"isError": st["isError"]}, "desktop_list": dl}
    finally:
        code, err = m.close()
    rec["mcpExit"] = code
    check("MCP exits cleanly on stdin close", code == 0, f"exit {code}; stderr {err[:200]!r}")
    after = cli_json(cli, endpoint, "runtime", "status")["data"]["status"]
    rec["afterStatus"] = {k: after[k] for k in ("connections", "desktops", "sessions", "runs")}
    check("nothing was created", after["desktops"] == 0 and after["sessions"] == 0 and after["runs"] == 0, json.dumps(rec["afterStatus"]))

    # No other way in: the same tools against a path where nothing listens.
    dead = os.path.join(os.path.dirname(endpoint), "qtest-nothing-here.runtime.sock")
    dlog = []
    d = MCP(cli, dead, dlog)
    try:
        dead_results = {name: d.tool(name, args) for name, args in
                        [("runtime_status", {}), ("desktop_list", {}), ("request_show", {"requestId": BOGUS_REQ})]}
    finally:
        dcode, _ = d.close()
    rec["deadEndpoint"] = {k: {"isError": v["isError"], "code": (v["body"] or {}).get("code") if isinstance(v["body"], dict) else v["body"]}
                           for k, v in dead_results.items()}
    check("with no Runtime every tool fails", all(v["isError"] is True for v in dead_results.values()), json.dumps(rec["deadEndpoint"]))

    rec["checks"] = checks
    text = json.dumps(rec, ensure_ascii=False, indent=1).replace(endpoint, "<side>/" + os.path.basename(endpoint))
    text = text.replace(os.path.dirname(endpoint), "<side>")
    with open(os.path.join(out_dir, "mcp-probe.json"), "w") as f:
        f.write(text)
    with open(os.path.join(out_dir, "mcp-transcript.jsonl"), "w") as f:
        for e in log + [{"dir": "note", "note": "dead endpoint session"}] + dlog:
            f.write(json.dumps(e, ensure_ascii=False).replace(endpoint, "<side>/" + os.path.basename(endpoint))
                    .replace(os.path.dirname(endpoint), "<side>") + "\n")
    for c in checks:
        print(("PASS " if c["ok"] else "FAIL ") + c["check"] + ("  — " + c["detail"] if c["detail"] else ""))
    return 0 if all(c["ok"] for c in checks) else 1


if __name__ == "__main__":
    if len(sys.argv) != 4:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(*sys.argv[1:]))
