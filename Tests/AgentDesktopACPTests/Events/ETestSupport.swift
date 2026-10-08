import AgentDesktopProtocol
import Foundation
@testable import AgentDesktopACP

/// Lane E test helpers: fixture loading, update encoding, leak scanning.
enum ETest {
    static var fixturesDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/events")
    }

    static func event(_ type: String, _ data: [(String, JSONValue)] = [], run: String = "run_0a1b2c3d4e5f", cursor: Int = 1) -> ACPRuntimeEvent {
        ACPRuntimeEvent(runId: run, cursor: cursor, type: type, payload: .obj(data))
    }

    static func receipt(delivery: String = "dispatched", execution: String = "completed", verification: String = "not_requested",
                        businessResult: String? = "not_evaluated", requestId: String = "req_0001aaaabbbb",
                        elementRef: JSONValue = .string("el_7"), extra: [(String, JSONValue)] = []) -> JSONValue {
        var m: [(String, JSONValue)] = [
            ("receiptId", .string("rcpt_00aa11bb22cc")), ("requestId", .string(requestId)), ("runId", .string("run_0a1b2c3d4e5f")),
            ("desktopId", .string("desk_000000aaaaaa")), ("sessionId", .string("sess_000000bbbbbb")),
            ("snapshotId", .string("snap_000000cccccc")), ("delivery", .string(delivery)), ("execution", .string(execution)),
            ("verification", .string(verification)),
        ]
        if let businessResult { m.append(("businessResult", .string(businessResult))) }
        m += [
            ("route", .string("ax")),
            ("target", .obj([("generation", .int(1)), ("process", .obj([("pid", .int(4242)), ("startedAt", .null)])),
                             ("windowId", .int(813)), ("elementRef", elementRef), ("point", .null)])),
            ("timing", .obj([("acceptedAt", .string("2026-10-08T12:00:00.000Z")),
                             ("dispatchedAt", .string("2026-10-08T12:00:00.120Z")),
                             ("completedAt", .string("2026-10-08T12:00:00.350Z"))])),
        ]
        return .obj(m + extra)
    }

    // MARK: Encoding updates for golden files

    static func encode(_ u: ACPSessionUpdate) -> JSONValue {
        func call(_ c: ACPToolCall) -> JSONValue {
            .obj([("toolCallId", .string(c.toolCallId)), ("title", .string(c.title)), ("kind", .string(c.kind.rawValue)),
                  ("status", .string(c.status.rawValue)), ("level", c.level.map(level) ?? .null),
                  ("detail", .array(c.detail.map(JSONValue.string)))])
        }
        switch u {
        case let .agentMessage(s): return .obj([("agentMessage", .string(s))])
        case let .agentThought(s): return .obj([("agentThought", .string(s))])
        case let .plan(es):
            return .obj([("plan", .array(es.map { .obj([("content", .string($0.content)), ("status", .string($0.status.rawValue))]) }))])
        case let .toolCall(c): return .obj([("toolCall", call(c))])
        case let .toolCallUpdate(c): return .obj([("toolCallUpdate", call(c))])
        case let .sessionInfo(t): return .obj([("sessionInfo", .string(t))])
        default: return .obj([("other", .string(String(describing: u)))])
        }
    }

    static func level(_ l: ACPActionLevel) -> JSONValue {
        switch l {
        case .accepted: return .string("accepted")
        case .dispatched: return .string("dispatched")
        case .executed: return .string("executed")
        case .verified: return .string("verified")
        case .contradicted: return .string("contradicted")
        case .unknown: return .string("unknown")
        case let .refused(code): return .string("refused:\(code)")
        case let .failed(code): return .string("failed:\(code)")
        }
    }

    static func policy(_ v: JSONValue?) -> ACPPrivacyPolicy {
        var p = ACPPrivacyPolicy()
        p.screenshots = ACPDisclosure(rawValue: v?["screenshots"]?.stringValue ?? "off") ?? .off
        p.pageText = v?["pageText"]?.boolValue ?? false
        return p
    }

    // MARK: Leak scanning

    /// Every string an update would put on the wire.
    static func strings(_ u: ACPSessionUpdate) -> [String] {
        switch u {
        case let .agentMessage(s), let .agentThought(s): return [s]
        case let .plan(es): return es.map(\.content)
        case let .toolCall(c), let .toolCallUpdate(c): return [c.toolCallId, c.title] + c.detail
        case let .sessionInfo(t): return [t]
        default: return [String(describing: u)]
        }
    }

    static func strings(_ us: [ACPSessionUpdate]) -> [String] { us.flatMap(strings) }

    /// Patterns that must never appear in projected output, whatever the policy.
    static let leakPatterns: [String] = [
        #"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z]{2,}"#, // e-mail
        #"(?<![0-9])1[3-9]\d{9}(?![0-9])"#,              // CN mobile
        #"(?<![0-9])\d{17}[0-9Xx](?![0-9])"#,             // ID card
        #"(?<![0-9])\d{7,}(?![0-9])"#,                    // long digits
        #"(?i)https?://"#,                                // links
        #"(?i)bearer\s+\S{8,}"#,                          // tokens
        #"iVBORw0KGgo"#,                                  // PNG bytes in base64
    ]

    static func leaks(in text: String) -> [String] {
        leakPatterns.filter { text.range(of: $0, options: .regularExpression) != nil }
    }
}
