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


class ObservationStreamTests(unittest.TestCase):
    def test_frames_are_read_and_closing_iterator_closes_only_the_view(self):
        def reply(r):
            subscribed = {"subscriptionId": "view-1", "version": 1, "subscribed": True, "fps": 1, "maxWidth": 200}
            frame = {"apiVersion": API_VERSION, "subscriptionId": "view-1", "sequence": 1,
                     "type": "observation.frame", "status": "ready", "frame": {"image": {"width": 200}}}
            return ok(r, subscribed) + b"\n" + json.dumps(frame).encode()
        rt = FakeRuntime(handshake_then(reply))
        try:
            c = RuntimeClient(rt.path, env={})
            frames = c.observation_frames("desk-1", max_width=200)
            self.assertEqual(next(frames)["frame"]["image"]["width"], 200)
            frames.close()
            self.assertIsNone(c._sock)
            self.assertEqual([r["method"] for r in rt.requests], ["runtime.handshake", "observe.subscribe"])
        finally:
            rt.close()

    def test_a_foreign_subscription_frame_is_rejected(self):
        def reply(r):
            return ok(r, {"subscriptionId": "view-1", "version": 1}) + b"\n" + json.dumps({
                "apiVersion": API_VERSION, "subscriptionId": "foreign", "sequence": 1,
                "type": "observation.frame", "status": "ready", "frame": {}}).encode()
        rt = FakeRuntime(handshake_then(reply))
        try:
            c = RuntimeClient(rt.path, env={})
            with self.assertRaises(RuntimeError_) as caught:
                next(c.observation_frames("desk-1"))
            self.assertEqual(caught.exception.code, "instance_mismatch")
            self.assertIsNone(c._sock)
        finally:
            rt.close()


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

    def test_delegated_run_helpers_preserve_context_and_quiescence(self):
        def reply(r):
            run = {"runId": "run-1", "ownership": "external_client",
                   "lifetime": "connection_scoped", "phase": "stopping",
                   "quiescence": "pending" if r["method"] == "run.cancel" else "confirmed"}
            return ok(r, {"run": run, "attachToken": "test-token"} if r["method"] == "run.start" else run)
        rt = FakeRuntime(handshake_then(reply))
        try:
            with RuntimeClient(rt.path, env={}) as c:
                started = c.run_start("ses-1", request_id="start-1")
                self.assertEqual(started["run"]["lifetime"], "connection_scoped")
                self.assertEqual(c.run_cancel("run-1", request_id="cancel-1")["quiescence"], "pending")
                self.assertEqual(c.run_show("run-1")["quiescence"], "confirmed")
            start = next(r for r in rt.requests if r["method"] == "run.start")
            self.assertEqual(start["context"], {"sessionId": "ses-1"})
            self.assertEqual(start["params"], {})
            self.assertEqual(start["requestId"], "start-1")
        finally:
            rt.close()

    def test_run_start_connection_loss_is_unknown_and_never_replayed(self):
        rt = FakeRuntime(handshake_then(lambda r: None))
        try:
            with RuntimeClient(rt.path, env={}) as c:
                with self.assertRaises(RuntimeError_) as caught:
                    c.run_start("ses-1", request_id="start-unknown")
                self.assertEqual(caught.exception.code, "request_acceptance_unknown")
                self.assertEqual(caught.exception.details["requestId"], "start-unknown")
            self.assertEqual(sum(r["method"] == "run.start" for r in rt.requests), 1)
        finally:
            rt.close()

    def test_request_show_missing_history_remains_not_found(self):
        def reply(r):
            return json.dumps({"apiVersion": API_VERSION, "requestId": r["requestId"], "ok": False,
                               "error": {"code": "not_found", "message": "no retained request", "phase": "handler",
                                         "retryable": False}}).encode()
        rt = FakeRuntime(handshake_then(reply))
        try:
            with RuntimeClient(rt.path, env={}) as c:
                with self.assertRaises(RuntimeError_) as caught:
                    c.request_show("expired-request")
                self.assertEqual(caught.exception.code, "not_found")
                self.assertIsNone(caught.exception.not_sent)
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


def err(req, code, message="refused", phase="request", details=None):
    e = {"code": code, "message": message, "phase": phase, "retryable": False, "notSent": True}
    if details:
        e["details"] = details
    return json.dumps({"apiVersion": API_VERSION, "requestId": req["requestId"], "ok": False, "error": e}).encode()


TOKEN = "adt1_" + "B" * 43


def pairing_runtime(final):
    """hub.pairing.* answering `requested` once, then `final` (a status dict)."""
    polls = []

    def reply(r):
        if r["method"] == "runtime.handshake":
            return ok(r, IDENTITY)
        if r["method"] == "hub.pairing.start":
            return ok(r, {"pairingId": "pair_9", "shortCode": "654321", "state": "requested", "expiresAt": "2026-10-11T01:00:00Z"})
        if r["method"] == "hub.pairing.status":
            polls.append(1)
            if len(polls) == 1:
                return ok(r, {"pairingId": "pair_9", "state": "requested", "expiresAt": "2026-10-11T01:00:00Z"})
            return ok(r, dict({"pairingId": "pair_9", "expiresAt": "2026-10-11T01:00:00Z"}, **final))
        return ok(r, {"desktops": []})
    return reply


