"""Tests of the neutral example agent against a fake Runtime (no real
Runtime, no real windows): python3 -m unittest discover examples/neutral-agent
"""
import contextlib
import io
import json
import os
import socket
import sys
import tempfile
import threading
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parents[1] / "sdks" / "python"))

import neutral_agent  # noqa: E402
from agentdesktop_client import API_VERSION  # noqa: E402

TOKEN = "adt1_" + "A" * 43
IDENTITY = {"product": "AgentDesktop", "productVersion": "0.1.0-dev", "apiVersion": API_VERSION,
            "apiVersions": [API_VERSION], "instanceId": "rt_neutral", "pid": 1, "startedAt": "2026-10-11T00:00:00Z",
            "endpoint": "/x", "platform": {"os": "macos", "osVersion": "15", "arch": "arm64"}, "build": {"source": "t"}}


class FakeRuntime:
    """Pairing, a grant and one Desktop, line by line over a Unix socket.

    `pairing`: what hub.pairing.status ends with (approved | denied).
    `refuse`: method -> error code, answered instead of the result.
    """

    def __init__(self, pairing="approved", refuse=None, desktops=("d_1",)):
        self.dir = tempfile.mkdtemp(prefix="adt-na-", dir="/tmp")
        self.path = os.path.join(self.dir, "r.sock")
        self.pairing, self.refuse, self.desktops = pairing, refuse or {}, list(desktops)
        self.requests, self.polls = [], 0
        self.srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.srv.bind(self.path)
        self.srv.listen(8)
        threading.Thread(target=self._loop, daemon=True).start()

    def close(self):
        self.srv.close()

    def methods(self):
        return [r["method"] for r in self.requests]

    def _loop(self):
        while True:
            try:
                conn, _ = self.srv.accept()
            except OSError:
                return
            threading.Thread(target=self._serve, args=(conn,), daemon=True).start()

    def _serve(self, conn):
        buf, paired = b"", False
        with conn:
            while True:
                chunk = conn.recv(65536)
                if not chunk:
                    return
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    req = json.loads(line)
                    self.requests.append(req)
                    if req["method"] == "runtime.handshake":
                        paired = req["params"].get("credential", {}).get("token") == TOKEN
                    conn.sendall(json.dumps(self._answer(req, paired)).encode() + b"\n")

    def _answer(self, req, paired):
        m, rid = req["method"], req["requestId"]

        def ok(data):
            return {"apiVersion": API_VERSION, "requestId": rid, "ok": True, "data": data}

        def err(code, msg="refused"):
            return {"apiVersion": API_VERSION, "requestId": rid, "ok": False,
                    "error": {"code": code, "message": msg, "phase": "request", "retryable": False, "notSent": True}}

        if m in self.refuse:
            return err(self.refuse[m])
        if m == "runtime.handshake":
            principal = {"clientId": "app:neutral", "role": "paired", "connectionId": "c1"} if paired \
                else {"clientId": "unpaired:c0", "role": "unpaired", "connectionId": "c0"}
            return ok(dict(IDENTITY, principal=principal))
        if m == "hub.pairing.start":
            return ok({"pairingId": "pair_1", "shortCode": "123456", "state": "requested", "expiresAt": "2026-10-11T01:00:00Z"})
        if m == "hub.pairing.status":
            self.polls += 1
            if self.polls < 2:
                return ok({"pairingId": "pair_1", "state": "requested", "expiresAt": "2026-10-11T01:00:00Z"})
            if self.pairing == "approved":
                return ok({"pairingId": "pair_1", "state": "approved", "expiresAt": "2026-10-11T01:00:00Z",
                           "clientId": "app:neutral", "credential": {"clientId": "app:neutral", "token": TOKEN}})
            return ok({"pairingId": "pair_1", "state": self.pairing, "expiresAt": "2026-10-11T01:00:00Z"})
        if not paired:
            return err("pairing_required", f"{m} needs a paired client")
        if m == "desktop.list":
            return ok({"desktops": [{"desktopId": d, "name": d, "state": "ready"} for d in self.desktops]})
        if m == "session.open":
            return ok({"sessionId": "s_1", "desktopId": req["params"]["desktopId"], "state": "open", "createdAt": "t"})
        if m == "session.close":
            return ok({"sessionId": "s_1", "desktopId": "d_1", "state": "closed", "createdAt": "t"})
        if m == "observe":
            return ok({"snapshotId": "obs_1", "elements": [{"id": "el_2", "role": "AXButton", "label": "完成"}]})
        if m == "act":
            return ok({"receiptId": "rcpt_1", "runId": "run_1", "delivery": "dispatched", "requestId": rid})
        return err("permission_denied", f"{m} is not part of this fake")


class NeutralAgentTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="adt-na-cred-")
        self.cred = os.path.join(self.tmp, "cred.json")

    def run_agent(self, rt, *extra):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = neutral_agent.main(["--endpoint", rt.path, "--credential-file", self.cred, "--poll", "0.01",
                                       "--pair-timeout", "5", *extra])
        steps = [line.split("]", 1)[0].lstrip("[") for line in out.getvalue().splitlines() if line.startswith("[")]
        return code, steps, out.getvalue(), err.getvalue()

    def test_the_whole_life_pair_list_observe_act_disconnect_reconnect(self):
        rt = FakeRuntime()
        try:
            code, steps, out, _ = self.run_agent(rt, "--act", "click:el_2", "--request-id", "na-click-1")
            self.assertEqual(code, 0, out)
            self.assertEqual(steps, ["handshake", "pair.start", "pair.approved", "connect", "desktops", "session.open",
                                     "observe", "act", "disconnect", "reconnect"])
            self.assertIn('"delivery": "dispatched"', out)
            self.assertIn('"sameClient": true', out)
            # The credential is kept owner-only and reused on reconnect.
            self.assertEqual(os.stat(self.cred).st_mode & 0o777, 0o600)
            acts = [r for r in rt.requests if r["method"] == "act"]
            self.assertEqual(len(acts), 1)
            self.assertEqual(acts[0]["requestId"], "na-click-1")
            self.assertEqual(acts[0]["params"]["action"], {"kind": "click", "target": {"elementRef": "el_2"}})
            # A second run reuses the file: no new pairing.
            code, steps, _, _ = self.run_agent(rt, "--list-only")
            self.assertEqual(code, 0)
            self.assertEqual(steps, ["handshake", "credential", "connect", "desktops", "disconnect", "reconnect"])
            self.assertEqual(rt.methods().count("hub.pairing.start"), 1)
        finally:
            rt.close()

    def test_without_act_no_input_is_sent(self):
        rt = FakeRuntime()
        try:
            code, steps, _, _ = self.run_agent(rt)
            self.assertEqual(code, 0)
            self.assertIn("act:skipped", steps)
            self.assertNotIn("act", rt.methods())
        finally:
            rt.close()

    def test_pairing_required_is_explained_and_nothing_else_is_tried(self):
        rt = FakeRuntime()
        try:
            code, steps, _, err = self.run_agent(rt, "--no-pair")
            self.assertEqual(code, neutral_agent.EXIT_REFUSED)
            self.assertEqual(steps, ["handshake", "pair:error"])
            self.assertIn("没有配对", err)
            self.assertEqual(rt.methods(), ["runtime.handshake"])
        finally:
            rt.close()

    def test_a_denied_pairing_is_permission_denied_and_saves_nothing(self):
        rt = FakeRuntime(pairing="denied")
        try:
            code, steps, out, err = self.run_agent(rt)
            self.assertEqual(code, neutral_agent.EXIT_REFUSED)
            self.assertEqual(steps[-1], "pair:error")
            self.assertIn('"code": "permission_denied"', out)
            self.assertIn("pair_1", out)
            self.assertIn("Agent Desktop 窗口", err)
            self.assertFalse(os.path.exists(self.cred))
        finally:
            rt.close()

    def test_grant_missing_on_act_is_explained_and_not_retried(self):
        rt = FakeRuntime(refuse={"act": "grant_missing"})
        try:
            code, steps, _, err = self.run_agent(rt, "--act", "key:escape")
            self.assertEqual(code, neutral_agent.EXIT_REFUSED)
            self.assertEqual(steps[-1], "run:error")
            self.assertIn("授权", err)
            self.assertEqual(rt.methods().count("act"), 1, "a refused action is never retried")
        finally:
            rt.close()

    def test_permission_denied_on_list_is_explained(self):
        rt = FakeRuntime(refuse={"desktop.list": "permission_denied"})
        try:
            code, steps, _, err = self.run_agent(rt)
            self.assertEqual(code, neutral_agent.EXIT_REFUSED)
            self.assertEqual(steps[-1], "run:error")
            self.assertIn("被拒绝", err)
        finally:
            rt.close()

    def test_a_desktop_outside_the_grant_is_not_touched(self):
        rt = FakeRuntime()
        try:
            code, steps, _, _ = self.run_agent(rt, "--desktop-id", "d_other", "--act", "key:escape")
            self.assertEqual(code, neutral_agent.EXIT_REFUSED)
            self.assertNotIn("session.open", rt.methods())
            self.assertNotIn("act", rt.methods())
        finally:
            rt.close()


if __name__ == "__main__":
    unittest.main()
