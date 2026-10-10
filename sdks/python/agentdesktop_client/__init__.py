"""Thin Python client for the AgentDesktop Runtime API (agentdesktop.runtime/1).

It connects, confirms who answered, and carries requests. Every rule —
scope, leases, snapshot checks, the request ledger, stopping — is enforced
by the Runtime, never here. See contracts/runtime/v1 in the repository.
"""

from .client import (
    API_VERSION,
    ExecContext,
    RuntimeClient,
    RuntimeError_,
    Session,
    load_credential,
    resolve_endpoint,
    save_credential,
)

__all__ = ["API_VERSION", "ExecContext", "RuntimeClient", "RuntimeError_", "Session", "load_credential", "resolve_endpoint",
           "save_credential"]
