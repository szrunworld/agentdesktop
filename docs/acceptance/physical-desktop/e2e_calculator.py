#!/usr/bin/env python3
"""Physical Window Desktop, end to end on Calculator (no business risk).

    python3 e2e_calculator.py ENDPOINT OUT.json

ENDPOINT is a test copy's runtime socket. The operator starts Calculator
first (it stays where macOS put it) and may bring it forward once if it is
covered; this script never moves, launches or activates anything. It
records every step with a pass/fail/blocked result and the display count,
which must stay the same throughout: no virtual display is created.

Steps: handshake → desktop.create {physical} → window.list Calculator →
window.bind (frame unchanged) → session.open → run.start → observe (bound
window only) → act click "7" → observe (display shows 7) → unbind/rebind
(generation grows) → run.finish → session.close → desktop.destroy (display
and app untouched). Occlusion and a closed window are recorded when the
operator sets them up (see README.md).
"""
import json
import socket
import subprocess
import sys
import time
import uuid

API = "agentdesktop.runtime/1"


def displays() -> int:
    out = subprocess.run(["system_profiler", "SPDisplaysDataType"], capture_output=True, text=True).stdout
    return out.count("Resolution:")


class Conn:
    def __init__(self, path: str):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.connect(path)
        self.f = self.s.makefile("rwb")

    def call(self, method, params=None, context=None):
        req = {"apiVersion": API, "requestId": "e2e_" + uuid.uuid4().hex[:12], "method": method, "params": params or {}}
        if context:
            req["context"] = context
        self.f.write((json.dumps(req, ensure_ascii=False) + "\n").encode())
        self.f.flush()
        return json.loads(self.f.readline())


