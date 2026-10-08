from __future__ import annotations

import json
import os
import re
import socket
import stat
import uuid
from dataclasses import dataclass
from typing import Any, Iterator, Optional

API_VERSION = "agentdesktop.runtime/1"
PRODUCT = "AgentDesktop"
MAX_FRAME = 1_048_576
_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]*$")
_PHASES = {"local", "connect", "transport", "handshake", "request", "handler"}


class RuntimeError_(Exception):
    """An error of the Runtime API. `code` is the stable interface."""

    def __init__(self, code: str, message: str, phase: str = "local", *, retryable: bool = False,
                 not_sent: Optional[bool] = None, details: Optional[dict] = None):
        super().__init__(f"{code}: {message}")
        self.code, self.message, self.phase = code, message, phase
        self.retryable, self.not_sent, self.details = retryable, not_sent, details or {}

    @classmethod
    def from_json(cls, e: dict) -> "RuntimeError_":
        return cls(e["code"], e["message"], e["phase"], retryable=e.get("retryable", False),
                   not_sent=e.get("notSent"), details=e.get("details"))


def _strict_loads(text: str) -> Any:
    def pairs(items):
        out = {}
        for k, v in items:
            if k in out:
                raise ValueError(f"duplicate key {k!r}")
            out[k] = v
        return out
    return json.loads(text, object_pairs_hook=pairs)


def new_request_id(prefix: str = "py") -> str:
    return f"{prefix}_{uuid.uuid4().hex}"


def resolve_endpoint(option: Optional[str] = None, env: Optional[dict] = None) -> str:
    """--endpoint, then AGENTDESKTOP_ENDPOINT, then the installed product's."""
    env = os.environ if env is None else env
    if option:
        return os.path.expanduser(option)
    if env.get("AGENTDESKTOP_ENDPOINT"):
        return os.path.expanduser(env["AGENTDESKTOP_ENDPOINT"])
    home = env.get("HOME") or os.path.expanduser("~")
    return f"{home}/Library/Application Support/AgentDesktop/runtime.sock"


def check_response(v: Any) -> None:
    """The Response envelope of runtime.schema.json, checked on receipt."""
    if not isinstance(v, dict) or v.get("apiVersion") != API_VERSION:
        raise RuntimeError_("version_mismatch", "reply is not agentdesktop.runtime/1", "transport")
    rid = v.get("requestId")
    if rid is not None and (not isinstance(rid, str) or not _ID.match(rid) or len(rid) > 128):
        raise RuntimeError_("instance_mismatch", "reply has an invalid requestId", "transport")
    if v.get("ok") is True:
        if set(v) != {"apiVersion", "requestId", "ok", "data"} or not isinstance(v["data"], dict):
            raise RuntimeError_("instance_mismatch", "success reply breaks the Response schema", "transport")
    elif v.get("ok") is False:
        e = v.get("error")
        if set(v) != {"apiVersion", "requestId", "ok", "error"} or not isinstance(e, dict) \
                or not {"code", "message", "phase", "retryable"} <= set(e) or e["phase"] not in _PHASES:
            raise RuntimeError_("instance_mismatch", "error reply breaks the Response schema", "transport")
    else:
        raise RuntimeError_("instance_mismatch", "reply has no ok", "transport")


@dataclass
class ExecContext:
    """What `agentdesktop session exec` hands its child (AGENTDESKTOP_CONTEXT)."""
    endpoint: str
    desktop_id: str
    session_id: str
    run_id: str
    token: str

    @classmethod
    def load(cls, env: Optional[dict] = None) -> Optional["ExecContext"]:
        env = os.environ if env is None else env
        path = env.get("AGENTDESKTOP_CONTEXT")
        if not path:
            return None
        st = os.lstat(path)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o077:
            raise RuntimeError_("permission_denied", f"{path} must be this user's file and not readable by others",
                                not_sent=True)
        with open(path, encoding="utf-8") as f:
            v = _strict_loads(f.read())
        return cls(v["endpoint"], v["desktopId"], v["sessionId"], v["runId"], v["token"])


