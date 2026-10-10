import glob
import json
import os
import socket
import stat
import tempfile
import threading
import unittest
from pathlib import Path

from agentdesktop_client import API_VERSION, ExecContext, RuntimeClient, RuntimeError_
from agentdesktop_client.client import check_response

REPO = Path(__file__).resolve().parents[3]
IDENTITY = {"product": "AgentDesktop", "productVersion": "0.1.0-dev", "apiVersion": API_VERSION,
            "apiVersions": [API_VERSION], "instanceId": "rt_py", "pid": 1, "startedAt": "2026-10-08T00:00:00Z",
            "endpoint": "/x", "platform": {"os": "macos", "osVersion": "15", "arch": "arm64"}, "build": {"source": "t"}}


class FakeRuntime:
    """A Unix socket answering line by line with `reply(request) -> bytes`."""

    def __init__(self, reply):
        self.dir = tempfile.mkdtemp(prefix="adt-py-", dir="/tmp")
        self.path = os.path.join(self.dir, "r.sock")
        self.requests = []
        self.reply = reply
        self.srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.srv.bind(self.path)
        self.srv.listen(4)
        threading.Thread(target=self._loop, daemon=True).start()

    def _loop(self):
        while True:
            try:
                conn, _ = self.srv.accept()
            except OSError:
                return
            threading.Thread(target=self._serve, args=(conn,), daemon=True).start()

    def _serve(self, conn):
        buf = b""
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
                    out = self.reply(req)
                    if out is None:
                        return
                    conn.sendall(out + b"\n")

    def close(self):
        self.srv.close()


def ok(req, data):
    return json.dumps({"apiVersion": API_VERSION, "requestId": req["requestId"], "ok": True, "data": data},
                      ensure_ascii=False).encode()


def handshake_then(fn):
    def reply(req):
        if req["method"] == "runtime.handshake":
            return ok(req, IDENTITY)
        return fn(req)
    return reply


class FixtureTests(unittest.TestCase):
    def test_shared_response_fixtures(self):
        files = sorted(glob.glob(str(REPO / "contracts/fixtures/runtime/v1/*.json")))
        self.assertGreater(len(files), 10)
        checked = 0
        for f in files:
            doc = json.loads(Path(f).read_text())
            if doc["def"] != "Response":
                continue
            checked += 1
            if f.endswith(".valid.json"):
                check_response(doc["instance"])
            else:
                with self.assertRaises(RuntimeError_, msg=f):
                    check_response(doc["instance"])
        self.assertGreaterEqual(checked, 4)


