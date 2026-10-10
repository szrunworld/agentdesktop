import AgentDesktopClient
import AgentDesktopProtocol
import Foundation

/// Which connection a `RuntimeClient` is made for. The control connection
/// submits and cancels, so the Runtime ties this editor's Delegated Runs to
/// it; an events connection controls no Run (runtime-api-v1-freeze §4).
public enum ACPBridgeConnectionRole: Sendable {
    case control
    case events
}

/// Makes a fresh, not yet connected `RuntimeClient`. Production passes a
/// `SocketRuntimeClient` for the resolved endpoint; tests pass a fake.
public typealias ACPBridgeClientFactory = @Sendable (ACPBridgeConnectionRole) -> RuntimeClient

public struct ACPBridgeConfiguration: Sendable {
    /// Upper bound on one blocking Runtime call, seen from async code. The
    /// client's own socket timeout normally ends a call first.
    public var callTimeout: Double = 20
    /// Pause between `run.events` polls when the Runtime cannot push.
    public var pollInterval: Double = 0.3
    /// Consecutive stream reconnects without progress before giving up.
    public var maxReconnects: Int = 3
    /// The uid the Runtime authenticates this process as (getpeereid). Never
    /// taken from the editor.
    public var uid: UInt32 = getuid()

    public init() {}

    /// The production client for `endpoint`: short receive timeout on event
    /// connections so a stopped stream notices quickly.
    /// `credential`: the ACP bridge is a paired client of the Runtime (A4);
    /// without one it can only learn that it must pair.
    public static func socketFactory(endpoint: Endpoint, info: ClientInfo = ClientInfo(name: "agentdesktop-acp", version: RuntimeAPI.productVersion),
                                     timeout: Double = 10, credential: ClientCredential? = nil) -> ACPBridgeClientFactory {
        { role in
            SocketRuntimeClient(endpoint: endpoint, info: info, timeout: role == .control ? timeout : 1, credential: credential)
        }
    }
}

/// A call that did not come back within `callTimeout`.
struct ACPBridgeTimeout: Error {}

/// Resumes a continuation at most once (call result vs. timeout).
final class ACPBridgeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Runs blocking `RuntimeClient` work on one serial dispatch queue, never on
/// the cooperative pool, and bounds how long an async caller waits. A job
/// that outlives its timeout keeps running to completion on the queue (the
/// client's socket timeout ends it); only the caller stops waiting.
///
/// The timeout is armed on a timer queue of its own, never on the job queue
/// (which the blocked call occupies) nor on a global queue (which other
/// blocking work can saturate), so it fires on time. What it cannot speed up
/// is the caller's own resumption: an `await` continues on the Swift
/// cooperative pool, and when other code blocks every thread of that pool
/// the caller resumes late. Measured 2026-10-08 under the full suite: the
/// timer fired at 0.105 s every run, the caller resumed after 0.87–1.40 s.
/// Nothing in this bridge blocks the pool.
final class ACPBridgeExecutor: @unchecked Sendable {
    private let queue: DispatchQueue
    /// A serial (overcommitting) queue of its own, so a timeout fires even
    /// when the shared global pool is saturated.
    private static let timers = DispatchQueue(label: "acp.bridge.timeouts", qos: .userInitiated)

    /// Test hook: called on the timer queue when a timeout fires.
    var onTimeout: ((Date) -> Void)?

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    func run<T>(timeout: Double, _ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            let once = ACPBridgeOnce()
            queue.async {
                let r = Result { try body() }
                if once.claim() { cont.resume(with: r) }
            }
            Self.timers.asyncAfter(deadline: .now() + timeout) {
                if once.claim() {
                    self.onTimeout?(Date())
                    cont.resume(throwing: ACPBridgeTimeout())
                }
            }
        }
    }
}

/// How Runtime failures reach the ACP server: an `ACPError` whose `reason`
/// is the runtime/1 error code. Callers treat any error from `pending`,
/// `decide` or `answer` as "no approval" (README §4 rule 4).
public enum ACPBridgeErrors {
    /// JSON-RPC server error range; the `reason` carries the stable code.
    public static let runtimeErrorCode = -32000

    public static func capabilityMissing(_ what: String) -> ACPError {
        ACPError(code: runtimeErrorCode, reason: "capability_missing", message: what)
    }

    public static let connectionLost = ACPError(
        code: runtimeErrorCode, reason: "connection_lost",
        message: "the editor's control connection is gone; this bridge accepts no further Runtime work")

    public static func map(_ error: Error) -> ACPError {
        switch error {
        case let e as ACPError: return e
        case let e as RuntimeError: return ACPError(code: runtimeErrorCode, reason: e.code, message: e.message)
        case is ACPBridgeTimeout:
            return ACPError(code: runtimeErrorCode, reason: "runtime_timeout", message: "the Runtime did not answer in time")
        default:
            return ACPError(code: runtimeErrorCode, reason: "internal_error", message: "\(error)")
        }
    }
}
