import Foundation

/// How to reach one WebDriverAgent runner on one iPhone.
///
/// The client talks to a runner that is already started (by Xcode,
/// `xcodebuild test-without-building`, or an Appium helper) and reachable
/// over HTTP, normally through a forwarded port such as
/// `iproxy 8100 8100`. Starting, signing and forwarding the runner are not
/// this client's job; see docs/ios/wda-readiness.md.
public struct WDAConfiguration: Sendable, Equatable {
    /// Runner base URL, e.g. `http://127.0.0.1:8100`.
    public var baseURL: URL
    /// Upper bound for one HTTP request. A call's deadline can shorten it,
    /// never lengthen it.
    public var requestTimeout: Duration
    /// Upper bound for `POST /session`, which can be slow on a cold runner.
    public var sessionCreateTimeout: Duration
    /// The device UDID as known to whoever started the runner. WDA's
    /// `/status` does not report a UDID, so without this the probe can only
    /// give a runner-reported identity with low confidence.
    public var deviceUDID: String?
    /// Extra W3C `alwaysMatch` capabilities for `POST /session`
    /// (e.g. `bundleId`). Values must be JSON-compatible.
    public var sessionCapabilities: [String: WDAJSONValue]
    /// Adopt a session the runner already holds (reported by `/status`)
    /// instead of creating one. Off by default: another client may own it.
    public var adoptRunnerSession: Bool

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:8100")!,
        requestTimeout: Duration = .seconds(30),
        sessionCreateTimeout: Duration = .seconds(60),
        deviceUDID: String? = nil,
        sessionCapabilities: [String: WDAJSONValue] = [:],
        adoptRunnerSession: Bool = false
    ) {
        self.baseURL = baseURL
        self.requestTimeout = requestTimeout
        self.sessionCreateTimeout = sessionCreateTimeout
        self.deviceUDID = deviceUDID
        self.sessionCapabilities = sessionCapabilities
        self.adoptRunnerSession = adoptRunnerSession
    }
}

/// A JSON value that is `Sendable` and `Equatable`, used where callers hand
/// structured data to the client.
public enum WDAJSONValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([WDAJSONValue])
    case object([String: WDAJSONValue])
    case null

    var foundationValue: Any {
        switch self {
        case let .string(value): return value
        case let .number(value): return value
        case let .bool(value): return value
        case let .array(values): return values.map(\.foundationValue)
        case let .object(values): return values.mapValues(\.foundationValue)
        case .null: return NSNull()
        }
    }
}
