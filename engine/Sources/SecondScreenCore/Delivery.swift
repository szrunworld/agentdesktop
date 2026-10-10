import ApplicationServices
import Foundation

/// What an input did, as the execution path itself records it (#173, Kevin
/// 2026-10-09), never inferred from an error's text.
public enum DeliveryState: String, Codable, Sendable {
    /// Evidence that nothing with an outside effect was done: no event was
    /// posted, no write or press was asked, or the one asked was refused.
    case notPerformed
    /// At least one event, press or write was submitted to the system's
    /// input interface. Not a confirmation that the app did anything.
    case submitted
    /// Whether anything was submitted or done cannot be told (a press or
    /// write with no clear answer).
    case unknown

    var rank: Int {
        switch self {
        case .notPerformed: 0
        case .submitted: 1
        case .unknown: 2
        }
    }
}

/// Records one input request's delivery. It only moves one way
/// (not performed → submitted → unknown), so once anything was submitted a
/// later failure, in the same request, cannot make it read as not
/// performed: "click, then type, then Enter" stays submitted when the
/// typing fails before its first character.
public final class DeliveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var current: DeliveryState = .notPerformed

    public init() {}

    public var state: DeliveryState { lock.withLock { current } }

    public func note(_ state: DeliveryState) {
        lock.withLock { if state.rank > current.rank { current = state } }
    }

    /// The recorder of the input request running now (AgentRuntime sets it).
    @TaskLocal public static var active: DeliveryRecorder?

    /// Call right before handing anything with an outside effect to the
    /// system: an event, a focus or front change, a pointer move.
    public static func submitting() { active?.note(.submitted) }

    /// What a press or write through accessibility proved.
    public static func noteAX(_ outcome: AXActions.PressOutcome) {
        switch outcome {
        case .pressed: active?.note(.submitted)
        case .unknown: active?.note(.unknown)
        case .notPerformed: break
        }
    }
}

extension AXActions {
    /// What an AXUIElementSetAttributeValue result proves: done, refused
    /// before acting (the attribute cannot be set), or not clear.
    public static func writeOutcome(_ result: AXError) -> PressOutcome {
        switch result {
        case .success: return .pressed
        case .attributeUnsupported, .illegalArgument, .notImplemented, .apiDisabled, .actionUnsupported:
            return .notPerformed
        default:
            return .unknown
        }
    }

    /// Set an attribute and record what it proved.
    @discardableResult
    public static func write(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) -> AXError {
        let result = AXUIElementSetAttributeValue(element, attribute as CFString, value)
        DeliveryRecorder.noteAX(writeOutcome(result))
        return result
    }
}
