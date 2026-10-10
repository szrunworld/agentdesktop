# Binding recovery v1

Probe `runtime.capabilities.bindingRecovery.version == 1` before use.
`desktop.bindingStatus {desktopId}` returns unbound, valid, blocked, invalid,
or needs_authorization with a reason. A former grantee gets no window identity
or activity after its window grant ends; an owner can inspect invalid bindings.

`desktop.recoverBinding` takes the same parameters as `hub.windows.request`.
It requests a new independent window grant and, after the user's trusted
confirmation and authentication, applies the replacement binding itself.
The confirmation explicitly names the old window, generation and replacement.
No business-side `window.bind` call is needed. Generation advances and old
references are invalidated. An audit event records the rebound; the existing
audit store is best effort and is not a transactional durable guarantee.

Recovery is conservative: a physical Desktop, this client's former window
grant, the same verified process launch, the old window absent, and exactly
one eligible replacement already on the display. Stop the Run and confirm
quiescence first. The binding, window list, process and control lease are
checked again after confirmation. Denial or a changed target preserves the
old binding. No input or window movement is performed. Process restarts,
ambiguous windows and virtual Desktops require explicit ordinary rebinding.

Clients should display needs_authorization as waiting for user confirmation,
not silently resume execution. Neither this extension nor unit tests constitute
physical login acceptance. Existing physical-Desktop enablement gates remain.
