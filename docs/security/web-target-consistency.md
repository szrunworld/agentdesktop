# Web element target consistency (#165)

For coordinate actions naming a web element (click, hover, scroll, or nonreplacement typing), the engine checks before sending input:

1. Both the cached and freshly captured accessibility trees are complete, and their rendered content is identical.
2. The element at the observed index still has the same live accessibility identity and geometry. A moved element requires a fresh observation; the engine does not silently retarget it.
3. A system accessibility hit test at the observed center resolves to that exact element. Missing accessibility, a covered target, a child hit target, or a background window that cannot be hit-tested is refused conservatively.
4. Explicit coordinates accompanying an element reference must equal its observed center.

If any check fails, no input is sent. Reobserve and choose the intended target again. Native AX actions retain their existing routes. Raw coordinate actions without an element reference do not carry an element identity guarantee.

## Residual risks and validation limits

The accessibility tree is not a DOM transaction or pixel snapshot. A change not exposed by accessibility may remain invisible. Capture, geometry queries, hit testing, and event delivery are separate operations: the page can still change after the final check. This reduces stale target delivery but does not establish atomic observation-to-input consistency. Existing window authorization and overlay checks remain necessary.

Regression tests cover the evidence gate for scroll, relayout, removal, covering, content change, incomplete trees, and unchanged evidence. These are injected evidence tests, not a claim of real Chromium/Electron acceptance. Strict identity matching can refuse legitimate child hit targets; it does not fall back to cached coordinates.
