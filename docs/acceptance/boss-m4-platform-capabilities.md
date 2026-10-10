# BOSS M4 platform capability confirmation (#44)

Verified on 2026-10-10. This confirms SDK and Runtime protocol behavior; it is not a substitute for physical-device acceptance (#168).

| Requirement | Python SDK path | Runtime behavior |
| --- | --- | --- |
| Request outcome lookup | `client.request_show(request_id)` | Returns retained accepted/completed/failed/unknown state and outcome. Missing, inaccessible, or pruned history returns `not_found`; this never proves a write did not happen. |
| Cancellation and quiescence | `client.run_cancel(run_id)` then `client.run_show(run_id)` | An accepted cancellation can still be stopping/pending. Stop is confirmed only by `quiescence == "confirmed"`; do not infer it from accepting cancel or losing the connection. |
| Delegated Run | `client.run_start(session_id)` | Returns `run` and `attachToken`. Runtime assigns `external_client` / `connection_scoped`; the helper does not grant ownership or lifetime escalation. |
| Disconnect | Close the Run's owning RuntimeClient connection | Connection loss requests stopping of the delegated Run. In-flight delivery may remain unknown; reconnect and query instead of replaying input. A newly connected client does not silently resume the old Run. |
| MAC-001 target revalidation | `session.observe()` / `session.act(snapshot_id, action)` | Runtime rechecks bound process/window/generation and exposure before input. Moved/covered/invalid targets produce `stale_observation`; a target change during sending produces `action_delivery_unknown`. No automatic targeting of a sibling window. |

Finished request ledger entries have a seven-day retention policy (`RequestLedger.retentionDays`, methods.json transport); pruning runs at Runtime initialization using the accepted timestamp. Do not promise lookup forever, or treat `not_found` after retention as permission to resend. Screenshot artifact retention (24 hours) is a different policy.

`run.start` transport loss now preserves the original requestId and reports `request_acceptance_unknown`. Query it using the same paired principal; do not create a fresh Run as an automatic retry. Session creation requires the paired client's appropriate grants; Run creation requires its run capability.

## Evidence

- Python SDK unit tests: 10 discovered, 9 passed, 1 optional live-endpoint test skipped.
- SDK against an in-process real RuntimeServer plus revocation regressions: 13 passed, including Python and TypeScript live SDK tests. These use a test backend, not a physical application.
- Runtime target identity, Run model, and request/Desktop tests: 40 passed. Cover target movement/occlusion, changed target during sending, delegated disconnect and cancellation/quiescence.
- Physical display approval and real application input remain separate acceptance work; this document does not declare M4 itself passed.
