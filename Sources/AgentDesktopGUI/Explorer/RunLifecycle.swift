import AgentDesktopContracts
import Foundation

/// The state machine of one GUI run (spec §07.1–07.2), kept apart from the
/// explorer loop so every transition is a compare-and-set on the run's
/// generation and can be tested without a model or a desktop.
///
/// Rules it enforces:
/// - Only the edges of §07.1; terminal states never change.
/// - Work started under generation G is void once the generation moves on;
///   `cancel` moves it immediately and before anything else.
/// - The binding's initial generation never changes.
/// - An input whose outcome is unknown keeps its conflict domain quarantined
///   until the Runtime reconciles it; nothing here resends it, and there is
///   no resume.
public actor RunLifecycle {
    public enum State: String, CaseIterable, Sendable {
        case queued, observing, inferencing, validating, executing, verifying
        case waitingUser = "waiting_user"
        case cancelling, succeeded, failed, cancelled

        public var isTerminal: Bool { self == .succeeded || self == .failed || self == .cancelled }
    }

    public enum Delivery: String, Sendable {
        case notSent = "not_sent", submitted, confirmed, unknown, rejected
    }

    public struct Event: Equatable, Sendable {
        public enum Kind: String, Sendable { case stateChanged = "state_changed", cancelRequested = "cancel_requested", waitingUser = "waiting_user" }
        public let sequence: Int
        public let kind: Kind
        public let state: State
        public let generation: UInt64
        public let summary: String
    }

    public struct CancelReceipt: Equatable, Sendable {
        public let accepted: Bool
        public let state: State
        public var terminal: Bool { state.isTerminal }
    }

    /// Edges of §07.1, excluding cancelling (reachable from every
    /// non-terminal state through `requestCancel`).
    static let edges: [State: Set<State>] = [
        .queued: [.observing, .failed],
        .observing: [.inferencing, .verifying, .failed],
        .inferencing: [.validating, .waitingUser, .failed],
        .validating: [.executing, .observing, .verifying, .waitingUser, .failed],
        .executing: [.observing, .verifying, .waitingUser, .failed],
        .verifying: [.succeeded, .observing, .waitingUser, .failed],
        .waitingUser: [],
        .cancelling: [],
    ]

    public static let maxEvents = 100_000

    public let runId: String
    public let initialGeneration: UInt64
    public private(set) var state: State = .queued
    public private(set) var currentGeneration: UInt64
    public private(set) var cancelRequested = false
    public private(set) var waitingReasonCode: String?
    public private(set) var failure: ContractError?
    /// The action handed to the executor and not yet resolved.
    public private(set) var inFlightActionId: String?
    /// Set while an unknown outcome holds the conflict domain.
    public private(set) var quarantinedActionId: String?
    public private(set) var events: [Event] = []

    public init(runId: String, initialGeneration: UInt64 = 1) {
        precondition(initialGeneration >= 1)
        self.runId = runId
        self.initialGeneration = initialGeneration
        self.currentGeneration = initialGeneration
    }

    /// Whether work started under `generation` may still take a new step
    /// (a model call, an input, a timer). False after cancel, on a newer
    /// generation, in a terminal state, or while an outcome is unknown.
    public func mayProceed(generation: UInt64) -> Bool {
        generation == currentGeneration && !cancelRequested && !state.isTerminal
            && quarantinedActionId == nil && state != .waitingUser
    }

    /// Move to `next` if the caller still holds the current generation.
    public func transition(to next: State, generation: UInt64, summary: String) throws {
        guard !state.isTerminal else {
            throw ContractError(.staleGeneration, "run already ended as \(state.rawValue)")
        }
        guard generation == currentGeneration else {
            throw ContractError(.staleGeneration, "generation \(generation) is no longer current")
        }
        guard next != .cancelling, next != .cancelled, Self.edges[state]?.contains(next) == true else {
            throw ContractError(.internalError, "no transition \(state.rawValue) → \(next.rawValue)")
        }
        if next == .succeeded || next == .failed {
            guard inFlightActionId == nil, quarantinedActionId == nil else {
                throw ContractError(.internalError, "an input is still unresolved")
            }
        }
        set(next, summary)
    }

    public func fail(_ error: ContractError, generation: UInt64) throws {
        try transition(to: .failed, generation: generation, summary: error.code.rawValue)
        failure = error
    }

    /// Cancel: void the current generation first, then report. Accepting a
    /// cancel is not being cancelled; with an input in flight the run stays
    /// cancelling until the executor resolves it.
    public func requestCancel() -> CancelReceipt {
        switch state {
        case .cancelled:
            return CancelReceipt(accepted: true, state: .cancelled)
        case .succeeded, .failed:
            return CancelReceipt(accepted: false, state: state)
        default:
            break
        }
        if cancelRequested { return CancelReceipt(accepted: true, state: state) }
        cancelRequested = true
        currentGeneration += 1
        append(.cancelRequested, "cancel requested")
        set(.cancelling, "cancelling")
        if quarantinedActionId != nil {
            waitingReasonCode = ErrorCode.actionOutcomeUnknown.rawValue
        } else if inFlightActionId == nil {
            set(.cancelled, "cancelled")
        }
        return CancelReceipt(accepted: true, state: state)
    }

    /// The executor took an action for this run. Refused once the
    /// generation moved on, so a late proposal never becomes input.
    public func actionStarted(_ actionId: String, generation: UInt64) throws {
        guard mayProceed(generation: generation), state == .executing else {
            throw ContractError(.staleGeneration, "the run no longer accepts input")
        }
        guard inFlightActionId == nil else {
            throw ContractError(.internalError, "one input at a time per run")
        }
        inFlightActionId = actionId
    }

    /// The executor's verdict on the in-flight action.
    public func actionResolved(_ actionId: String, delivery: Delivery) throws {
        guard inFlightActionId == actionId else {
            throw ContractError(.internalError, "unknown action \(actionId)")
        }
        inFlightActionId = nil
        switch delivery {
        case .unknown, .submitted:
            quarantinedActionId = actionId
            waitingReasonCode = ErrorCode.actionOutcomeUnknown.rawValue
            if state == .cancelling {
                append(.waitingUser, "cancel waits for an input whose outcome is unknown")
            } else {
                set(.waitingUser, "input outcome unknown")
                append(.waitingUser, ErrorCode.actionOutcomeUnknown.rawValue)
            }
        case .confirmed, .notSent, .rejected:
            if state == .cancelling { set(.cancelled, "cancelled") }
        }
    }

    /// A model or the run asks for a person (needs_user).
    public func waitForUser(reasonCode: String, generation: UInt64) throws {
        try transition(to: .waitingUser, generation: generation, summary: reasonCode)
        waitingReasonCode = reasonCode
        append(.waitingUser, reasonCode)
    }

    /// The Runtime's existing reconciliation proved the quarantined input's
    /// effect and released its domain. The run ends; it never resumes.
    public func reconciled(actionId: String) throws {
        guard quarantinedActionId == actionId else {
            throw ContractError(.internalError, "no quarantined action \(actionId)")
        }
        quarantinedActionId = nil
        if cancelRequested {
            waitingReasonCode = nil
            set(.cancelled, "cancelled after reconciliation")
        } else {
            failure = ContractError(.actionOutcomeUnknown, "an input's outcome had to be reconciled")
            set(.failed, "ended after reconciliation")
        }
    }

    private func set(_ next: State, _ summary: String) {
        state = next
        append(.stateChanged, summary)
    }

    private func append(_ kind: Event.Kind, _ summary: String) {
        guard events.count < Self.maxEvents else { return }
        events.append(Event(sequence: events.count + 1, kind: kind, state: state,
                            generation: currentGeneration, summary: summary))
    }
}