class RuntimeClient:
    """One connection to the Runtime: handshake first, then requests in order.

    Inside `agentdesktop session exec` the context file names the endpoint,
    session and Run; act requests then run inside that Run.
    """

    def __init__(self, endpoint: Optional[str] = None, *, timeout: float = 10.0,
                 client_name: str = "agentdesktop-python", env: Optional[dict] = None):
        env = os.environ if env is None else env
        self.context = ExecContext.load(env)
        if endpoint is None and self.context and not env.get("AGENTDESKTOP_ENDPOINT"):
            endpoint = self.context.endpoint
        self.endpoint = resolve_endpoint(endpoint, env)
        self.timeout, self.client_name = timeout, client_name
        self._sock: Optional[socket.socket] = None
        self._buf = b""
        self.identity: Optional[dict] = None
        self._attached = False

    # -- connection -----------------------------------------------------
    def __enter__(self) -> "RuntimeClient":
        self.handshake()
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    def close(self) -> None:
        if self._sock:
            self._sock.close()
        self._sock, self._buf, self.identity, self._attached = None, b"", None, False

    def _connect(self) -> None:
        try:
            st = os.lstat(self.endpoint)
        except FileNotFoundError:
            raise RuntimeError_("runtime_offline", f"nothing is listening: {self.endpoint} does not exist", "connect",
                                retryable=True, not_sent=True, details={"endpoint": self.endpoint})
        if not stat.S_ISSOCK(st.st_mode):
            raise RuntimeError_("runtime_offline", f"{self.endpoint} is not a socket", "connect", not_sent=True)
        if st.st_uid != os.getuid():
            raise RuntimeError_("permission_denied", f"{self.endpoint} belongs to another user", "connect", not_sent=True)
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(self.timeout)
        try:
            s.connect(self.endpoint)
        except OSError as e:
            s.close()
            raise RuntimeError_("runtime_offline", f"no Runtime is accepting on {self.endpoint} ({e})", "connect",
                                retryable=True, not_sent=True)
        self._sock = s

    def _exchange(self, request: dict) -> dict:
        assert self._sock is not None
        line = json.dumps(request, ensure_ascii=False, separators=(",", ":")).encode() + b"\n"
        if len(line) > MAX_FRAME:
            raise RuntimeError_("invalid_argument", "request exceeds 1 MiB", not_sent=True)
        try:
            self._sock.sendall(line)
            while b"\n" not in self._buf:
                chunk = self._sock.recv(65536)
                if not chunk:
                    raise RuntimeError_("connection_lost", "the Runtime closed the connection before replying", "transport")
                self._buf += chunk
                if len(self._buf) > MAX_FRAME:
                    raise RuntimeError_("connection_lost", "the reply exceeds 1 MiB", "transport")
        except (socket.timeout, OSError) as e:
            self.close()
            raise RuntimeError_("connection_lost", f"no complete reply ({e})", "transport")
        raw, self._buf = self._buf.split(b"\n", 1)
        try:
            v = _strict_loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError) as e:
            raise RuntimeError_("instance_mismatch", f"reply is not JSON: {e}", "transport")
        check_response(v)
        if v["requestId"] is not None and v["requestId"] != request["requestId"]:
            raise RuntimeError_("instance_mismatch", f"reply answers {v['requestId']}, not {request['requestId']}", "transport")
        if not v["ok"]:
            raise RuntimeError_.from_json(v["error"])
        return v["data"]

    def handshake(self) -> dict:
        if self.identity:
            return self.identity
        self._connect()
        try:
            ident = self._exchange({"apiVersion": API_VERSION, "requestId": new_request_id("hs"), "method": "runtime.handshake",
                                    "params": {"apiVersions": [API_VERSION],
                                               "client": {"name": self.client_name, "version": "0.1.0"}}})
        except RuntimeError_:
            self.close()
            raise
        if ident.get("product") != PRODUCT:
            self.close()
            raise RuntimeError_("instance_mismatch", f"{self.endpoint} is not an AgentDesktop Runtime", "handshake")
        self.identity = ident
        return ident

    def call(self, method: str, params: Optional[dict] = None, *, context: Optional[dict] = None,
             request_id: Optional[str] = None, deadline: Optional[str] = None) -> dict:
        self.handshake()
        req: dict = {"apiVersion": API_VERSION, "requestId": request_id or new_request_id(), "method": method}
        if context:
            req["context"] = context
        if deadline:
            req["deadline"] = deadline
        req["params"] = params or {}
        try:
            return self._exchange(req)
        except RuntimeError_ as e:
            # A write sent without a reply: its outcome is unknown, not "offline".
            if e.code == "connection_lost" and method in _WRITES:
                raise RuntimeError_("request_acceptance_unknown",
                                    f"{e.message}; check with request_show({req['requestId']!r})", "transport",
                                    details={"requestId": req["requestId"]})
            raise

    # -- typed helpers ---------------------------------------------------
    def status(self) -> dict: return self.call("runtime.status")
    def capabilities(self) -> dict: return self.call("runtime.capabilities")
    def desktops(self) -> list: return self.call("desktop.list")["desktops"]

    def create_desktop(self, name: Optional[str] = None, size: Optional[tuple] = None, *, request_id=None) -> dict:
        p: dict = {}
        if name: p["name"] = name
        if size: p["width"], p["height"] = size
        return self.call("desktop.create", p, request_id=request_id)

    def destroy_desktop(self, desktop_id: str, *, request_id=None) -> dict:
        return self.call("desktop.destroy", {"desktopId": desktop_id}, request_id=request_id)

    def launch(self, desktop_id: str, bundle_id: str, *, new_instance=False, request_id=None) -> dict:
        p = {"desktopId": desktop_id, "bundleId": bundle_id}
        if new_instance: p["newInstance"] = True
        return self.call("app.launch", p, request_id=request_id)

    def bind_window(self, desktop_id: str, pid: int, window_id: Optional[int] = None, *, request_id=None) -> dict:
        p = {"desktopId": desktop_id, "pid": pid}
        if window_id: p["windowId"] = window_id
        return self.call("window.bind", p, request_id=request_id)

    def session(self, desktop_id: Optional[str] = None) -> "Session":
        """A Session as a context manager; inside session exec, its own."""
        return Session(self, desktop_id)

    def request_show(self, request_id: str) -> dict: return self.call("request.show", {"requestId": request_id})
    def run_show(self, run_id: str) -> dict: return self.call("run.show", {"runId": run_id})
    def run_cancel(self, run_id: str, *, request_id=None) -> dict:
        return self.call("run.cancel", {"runId": run_id}, request_id=request_id)

    def run_events(self, run_id: str, after: int = 0) -> Iterator[dict]:
        while True:
            page = self.call("run.events", {"runId": run_id, "after": after, "limit": 200})
            yield from page["events"]
            after = page["next"]
            if not page["events"]:
                return

    def _attach(self) -> Optional[str]:
        if not self.context:
            return None
        if not self._attached:
            self.call("run.attach", {"runId": self.context.run_id, "token": self.context.token})
            self._attached = True
        return self.context.run_id


