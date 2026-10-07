import Foundation

/// The shared model service: one authoritative path for credentials, HTTP,
/// deadline, budget, ledger and usage, used by GUI steps and capability
/// tests alike (spec §06.1, §18.1).
public protocol AiService: Sendable {
    /// Make one bounded call to a fixed candidate. Failures and
    /// cancellations are recorded in the ledger before this throws.
    func infer(_ request: AiInferenceRequest, resolvedModel: AiResolvedModel,
               context: AiCallContext) async throws -> AiInferenceResult
}

/// Durable record of model calls (spec §09.3).
public protocol AiCallLedgerPort: Sendable {
    /// Reserve the attempt before any HTTP request. A failure here stops the
    /// call (AUDIT_UNAVAILABLE) with no network traffic.
    func reserve(context: AiCallContext, target: AiResolvedModel) async throws -> ResourceID
    /// Record the attempt's end: success, failure or cancellation. A
    /// cancellation never erases the row. Finishing the same reservation
    /// twice must not count it twice.
    func finish(_ record: AiCallRecord) async throws
}

/// Resolves a credential identity to its key at call time (spec §04.1,
/// §10.2). Implementations read the system credential store only; they never
/// fall back to environment variables or older config files.
public protocol CredentialResolver: Sendable {
    /// - Throws: CREDENTIAL_REVOKED for a revoked or rotated-away identity,
    ///   CREDENTIAL_REQUIRED when no key is stored for it.
    func resolveKey(credentialIdentity: ResourceID) async throws -> String
}

/// Checks that a call may start and, afterwards, that its result may still
/// be used: run generation, candidate authorization, credential state.
/// The Runtime implements it; the default admits everything.
public protocol AiCallAdmission: Sendable {
    func admit(_ context: AiCallContext, target: AiResolvedModel) async throws
    /// False when the result must be discarded (generation moved on,
    /// credential revoked while in flight).
    func isStillCurrent(_ context: AiCallContext, target: AiResolvedModel) async -> Bool
}

public struct AdmitAll: AiCallAdmission {
    public init() {}
    public func admit(_ context: AiCallContext, target: AiResolvedModel) async throws {}
    public func isStillCurrent(_ context: AiCallContext, target: AiResolvedModel) async -> Bool { true }
}

/// Monotonic time for deadlines and waits, injectable so tests can move
/// time by hand (spec §03.2). Wall time is for records only.
public protocol MonotonicClock: Sendable {
    func nowNanoseconds() -> UInt64
    /// Sleep until the monotonic instant; throws CancellationError when the
    /// task is cancelled.
    func sleep(untilNanoseconds deadline: UInt64) async throws
    func wallNow() -> Date
}

public struct SystemMonotonicClock: MonotonicClock {
    public init() {}
    public func nowNanoseconds() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
    public func sleep(untilNanoseconds deadline: UInt64) async throws {
        let now = nowNanoseconds()
        if deadline > now { try await Task.sleep(nanoseconds: deadline - now) }
        try Task.checkCancellation()
    }
    public func wallNow() -> Date { Date() }
}