class ClientTests(unittest.TestCase):
    def test_handshake_then_requests_in_order(self):
        rt = FakeRuntime(handshake_then(lambda r: ok(r, {"desktops": [], "echo": r["method"]})))
        try:
            with RuntimeClient(rt.path, env={}) as c:
                self.assertEqual(c.identity["instanceId"], "rt_py")
                self.assertEqual(c.desktops(), [])
                c.create_desktop("工作区", (1280, 800), request_id="py-create-1")
            sent = rt.requests
            self.assertEqual([r["method"] for r in sent], ["runtime.handshake", "desktop.list", "desktop.create"])
            self.assertEqual(sent[2]["params"], {"name": "工作区", "width": 1280, "height": 800})
            self.assertEqual(sent[2]["requestId"], "py-create-1")
            self.assertTrue(all(r["apiVersion"] == API_VERSION for r in sent))
        finally:
            rt.close()

    def test_errors_keep_their_code(self):
        def err(r):
            return json.dumps({"apiVersion": API_VERSION, "requestId": r["requestId"], "ok": False,
                               "error": {"code": "stale_observation", "message": "observe again", "phase": "handler",
                                         "retryable": False, "notSent": True}}).encode()
        rt = FakeRuntime(handshake_then(err))
        try:
            with RuntimeClient(rt.path, env={}) as c:
                with self.assertRaises(RuntimeError_) as cm:
                    with c.session("d_1"):
                        pass
            self.assertEqual(cm.exception.code, "stale_observation")
            self.assertTrue(cm.exception.not_sent)
            self.assertEqual(cm.exception.phase, "handler")
        finally:
            rt.close()

    def test_bad_replies_are_refused(self):
        for bad in [lambda r: b'{"apiVersion":"agentdesktop.runtime/1","requestId":"x","requestId":"y","ok":true,"data":{}}',
                    lambda r: ok({"requestId": "someone_else"}, {}),
                    lambda r: b'{"schemaVersion":"agentdesktop.ai/1","ok":true}']:
            rt = FakeRuntime(handshake_then(bad))
            try:
                c = RuntimeClient(rt.path, env={})
                with self.assertRaises(RuntimeError_) as cm:
                    c.status()
                self.assertIn(cm.exception.code, {"instance_mismatch", "version_mismatch"})
                c.close()
            finally:
                rt.close()

    def test_offline_and_unknown(self):
        with self.assertRaises(RuntimeError_) as cm:
            RuntimeClient("/nonexistent/r.sock", env={}).status()
        self.assertEqual(cm.exception.code, "runtime_offline")
        self.assertTrue(cm.exception.not_sent)
        rt = FakeRuntime(handshake_then(lambda r: None))   # hang up without replying
        try:
            c = RuntimeClient(rt.path, env={})
            with self.assertRaises(RuntimeError_) as cm:
                c.destroy_desktop("d_1", request_id="py-kill-1")
            self.assertEqual(cm.exception.code, "request_acceptance_unknown")
            self.assertEqual(cm.exception.details["requestId"], "py-kill-1")
        finally:
            rt.close()

    def test_session_exec_context_attaches_and_acts_in_the_run(self):
        rt = FakeRuntime(handshake_then(lambda r: ok(r, {"runId": "run_ctx", "delivery": "dispatched"})))
        d = tempfile.mkdtemp(prefix="adt-py-ctx-")
        path = os.path.join(d, "ctx.json")
        fd = os.open(path, os.O_WRONLY | os.O_CREAT, 0o600)
        os.write(fd, json.dumps({"endpoint": rt.path, "desktopId": "d_1", "sessionId": "s_ctx", "runId": "run_ctx",
                                 "token": "ab" * 32}).encode())
        os.close(fd)
        try:
            c = RuntimeClient(env={"AGENTDESKTOP_CONTEXT": path})
            with c.session() as s:
                s.click("obs_1", element="el_7")
            c.close()
            methods = [r["method"] for r in rt.requests]
            self.assertEqual(methods, ["runtime.handshake", "run.attach", "act"])
            self.assertEqual(rt.requests[2]["context"], {"sessionId": "s_ctx", "runId": "run_ctx"})
            self.assertNotIn("session.close", methods, "the exec's own session stays open")
            os.chmod(path, 0o644)
            with self.assertRaises(RuntimeError_):
                ExecContext.load({"AGENTDESKTOP_CONTEXT": path})
        finally:
            rt.close()


@unittest.skipUnless(os.environ.get("AGENTDESKTOP_SDK_LIVE_ENDPOINT"), "needs a live Runtime")
class LiveTests(unittest.TestCase):
    """Run by the Swift cross-entry test against a real RuntimeServer."""

    def test_flow(self):
        # A4: an external app pairs first; the Swift harness plays the owner
        # and approves. Unpaired, everything but pairing is refused.
        endpoint = os.environ["AGENTDESKTOP_SDK_LIVE_ENDPOINT"]
        with RuntimeClient(endpoint, env={}) as anon:
            with self.assertRaises(RuntimeError_) as cm:
                anon.desktops()
            self.assertEqual(cm.exception.code, "pairing_required")
        pairer = RuntimeClient(endpoint, env={})
        codes = []
        cred = pairer.pair("py-live", ["observe", "act", "desktop.manage", "run"], desktops=["created"],
                           apps=["com.apple.Notes"], on_code=lambda code, pid: codes.append(code), timeout=30, poll=0.1)
        self.assertTrue(cred["clientId"].startswith("app:"))
        self.assertEqual(len(codes[0]), 6)
        with RuntimeClient(endpoint, env={}, credential=cred) as c:
            self.assertEqual(c.identity["principal"]["role"], "paired")
            d = c.create_desktop("py", request_id="py-live-create")["desktopId"]
            self.assertEqual(c.create_desktop("py", request_id="py-live-create")["desktopId"], d)
            c.launch(d, "com.apple.Notes")
            c.bind_window(d, 4)
            with c.session(d) as s:
                o = s.observe()
                el = [e["id"] for e in o["elements"] if e["label"] == "完成"][0]
                r = s.click(o["snapshotId"], element=el, request_id="py-live-click")
                self.assertEqual(r["delivery"], "dispatched")
                self.assertEqual(s.click(o["snapshotId"], element=el, request_id="py-live-click")["receiptId"], r["receiptId"])
                with self.assertRaises(RuntimeError_) as cm:
                    s.click("obs_gone", element=el)
                self.assertEqual(cm.exception.code, "stale_observation")
            c.destroy_desktop(d)
            print("LIVE-OK")


if __name__ == "__main__":
    unittest.main()
