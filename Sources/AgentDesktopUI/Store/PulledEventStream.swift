import AgentDesktopProtocol
import Foundation

/// The stream `RuntimePort.subscribe` returns, built over a subscription
/// whose frames are taken rather than delivered: in process, a connection
/// subscribed with `events.subscribe` holds its frames until
/// `RuntimeService.pendingEventFrames` takes them, exactly as the socket
/// server's push loop does every 200 ms (docs/plan/10 §1.6).
///
/// `pull` returns the frames due now (empty: nothing new), or nil when the
/// subscription has ended (access withdrawn, a Run's own stream drained);
/// a thrown error ends the stream with it. When nothing was due the stream
/// waits `intervalMs` before taking again; frames that arrive together are
/// handed on at once. When the reader stops (the Store stops or the window
/// closes) the taking stops and `close` runs once, which unsubscribes; it
/// never stops a Run (ADR-02).
public enum PulledEventStream {
    public static func make(intervalMs: Int = 200, clock: PollClock = SystemPollClock(),
                            pull: @escaping @Sendable () async throws -> [JSONValue]?,
                            close: @escaping @Sendable () -> Void) -> AsyncThrowingStream<JSONValue, Error> {
        let (stream, continuation) = AsyncThrowingStream<JSONValue, Error>.makeStream()
        let closer = Once(close)
        let task = Task {
            do {
                while !Task.isCancelled {
                    guard let frames = try await pull() else { break }
                    for f in frames { continuation.yield(f) }
                    if frames.isEmpty { try await clock.pause(milliseconds: intervalMs) }
                }
                continuation.finish()
            } catch is CancellationError {
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
            closer.run()
        }
        continuation.onTermination = { _ in
            task.cancel()
            closer.run()
        }
        return stream
    }

    /// Runs its action at most once, from whichever side ends first.
    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var action: (@Sendable () -> Void)?

        init(_ action: @escaping @Sendable () -> Void) { self.action = action }

        func run() {
            let a: (@Sendable () -> Void)? = lock.withLock {
                defer { action = nil }
                return action
            }
            a?()
        }
    }
}
