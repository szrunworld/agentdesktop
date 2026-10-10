# Read-only observation stream v1 (#108)

Probe runtime.capabilities.liveObservation.version == 1 and observe.subscribe in the method list. Open a separate read-only connection with the same paired principal; use context.desktopId or its own sessionId, never runId. A connection owning or joining a live Run cannot subscribe.

observe.subscribe params: fps integer 1–2 (default 1), maxWidth integer 1–1920 (default 1280), optional global region. The response includes subscriptionId, version, fps and maxWidth. After it, the socket pushes ObservationFrame lines: type=observation.frame, subscriptionId, sequence and status. ready includes frame.image, frame.screen, frame.target and frame.capturedAt; paused includes the exact Runtime error. There are no actionable snapshotId or element references in these frames.

The Runtime schedules frames on monotonic time, skips missed deadlines and never catches up by bursting. The image is proportionally resized by region observation v1. Artifacts are always transient for at most 120 seconds and remain subject to the original grant expiry/revocation. Fetch artifact.read on a second connection of the same principal. The subscribed connection accepts only observe.unsubscribe; closing it also ends the view.

## Control and failure behavior

No Run, control lease, input request, element read or stored action snapshot is created. Watching does not change the executor's ownership, phase or quiescence, and does not evict its observations. Closing a viewer does not stop an execution Run on another connection.

Capture still uses the existing per-Desktop synchronization and target authorization checks. An in-progress action can delay or pause a frame; frame capture has a 500 ms synchronization deadline. Error codes remain explicit, including deadline_exceeded, stale_observation, grant_missing, quota_exceeded and disk_low. A pause never authorizes input or retries an action. Synchronous platform screenshot/conversion itself is not forcibly cancellable; frames can take longer under system load, and the stated FPS is a maximum rather than a delivery guarantee.

Every frame rechecks current principal/Desktop/app/window access. Permission withdrawal sends no subsequent image; whole-principal revocation closes the stream. Pauses may continue after window invalidation so the client can show a precise waiting state. No changes to the frozen EventFrame or observe parameters are required; ObservationFrame is a separate additive frame schema.

Swift SocketRuntimeClient.call(observeSubscribe) selects ObservationFrame validation for nextEvent(), and skips queued frames while waiting for unsubscribe's reply. Existing EventFrame subscriptions retain their behavior. Python RuntimeClient.observation_frames(desktop_id, fps=1, max_width=1280, region=None) reads these frames on a dedicated connection. Close the iterator to close the view; use a second RuntimeClient with the same credential for artifact.read. The helper validates subscription identity and monotonic sequence and never creates or retries a Run.