_WRITES = {"desktop.create", "desktop.destroy", "app.launch", "window.bind", "window.unbind",
           "session.open", "session.close", "act", "run.finish", "run.cancel"}


class Session:
    """observe / act / wait on one Session. Opened and closed here unless it
    is the session exec's own."""

    def __init__(self, client: RuntimeClient, desktop_id: Optional[str]):
        self.client, self.desktop_id = client, desktop_id
        self.session_id: Optional[str] = None
        self._owned = False

    def __enter__(self) -> "Session":
        ctx = self.client.context
        if ctx and (self.desktop_id is None or self.desktop_id == ctx.desktop_id):
            self.session_id, self.desktop_id = ctx.session_id, ctx.desktop_id
        else:
            if not self.desktop_id:
                raise RuntimeError_("invalid_argument", "give a desktop_id outside session exec", not_sent=True)
            self.session_id = self.client.call("session.open", {"desktopId": self.desktop_id})["sessionId"]
            self._owned = True
        return self

    def __exit__(self, *exc) -> None:
        if self._owned and self.session_id:
            try:
                self.client.call("session.close", {"sessionId": self.session_id})
            except RuntimeError_:
                pass

    def _ctx(self, act: bool = False) -> dict:
        c = {"sessionId": self.session_id}
        if act and self.client.context and self.client.context.session_id == self.session_id:
            c["runId"] = self.client._attach()
        return c

    def observe(self, *, query: Optional[str] = None, screenshot: bool = True, elements: bool = True) -> dict:
        p: dict = {}
        if query: p["query"] = query
        if not screenshot: p["screenshot"] = False
        if not elements: p["elements"] = False
        return self.client.call("observe", p, context=self._ctx())

    def act(self, snapshot_id: str, action: dict, *, request_id: Optional[str] = None) -> dict:
        return self.client.call("act", {"snapshotId": snapshot_id, "action": action}, context=self._ctx(True),
                                request_id=request_id)

    def click(self, snapshot_id: str, element: Optional[str] = None, image_point: Optional[tuple] = None, **kw) -> dict:
        if (element is None) == (image_point is None):
            raise RuntimeError_("invalid_argument", "give exactly one of element and image_point", not_sent=True)
        target = {"elementRef": element} if element else {"imagePoint": {"x": image_point[0], "y": image_point[1]}}
        return self.act(snapshot_id, {"kind": "click", "target": target}, **kw)

    def type_text(self, snapshot_id: str, text: str, element: Optional[str] = None, **kw) -> dict:
        a: dict = {"kind": "type", "text": text}
        if element: a["target"] = {"elementRef": element}
        return self.act(snapshot_id, a, **kw)

    def key(self, snapshot_id: str, key: str, modifiers: Optional[list] = None, **kw) -> dict:
        a: dict = {"kind": "key", "key": key}
        if modifiers: a["modifiers"] = modifiers
        return self.act(snapshot_id, a, **kw)

    def wait_for(self, *, present: bool = True, role=None, label=None, label_contains=None, timeout_ms: int = 5000) -> dict:
        cond: dict = {"kind": "elementPresent" if present else "elementAbsent"}
        if role: cond["role"] = role
        if label is not None: cond["label"] = label
        if label_contains: cond["labelContains"] = label_contains
        return self.client.call("wait", {"condition": cond, "timeoutMs": timeout_ms}, context=self._ctx())
