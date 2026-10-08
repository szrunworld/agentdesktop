import Foundation

/// What the client can say about whether a request reached the device.
///
/// The client never claims an effect happened on screen. `accepted` only
/// means WDA answered the request with success; whether the phone shows the
/// expected result is for the Runtime to verify with a fresh observation.
public enum WDADeliveryState: String, Sendable, Codable, Equatable {
    /// The request was not sent (deadline already passed, runner refused
    /// the connection, invalid argument caught locally).
    case notSent
    /// WDA answered with an error that means the command did not run
    /// (invalid session, no such element, unknown route, invalid argument).
    case rejected
    /// WDA answered with success.
    case accepted
    /// The request may have run: timeout or connection lost after sending,
    /// or a WDA error raised mid-command. Never replay automatically.
    case unknown
}

/// The client has no way to confirm on-screen effects; every result says so.
public enum WDAEffectStatus: String, Sendable, Codable, Equatable {
    case notVerifiedByClient = "not_verified_by_client"
}

/// Error categories a caller can branch on.
public enum WDAErrorKind: String, Sendable, Codable, Equatable {
    /// No HTTP answer from the runner (refused, host not found, dropped).
    case runnerUnreachable
    /// The WDA session is gone; the client drops it and creates a new one
    /// on the next call.
    case sessionInvalid
    /// The locator matched nothing, or the element went stale.
    case elementNotFound
    /// The request or the caller's deadline ran out.
    case timeout
    /// The runner does not serve this route (older/newer WDA).
    case unsupportedEndpoint
    /// The arguments were refused, locally or by WDA.
    case invalidArgument
    /// Any other WDA error answer.
    case wdaRejected
    /// The answer was not the JSON shape WDA documents.
    case invalidResponse
}

public struct WDAError: Error, Sendable, Equatable, CustomStringConvertible {
    public let kind: WDAErrorKind
    public let delivery: WDADeliveryState
    /// `METHOD /path` of the failing request.
    public let endpoint: String
    public let httpStatus: Int?
    /// The W3C `error` code or legacy status, when WDA sent one.
    public let wdaErrorCode: String?
    public let message: String

    public init(kind: WDAErrorKind, delivery: WDADeliveryState, endpoint: String,
                httpStatus: Int? = nil, wdaErrorCode: String? = nil, message: String) {
        self.kind = kind
        self.delivery = delivery
        self.endpoint = endpoint
        self.httpStatus = httpStatus
        self.wdaErrorCode = wdaErrorCode
        self.message = message
    }

    public var description: String {
        var parts = ["WDA \(kind.rawValue) [\(delivery.rawValue)] \(endpoint)"]
        if let httpStatus { parts.append("http=\(httpStatus)") }
        if let wdaErrorCode { parts.append("error=\(wdaErrorCode)") }
        parts.append(message)
        return parts.joined(separator: " ")
    }
}

/// Evidence for one input command WDA accepted. Handed to the Runtime,
/// which alone writes the formal ActionReceipt.
public struct WDAActionEvidence: Sendable, Codable, Equatable {
    public let requestId: UUID
    /// Logical operation: `tap`, `swipe`, `drag`, `longPress`, `typeText`,
    /// `launchApp`, `home`, `clickElement`.
    public let operation: String
    public let endpoint: String
    public let sessionId: String?
    public let delivery: WDADeliveryState
    public let effect: WDAEffectStatus
    public let httpStatus: Int
    public let sentAt: Date
    public let answeredAt: Date
}
