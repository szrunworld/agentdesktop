#!/usr/bin/env python3
"""A neutral example agent for AgentDesktop (A7).

It belongs to no product: it shows the whole life of an external agent
through the Python SDK, printing a receipt for every step:

    pair -> wait for the owner -> list Desktops -> observe -> act
         -> disconnect -> reconnect

Refusals that only the user can lift (pairing_required, permission_denied,
grant_missing, ...) are explained and end the run; an action is never
retried. By default it sends no input at all: an action happens only when
--act names one. See README.md.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Optional

# Run from a checkout without installing the SDK.
_SDK = Path(__file__).resolve().parents[2] / "sdks" / "python"
if _SDK.is_dir() and str(_SDK) not in sys.path:
    sys.path.insert(0, str(_SDK))

from agentdesktop_client import RuntimeClient, RuntimeError_, load_credential, save_credential  # noqa: E402

# What only the user (in the Agent Desktop window) can change. The agent
# says so and stops; retrying would only ask again or act without consent.
HINTS = {
    "pairing_required": "这个 Agent 还没有配对。去掉 --no-pair 重新运行，并在 Agent Desktop 窗口里核对配对码后批准。",
    "permission_denied": "被拒绝：配对请求被拒绝或已过期，或这项操作只有 AgentDesktop 的主人能做。请在 Agent Desktop 窗口里查看。",
    "grant_missing": "授权里没有这项能力、这个 Desktop 或这个 App。请在 Agent Desktop 窗口里修改这个 Agent 的授权。",
    "grant_expired": "授权已过期。请在 Agent Desktop 窗口里续期。",
    "client_revoked": "这个 Agent 已被移除，旧凭据永久失效。删除凭据文件后重新配对。",
    "runtime_offline": "没有找到正在运行的 AgentDesktop Runtime。先启动 Agent Desktop，或用 --endpoint 指向测试副本。",
}
# The process ends with this status after a refusal the user must resolve.
EXIT_REFUSED = 3
EXIT_FAILED = 1


def receipt(step: str, data) -> None:
    """One line per step: what happened, as the Runtime answered it."""
    print(f"[{step}] " + json.dumps(data, ensure_ascii=False, sort_keys=True), flush=True)


def explain(step: str, e: RuntimeError_) -> int:
    out = {"code": e.code, "message": e.message, "phase": e.phase}
    if e.not_sent is not None:
        out["notSent"] = e.not_sent
    if e.details:
        out["details"] = e.details
    receipt(step + ":error", out)
    hint = HINTS.get(e.code)
    if hint:
        print(f"  -> {hint}", file=sys.stderr, flush=True)
        return EXIT_REFUSED
    if e.code == "request_acceptance_unknown":
        print(f"  -> 不确定动作是否生效。不要重试；用 request.show 查询 {e.details.get('requestId')}。", file=sys.stderr, flush=True)
    return EXIT_FAILED


def parse_action(text: Optional[str]) -> Optional[dict]:
    """--act key:escape | click:el_3 | press:el_3"""
    if not text:
        return None
    kind, _, arg = text.partition(":")
    if not arg:
        raise SystemExit(f"--act 需要 kind:value，例如 key:escape 或 click:el_3，收到 {text!r}")
    if kind == "key":
        return {"kind": "key", "key": arg}
    if kind in ("click", "press"):
        return {"kind": kind, "target": {"elementRef": arg}}
    raise SystemExit(f"--act 只支持 key、click、press，收到 {kind!r}")


def credential_for(args, step_client) -> dict:
    """The saved credential, or a new one from pairing (saved 0600)."""
    path = args.credential_file
    if os.path.exists(path):
        cred = load_credential(path)
        receipt("credential", {"source": "file", "path": path, "clientId": cred["clientId"]})
        return cred
    if args.no_pair:
        raise RuntimeError_("pairing_required", f"no credential at {path} and --no-pair was given", "local", not_sent=True)

    def on_code(code: str, pairing_id: str) -> None:
        receipt("pair.start", {"pairingId": pairing_id, "shortCode": code})
        print(f"  -> 请在 Agent Desktop 窗口里核对配对码 {code} 并批准（最多等 {int(args.pair_timeout)} 秒）。", file=sys.stderr, flush=True)

    caps = [c for c in args.capabilities.split(",") if c]
    desktops = [d for d in args.desktops.split(",") if d]
    cred = step_client.pair(args.name, caps, desktops=desktops, apps=[a for a in args.apps.split(",") if a],
                            publisher=args.publisher, timeout=args.pair_timeout, on_code=on_code, poll=args.poll)
    save_credential(cred, path)
    receipt("pair.approved", {"clientId": cred["clientId"], "savedTo": path, "mode": "0600"})
    return cred


def run(args) -> int:
    action = parse_action(args.act)
    endpoint = args.endpoint

    # 1. Handshake unpaired: who answered, before anything else is sent.
    anon = RuntimeClient(endpoint, env={}, client_name=args.name, timeout=args.timeout)
    try:
        ident = anon.handshake()
        receipt("handshake", {"product": ident.get("product"), "apiVersion": ident.get("apiVersion"),
                              "instanceId": ident.get("instanceId"), "principal": ident.get("principal")})
        # 2. Pair (or reuse the saved credential) and wait for the owner.
        cred = credential_for(args, anon)
    except RuntimeError_ as e:
        return explain("pair", e)
    finally:
        anon.close()

    # 3. As the paired app: list Desktops.
    client = RuntimeClient(endpoint, env={}, client_name=args.name, timeout=args.timeout, credential=cred)
    try:
        ident = client.handshake()
        receipt("connect", {"clientId": cred["clientId"], "principal": ident.get("principal")})
        desktops = client.desktops()
        receipt("desktops", [{"desktopId": d.get("desktopId"), "name": d.get("name"), "state": d.get("state")} for d in desktops])
        if args.list_only:
            client.close()
            receipt("disconnect", {"reason": "--list-only"})
            return reconnect(args, cred)
        ids = [d.get("desktopId") for d in desktops]
        desktop = args.desktop_id or (ids[0] if ids else None)
        if desktop is None:
            receipt("observe:skipped", {"reason": "the grant covers no Desktop yet"})
            print("  -> 授权里还没有可见的 Desktop。请在 Agent Desktop 窗口里给这个 Agent 授权一个 Desktop。", file=sys.stderr)
            client.close()
            receipt("disconnect", {"reason": "nothing to observe"})
            return reconnect(args, cred)
        if desktop not in ids:
            raise RuntimeError_("grant_missing", f"desktop {desktop} is not among the Desktops this grant shows", "local",
                                not_sent=True, details={"desktopId": desktop})

        # 4-5. Observe, then (only when asked) one action against that snapshot.
        with client.session(desktop) as s:
            receipt("session.open", {"desktopId": desktop, "sessionId": s.session_id})
            o = s.observe(screenshot=False)
            elements = o.get("elements") or []
            receipt("observe", {"snapshotId": o.get("snapshotId"), "elements": len(elements),
                                "sample": [{"id": e.get("id"), "role": e.get("role"), "label": e.get("label")} for e in elements[:5]]})
            if action is None:
                receipt("act:skipped", {"reason": "no --act given; no input was sent"})
            else:
                # One attempt only: a refused or unclear action is reported, never retried.
                r = s.act(o["snapshotId"], action, request_id=args.request_id)
                receipt("act", {k: r.get(k) for k in ("receiptId", "runId", "delivery", "requestId", "reason") if k in r})
    except RuntimeError_ as e:
        client.close()
        return explain("run", e)

    # 6. Disconnect: whatever this connection started stops with it.
    client.close()
    receipt("disconnect", {"clientId": cred["clientId"]})
    return reconnect(args, cred)


def reconnect(args, cred: dict) -> int:
    """7. A new connection with the same credential is the same app."""
    again = RuntimeClient(args.endpoint, env={}, client_name=args.name, timeout=args.timeout, credential=cred)
    try:
        ident = again.handshake()
        same = (ident.get("principal") or {}).get("clientId", cred["clientId"]) == cred["clientId"]
        receipt("reconnect", {"clientId": cred["clientId"], "sameClient": same, "desktops": len(again.desktops())})
        return 0
    except RuntimeError_ as e:
        return explain("reconnect", e)
    finally:
        again.close()


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description="中性示例 Agent：配对、列 Desktop、观察、动作、断开、重连")
    p.add_argument("--endpoint", help="Runtime socket；默认 AGENTDESKTOP_SOCKET / AGENTDESKTOP_ENDPOINT，再默认已安装产品的")
    p.add_argument("--credential-file", default="neutral-agent.credential.json", help="凭据文件（0600）；没有就先配对")
    p.add_argument("--name", default="neutral-agent", help="配对时显示的 Agent 名")
    p.add_argument("--publisher", default=None)
    p.add_argument("--capabilities", default="observe,act", help="配对请求的能力，逗号分隔")
    p.add_argument("--desktops", default="", help="配对请求的 Desktop，逗号分隔（如 created 或 d_123）")
    p.add_argument("--apps", default="", help="配对请求的 App bundle id，逗号分隔")
    p.add_argument("--desktop-id", help="观察哪个 Desktop；默认授权里的第一个")
    p.add_argument("--act", help="可选的一个动作：key:escape、click:el_3、press:el_3。不给就不发任何输入")
    p.add_argument("--request-id", help="动作的 requestId（不确定是否生效时用它查询，不要重发）")
    p.add_argument("--list-only", action="store_true", help="只握手和列 Desktop（测试副本上的只读检查）")
    p.add_argument("--no-pair", action="store_true", help="没有凭据时不发起配对，直接报 pairing_required")
    p.add_argument("--pair-timeout", type=float, default=600.0)
    p.add_argument("--poll", type=float, default=1.0)
    p.add_argument("--timeout", type=float, default=10.0)
    args = p.parse_args(argv)
    if not args.endpoint:
        args.endpoint = os.environ.get("AGENTDESKTOP_SOCKET") or None
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
