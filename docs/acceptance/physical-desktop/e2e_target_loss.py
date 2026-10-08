#!/usr/bin/env python3
"""Physical Desktop, target loss on Calculator (review round 1).

    python3 e2e_target_loss.py ENDPOINT minimize|quit OUT.json

minimize: the window disappears while the process lives. The script itself
asks the Runtime to send cmd+M to the bound window (the only input it sends),
then checks that observation and input are refused and nothing else is sent.
quit: C1 again. The operator quits Calculator after the script has bound it
(the script does it with SIGTERM to the pid it bound). A refusal counts when
the code is stale_observation and nothing is sent: "window_gone" and "the
bound process has exited" are the same safe refusal (corrected assertion;
the first C1 record is kept).

Both: the Run is not ended by the loss, action.refused records it, a second
attempt is refused too (no retry), run.finish ends it, the display count
does not change.
"""
import json, subprocess, sys, time
sys.path.insert(0, __file__.rsplit("/", 1)[0])
from e2e_calculator import Conn, displays, API
import os
BUNDLE = os.environ.get("BUNDLE", "com.apple.calculator")


def main():
    endpoint, mode, out = sys.argv[1], sys.argv[2], sys.argv[3]
    before = displays(); steps = []

    def step(sid, title, ok, detail):
        steps.append({"id": sid, "title": title, "result": "passed" if ok else "failed", "displays": displays(), "detail": detail})
        print(f"{steps[-1]['result']:7} {sid:4} {title}")

    c = Conn(endpoint)
    c.call("runtime.handshake", {"apiVersions": [API], "client": {"name": "physical-desktop-e2e", "version": "0.1.0"}})
    did = c.call("desktop.create", {"name": f"e2e-{mode}", "physical": {}})["data"]["desktopId"]
    w = [x for x in c.call("window.list", {"bundleId": BUNDLE})["data"]["windows"] if x["onScreen"]][0]
    pid, wid = w["process"]["pid"], w["windowId"]
    c.call("window.bind", {"desktopId": did, "pid": pid, "windowId": wid})
    sid = c.call("session.open", {"desktopId": did})["data"]["sessionId"]
    rid = c.call("run.start", {}, {"sessionId": sid})["data"]["run"]["runId"]
    o = c.call("observe", {}, {"sessionId": sid, "runId": rid})
    step("L1", "bound and observed before the loss", o.get("ok"), {"error": o.get("error"), "windowId": wid, "pid": pid})
    if not o.get("ok"):
        return finish(c, did, sid, rid, steps, out, before)
    snap = o["data"]["snapshotId"]

    if mode == "minimize":
        a = c.call("act", {"snapshotId": snap, "action": {"kind": "key", "key": "m", "modifiers": ["cmd"]}}, {"sessionId": sid, "runId": rid})
        step("L2", "cmd+M sent to the bound window through the Runtime", a.get("ok"), {"receipt": a.get("data"), "error": a.get("error")})
        time.sleep(1.5)
        alive = subprocess.run(["kill", "-0", str(pid)]).returncode == 0
        step("L3", "the process is still alive", alive, {"pid": pid})
    else:
        subprocess.run(["kill", "-TERM", str(pid)]); time.sleep(1.5)
        step("L2", "the app quit (SIGTERM to the bound pid)", subprocess.run(["kill", "-0", str(pid)]).returncode != 0, {"pid": pid})

    o2 = c.call("observe", {}, {"sessionId": sid, "runId": rid})
    e = o2.get("error") or {}
    step("L4", "observe after the loss: refused (stale_observation)", not o2.get("ok") and e.get("code") == "stale_observation",
         {"error": e, "reason": (e.get("details") or {}).get("reason")})
    for i in (1, 2):
        a2 = c.call("act", {"snapshotId": snap, "action": {"kind": "key", "key": "return"}}, {"sessionId": sid, "runId": rid})
        e2 = a2.get("error") or {}
        step(f"L5.{i}", f"input after the loss (attempt {i}): refused, not sent", not a2.get("ok") and e2.get("code") == "stale_observation" and e2.get("notSent") is True, {"error": e2})
    shown = c.call("run.show", {"runId": rid})["data"]
    events = c.call("run.events", {"runId": rid})["data"]["events"]
    refused = [x for x in events if x["type"] == "action.refused"]
    step("L6", "the Run is still running; action.refused records each refusal",
         shown["phase"] == "running" and len(refused) >= 2 and all(x["data"]["reason"]["code"] == "stale_observation" for x in refused),
         {"phase": shown["phase"], "unknownActions": shown["unknownActions"], "eventTypes": [x["type"] for x in events]})
    return finish(c, did, sid, rid, steps, out, before)


def finish(c, did, sid, rid, steps, out, before):
    f = c.call("run.finish", {"runId": rid, "exitCode": 1}, {"sessionId": sid, "runId": rid})
    c.call("session.close", {"sessionId": sid})
    d = c.call("desktop.destroy", {"desktopId": did})
    steps.append({"id": "L7", "title": "run.finish and desktop.destroy; display count unchanged",
                  "result": "passed" if f.get("ok") and d.get("ok") and displays() == before else "failed",
                  "displays": displays(), "detail": {"run": (f.get("data") or {}).get("phase"), "destroy": d.get("data")}})
    print(f"{steps[-1]['result']:7} L7   run.finish and desktop.destroy; display count unchanged")
    record = {"probe": "physical-desktop target loss", "at": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "displaysBefore": before,
              "displaysAfter": displays(), "steps": steps,
              "summary": {r: [s["id"] for s in steps if s["result"] == r] for r in ("passed", "failed")}}
    json.dump(record, open(out, "w"), ensure_ascii=False, indent=2)
    return 1 if record["summary"]["failed"] else 0


if __name__ == "__main__":
    sys.exit(main())
