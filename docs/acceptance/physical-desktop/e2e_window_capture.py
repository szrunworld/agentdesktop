#!/usr/bin/env python3
"""Physical Desktop: the observation is the bound window alone (review round 1, finding 2).

    python3 e2e_window_capture.py ENDPOINT RUNTIME_DIR OUT.json

Binds the app named by $BUNDLE (default Chess), observes once, and checks that
the image is exactly the window (size = window frame × display scale, origin =
window origin) and that no whole-screen capture was ever written to the
Runtime's artifact directory. Read-only: no input is sent.
"""
import glob, json, os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_calculator import Conn, displays, API

endpoint, rt, out = sys.argv[1:4]
bundle = os.environ.get("BUNDLE", "com.apple.Chess")
before = displays(); steps = []
def step(i, t, ok, d): steps.append({"id": i, "title": t, "result": "passed" if ok else "failed", "detail": d}); print(steps[-1]["result"], i, t)
c = Conn(endpoint)
c.call("runtime.handshake", {"apiVersions": [API], "client": {"name": "physical-desktop-e2e", "version": "0.1.0"}})
desk = c.call("desktop.create", {"name": "e2e-capture", "physical": {}})["data"]
did, scr = desk["desktopId"], desk["screen"]
w = [x for x in c.call("window.list", {"bundleId": bundle})["data"]["windows"] if x["onScreen"]][0]
c.call("window.bind", {"desktopId": did, "pid": w["process"]["pid"], "windowId": w["windowId"]})
sid = c.call("session.open", {"desktopId": did})["data"]["sessionId"]
o = c.call("observe", {}, {"sessionId": sid})
if o.get("ok"):
    img, f = o["data"]["image"], o["data"]["target"]["windowFrame"]
    scale = 2 if scr["hiDPI"] else 1
    ok = (img["width"], img["height"]) == (int(f["width"] * scale), int(f["height"] * scale)) and \
         (img["transform"]["originX"], img["transform"]["originY"]) == (f["x"], f["y"])
    step("W1", "the image is the window alone (size = frame × scale, origin = window origin)", ok,
         {"image": {k: img[k] for k in ("width", "height", "sha256", "transform")}, "windowFrame": f, "screen": scr})
else:
    step("W1", "observe", False, {"error": o.get("error")})
files = [os.path.basename(p) for p in glob.glob(os.path.join(rt, "artifacts", "**", "*"), recursive=True) if os.path.isfile(p)]
step("W2", "no whole-screen capture was written (no *.screen.png in the artifact directory)",
     not any(n.endswith(".screen.png") for n in files), {"artifactFiles": files})
c.call("session.close", {"sessionId": sid}); d = c.call("desktop.destroy", {"desktopId": did})
step("W3", "destroyed; display count unchanged", d.get("ok") and displays() == before, {"displays": displays()})
json.dump({"probe": "physical-desktop window capture", "at": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "steps": steps}, open(out, "w"), ensure_ascii=False, indent=2)
sys.exit(1 if any(s["result"] == "failed" for s in steps) else 0)