class ConsistencyWithCLITests(unittest.TestCase):
    """SDK-01…SDK-05 (08 file): pairing, action, disconnect, reconnect and
    revocation behave as `agentdesktop agents pair` and the CLI do. SDK-06
    (MCP --desktop-id) is Swift's MCPServerTests."""

    def test_sdk01_pairing_returns_the_credential_once_and_reconnects_as_the_app(self):
        rt = FakeRuntime(pairing_runtime({"state": "approved", "clientId": "app:x",
                                          "credential": {"clientId": "app:x", "token": TOKEN}}))
        try:
            c = RuntimeClient(rt.path, env={})
            codes = []
            cred = c.pair("py-app", ["observe"], desktops=["created"], on_code=lambda code, pid: codes.append((code, pid)),
                          timeout=5, poll=0.01)
            self.assertEqual(cred, {"clientId": "app:x", "token": TOKEN})
            self.assertEqual(codes, [("654321", "pair_9")])
            self.assertIsNone(c._sock, "the pairing connection is closed")
            start = next(r for r in rt.requests if r["method"] == "hub.pairing.start")
            self.assertEqual(start["params"], {"agentName": "py-app",
                                               "requested": {"capabilities": ["observe"], "desktops": ["created"], "apps": []}})
            self.assertNotIn("credential", rt.requests[0]["params"], "pairing runs unpaired")
            c.desktops()
            hs = [r for r in rt.requests if r["method"] == "runtime.handshake"]
            self.assertEqual(hs[-1]["params"]["credential"], {"clientId": "app:x", "token": TOKEN})
        finally:
            rt.close()

    def test_sdk01_a_denied_or_expired_pairing_is_permission_denied_with_its_id(self):
        for state in ("denied", "expired"):
            rt = FakeRuntime(pairing_runtime({"state": state}))
            try:
                with self.assertRaises(RuntimeError_) as cm:
                    RuntimeClient(rt.path, env={}).pair("py-app", ["observe"], timeout=5, poll=0.01)
                self.assertEqual(cm.exception.code, "permission_denied")
                self.assertEqual(cm.exception.details, {"pairingId": "pair_9"})
            finally:
                rt.close()

    def test_sdk01_approved_without_a_credential_fails_at_once_like_the_cli(self):
        rt = FakeRuntime(pairing_runtime({"state": "approved", "clientId": "app:x"}))
        try:
            with self.assertRaises(RuntimeError_) as cm:
                RuntimeClient(rt.path, env={}).pair("py-app", ["observe"], timeout=5, poll=0.01)
            self.assertEqual(cm.exception.code, "execution_failed")
            self.assertEqual(sum(r["method"] == "hub.pairing.status" for r in rt.requests), 2, "no polling until the timeout")
        finally:
            rt.close()

    def test_sdk02_a_refused_action_is_reported_once_and_never_resent(self):
        def reply(r):
            if r["method"] == "session.open":
                return ok(r, {"sessionId": "s_1", "desktopId": "d_1", "state": "open", "createdAt": "t"})
            if r["method"] == "act":
                return err(r, "grant_missing", details={"reason": "capability", "capability": "act"})
            return ok(r, {})
        rt = FakeRuntime(handshake_then(reply))
        try:
            with RuntimeClient(rt.path, env={}) as c:
                with c.session("d_1") as s:
                    with self.assertRaises(RuntimeError_) as cm:
                        s.click("obs_1", element="el_2", request_id="py-act-1")
            self.assertEqual(cm.exception.code, "grant_missing")
            self.assertTrue(cm.exception.not_sent)
            acts = [r for r in rt.requests if r["method"] == "act"]
            self.assertEqual(len(acts), 1)
            self.assertEqual(acts[0]["requestId"], "py-act-1")
            self.assertEqual(acts[0]["context"], {"sessionId": "s_1"})
        finally:
            rt.close()

    def test_sdk03_sdk04_disconnect_then_reconnect_with_the_saved_credential(self):
        rt = FakeRuntime(handshake_then(lambda r: ok(r, {"desktops": []})))
        d = tempfile.mkdtemp(prefix="adt-py-cred-")
        path = os.path.join(d, "cred.json")
        try:
            from agentdesktop_client import load_credential, save_credential
            save_credential({"clientId": "app:x", "token": TOKEN}, path)
            self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
            c = RuntimeClient(rt.path, env={"AGENTDESKTOP_CREDENTIAL_FILE": path})
            c.desktops()
            c.close()
            self.assertIsNone(c.identity)
            c.desktops()   # a fresh connection, handshaking again with the same credential
            hs = [r for r in rt.requests if r["method"] == "runtime.handshake"]
            self.assertEqual(len(hs), 2)
            self.assertTrue(all(h["params"]["credential"] == {"clientId": "app:x", "token": TOKEN} for h in hs))
            # A tampered file is no credential (duplicate keys, wrong types).
            with open(path, "w") as f:
                f.write('{"clientId":"app:x","token":"a","token":"b"}')
            with self.assertRaises(RuntimeError_):
                load_credential(path)
            with open(path, "w") as f:
                f.write('{"clientId":"app:x","token":7}')
            with self.assertRaises(RuntimeError_):
                load_credential(path)
        finally:
            rt.close()

    def test_sdk05_a_revoked_credential_is_refused_and_not_retried(self):
        def reply(r):
            return err(r, "client_revoked", "app:x was removed from AgentDesktop; pair again to continue",
                       details={"reason": "client_revoked"})
        rt = FakeRuntime(reply)
        try:
            c = RuntimeClient(rt.path, env={}, credential={"clientId": "app:x", "token": TOKEN})
            with self.assertRaises(RuntimeError_) as cm:
                c.desktops()
            self.assertEqual(cm.exception.code, "client_revoked")
            self.assertIsNone(c._sock)
            self.assertEqual([r["method"] for r in rt.requests], ["runtime.handshake"])
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