def main():
    endpoint, out = sys.argv[1], sys.argv[2]
    steps = []
    before = displays()

    def step(sid, title, ok, detail, blocked=False):
        steps.append({"id": sid, "title": title, "result": "blocked" if blocked else ("passed" if ok else "failed"),
                      "displays": displays(), "detail": detail})
        print(f"{steps[-1]['result']:7} {sid:4} {title}")

    c = Conn(endpoint)
    hs = c.call("runtime.handshake", {"apiVersions": [API], "client": {"name": "physical-desktop-e2e", "version": "0.1.0"}})
    step("P1", "handshake", hs.get("ok"), {"build": hs.get("data", {}).get("build")})

    d = c.call("desktop.create", {"name": "e2e-physical", "physical": {}})
    desk = d.get("data", {})
    step("P2", "desktop.create physical: kind physical, nothing created", d.get("ok") and desk.get("kind") == "physical" and displays() == before,
         {"response": d})
    did = desk.get("desktopId")

    wl = c.call("window.list", {"bundleId": "com.apple.calculator"})
    wins = [w for w in wl.get("data", {}).get("windows", []) if w.get("onScreen")]
    step("P3", "window.list finds Calculator", bool(wins), {"windows": wins})
    if not wins:
        return finish(steps, out, before)
    w = wins[0]
    pid, wid, frame_before = w["process"]["pid"], w["windowId"], w["frame"]

    b = c.call("window.bind", {"desktopId": did, "pid": pid, "windowId": wid})
    after = [x for x in c.call("window.list", {"pid": pid}).get("data", {}).get("windows", []) if x["windowId"] == wid]
    step("P4", "window.bind: bound, window not moved", b.get("ok") and after and after[0]["frame"] == frame_before,
         {"binding": b.get("data", {}).get("binding"), "frameBefore": frame_before, "frameAfter": after[0]["frame"] if after else None, "error": b.get("error")})

    s = c.call("session.open", {"desktopId": did})
    sid = s.get("data", {}).get("sessionId")
    r = c.call("run.start", {}, {"sessionId": sid})
    run = r.get("data", {}).get("run", {})
    rid = run.get("runId")
    step("P5", "session.open + run.start (Delegated, connection_scoped)",
         s.get("ok") and r.get("ok") and run.get("lifetime") == "connection_scoped",
         {"sessionId": sid, "run": {k: run.get(k) for k in ("runId", "kind", "ownership", "lifetime", "phase")}})

    o = c.call("observe", {}, {"sessionId": sid, "runId": rid})
    if not o.get("ok"):
        reason = o.get("error", {}).get("details", {}).get("reason")
        step("P6", f"observe refused ({reason}): fail closed", o["error"]["code"] == "stale_observation", {"error": o["error"]},
             blocked=True)
        c.call("run.finish", {"runId": rid, "exitCode": 1}, {"sessionId": sid, "runId": rid})
        c.call("session.close", {"sessionId": sid})
        c.call("desktop.destroy", {"desktopId": did})
        return finish(steps, out, before)
    obs = o["data"]
    img = obs.get("image") or {}
    same_window = obs.get("target", {}).get("windowId") == wid
    within = img.get("transform", {}).get("originX") == frame_before["x"] and img.get("transform", {}).get("originY") == frame_before["y"]
    step("P6", "observe: the image is the bound window (origin = window frame)", same_window and within,
         {"target": obs.get("target"), "image": {k: img.get(k) for k in ("artifactId", "width", "height", "sha256", "transform")},
          "elements": len(obs.get("elements", [])), "coverage": obs.get("coverage")})

    seven = next((e for e in obs.get("elements", []) if e.get("role", "").endswith("Button") and e.get("label") in ("7", "seven")), None)
    if not seven:
        step("P7", "act click 7", False, {"note": "no button labelled 7 in the elements"})
    else:
        a = c.call("act", {"snapshotId": obs["snapshotId"], "action": {"kind": "click", "target": {"elementRef": seven["id"]}}},
                   {"sessionId": sid, "runId": rid})
        step("P7", "act click 7 on the bound window: delivered", a.get("ok") and a["data"].get("delivery") == "dispatched",
             {"receipt": a.get("data"), "error": a.get("error")})
        time.sleep(0.5)
        o2 = c.call("observe", {}, {"sessionId": sid, "runId": rid})
        texts = [e.get("value") or e.get("label") for e in o2.get("data", {}).get("elements", []) if "StaticText" in e.get("role", "")]
        step("P8", "observe again: the display shows 7 (effect verified by observation, not by the receipt)",
             o2.get("ok") and any(t and "7" in str(t) for t in texts), {"staticTexts": texts[:6], "error": o2.get("error")})

    u = c.call("window.unbind", {"desktopId": did})
    rb = c.call("window.bind", {"desktopId": did, "pid": pid, "windowId": wid})
    step("P9", "unbind/rebind: generation grows, older snapshots are stale",
         u.get("ok") and rb.get("ok") and rb["data"]["binding"]["generation"] > (b.get("data", {}).get("binding") or {}).get("generation", 0),
         {"generation": rb.get("data", {}).get("binding", {}).get("generation")})
    stale = c.call("act", {"snapshotId": obs["snapshotId"], "action": {"kind": "key", "key": "escape"}}, {"sessionId": sid, "runId": rid})
    step("P10", "an act on a snapshot from before the rebind is refused, not sent",
         not stale.get("ok") and stale["error"].get("notSent") is True, {"error": stale.get("error")})

    fin = c.call("run.finish", {"runId": rid, "exitCode": 0}, {"sessionId": sid, "runId": rid})
    sc = c.call("session.close", {"sessionId": sid})
    de = c.call("desktop.destroy", {"desktopId": did})
    alive = subprocess.run(["kill", "-0", str(pid)]).returncode == 0
    step("P11", "run.finish, session.close, desktop.destroy: display stays, Calculator keeps running",
         fin.get("ok") and sc.get("ok") and de.get("ok") and alive and displays() == before,
         {"destroy": de.get("data"), "calculatorAlive": alive})
    return finish(steps, out, before)


def finish(steps, out, before):
    record = {"probe": "physical-desktop e2e (Calculator)", "at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
              "displaysBefore": before, "displaysAfter": displays(), "steps": steps,
              "summary": {r: [s["id"] for s in steps if s["result"] == r] for r in ("passed", "failed", "blocked")}}
    with open(out, "w") as f:
        json.dump(record, f, ensure_ascii=False, indent=2)
    return 1 if record["summary"]["failed"] else 0


if __name__ == "__main__":
    sys.exit(main())
