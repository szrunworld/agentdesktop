// The task client contract, version 0: 2ndscreen docs/task-client-contract.md
// (PR #64), with the coordinator's decisions of 2026-10-07 (two-layer service
// identity, JSON payloads, fractional cost, fixed operation inputs, inbox
// items). These types mirror the document field for field; the UI reads
// them and nothing else. Tests/Fixtures/task-view-sample.json is the shared
// sample both sides decode.

import Foundation

/// Any JSON value: what a control request's payload is.
indirect enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a JSON value") }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

/// Who answered a request: the native host and the task runtime inside it.
/// Both belong to one process, so the pids agree.
struct ServiceIdentity: Codable, Equatable {
    struct Host: Codable, Equatable {
        var product: String
        var bundleId: String
        var pid: Int
        /// The native control protocol (`host.info`), "1" today.
        var controlProtocolVersion: String
        var engineRevision: String
    }
    struct TaskService: Codable, Equatable {
        /// This contract's version, "0".
        var protocolVersion: String
        var runtimeVersion: String
        var capabilities: [String]
    }
    var host: Host
    var task: TaskService

    /// The contract version this client speaks.
    static let supportedProtocolVersion = "0"
}

/// What a client may see and control.
struct ClientScope: Codable, Equatable {
    var clientId: String
    var agentIds: [String]?
}

enum TaskKind: String, Codable {
    case skill, agent
}

/// The one state the UI reads. Words and buttons follow it, never `raw`.
enum TaskUiState: String, Codable, CaseIterable {
    case queued, running, waiting, pausing, paused, stopping, cancelled
    case succeeded, partial, failed, interrupted, unknown

    var isTerminal: Bool {
        switch self {
        case .cancelled, .succeeded, .partial, .failed: return true
        default: return false
        }
    }
}

enum TaskOperation: String, Codable, CaseIterable {
    case pause, resume, cancel, approve, deny, answer
    case bindAccount = "bind_account"
    case openOutput = "open_output"
    case resubmit

    /// The fixed input of each operation (contract, decisions of 2026-10-07).
    /// Operations without one take no payload.
    var inputFields: [String] {
        switch self {
        case .approve: return ["inboxId", "decision"]
        case .deny: return ["inboxId"]
        case .answer: return ["inboxId", "answer"]
        case .bindAccount: return ["platform", "accountKey"]
        case .resubmit: return ["input"]
        case .pause, .resume, .cancel, .openOutput: return []
        }
    }
}

/// A number that may be unknown: never shown as zero.
enum Count: Codable, Equatable {
    case known(Int)
    case unknown

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Int.self) { self = .known(n) }
        else if (try? c.decode(String.self)) == "unknown" { self = .unknown }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "a count is an integer or \"unknown\"") }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .known(let n): try c.encode(n)
        case .unknown: try c.encode("unknown")
        }
    }
    var text: String {
        switch self {
        case .known(let n): return String(n)
        case .unknown: return "未知"
        }
    }
}

/// Money that may be unknown; fractional.
enum Cost: Codable, Equatable {
    case known(Double)
    case unknown

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Double.self) { self = .known(n) }
        else if (try? c.decode(String.self)) == "unknown" { self = .unknown }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "a cost is a number or \"unknown\"") }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .known(let n): try c.encode(n)
        case .unknown: try c.encode("unknown")
        }
    }
    var text: String {
        switch self {
        case .known(let n): return String(format: "%.4f", n)
        case .unknown: return "未知"
        }
    }
}

struct TaskView: Codable, Equatable, Identifiable {
    struct Scope: Codable, Equatable {
        var clientId: String?
        var agentId: String
    }
    struct Raw: Codable, Equatable {
        var status: String
        var phase: String?
        var lifecycle: String?
    }
    enum ResolvedBy: String, Codable {
        case user, approval, external, operator_ = "operator"
    }
    struct Waiting: Codable, Equatable {
        var reason: String
        var since: String
        var resolvedBy: ResolvedBy
        var inboxId: String?
    }
    struct Heartbeat: Codable, Equatable {
        var at: String
        var stale: Bool
    }
    struct Progress: Codable, Equatable {
        var current: String?
        var counts: [String: Int]?
    }
    struct Executor: Codable, Equatable {
        var ownerPid: Int?
        var epoch: String?
        var stopped: Bool
    }
    struct Failure: Codable, Equatable {
        var code: String
        var message: String
    }
    enum Verdict: String, Codable {
        case passed, failed, none
    }
    struct Verification: Codable, Equatable {
        var platform: Verdict
        var business: Verdict
        var notes: [String]?
    }
    struct Result: Codable, Equatable {
        var summary: String?
        var outputPath: String?
        var verification: Verification
    }
    struct Artifact: Codable, Equatable, Identifiable {
        var id: String
        var path: String
        var kind: String
        var sha256: String?
        var verified: Bool
    }
    struct Usage: Codable, Equatable {
        var modelCalls: Count
        var inputTokens: Count
        var outputTokens: Count
        var cost: Cost?
    }

    var id: String
    var kind: TaskKind
    var agentId: String
    var taskType: String
    var scope: Scope
    var state: TaskUiState
    var raw: Raw
    var waiting: Waiting?
    var updatedAt: String
    var heartbeat: Heartbeat?
    var progress: Progress?
    var allowed: [TaskOperation]
    var executor: Executor?
    var error: Failure?
    var result: Result?
    var artifacts: [Artifact]
    var usage: Usage?
    var submittedAt: String?
    var startedAt: String?
    var endedAt: String?
}

/// A pending item (approval, question, login, check), as 待处理 renders it:
/// what is asked, of which task, and the action it would allow.
struct InboxItem: Codable, Equatable, Identifiable {
    struct ActionSummary: Codable, Equatable {
        var effect: String
        var app: String
        var target: String
        var label: String
    }
    var id: String
    var kind: String
    var taskId: String
    var agentId: String
    var action: ActionSummary?
    var question: String?
    var expiresAt: String?
}

struct ControlRequest: Codable, Equatable {
    var taskId: String
    var operation: TaskOperation
    var payload: JSONValue?
    var requestId: String
}

struct ControlReceipt: Codable, Equatable {
    struct Reason: Codable, Equatable {
        var code: String
        var message: String
    }
    var requestId: String
    var taskId: String
    var operation: TaskOperation
    var accepted: Bool
    var acceptedAt: String?
    var reason: Reason?
    var executorStopped: Bool
    var settlesTo: [TaskUiState]
}

/// Why a client call failed: the contract's error codes plus the two
/// service-level ones, as the UI tells them apart.
enum TaskClientError: Error, Equatable {
    /// Nobody listens at the endpoint, or the runtime says the app is not running.
    case offline(String)
    /// The service lacks the ability: no runtime, no `task view`, no workflow.
    case capabilityMissing(String)
    case versionMismatch(found: String, supported: String)
    /// The command could not be run, or answered something this contract does not describe.
    case connectionFailed(String)
    case notFound(String)
    case conflict(String)
    case invalidInput(String)
    case leaseHeld(String)
    case other(code: String, message: String)

    /// Built from a RuntimeError code of the CLI's JSON line.
    static func fromCode(_ code: String, _ message: String) -> TaskClientError {
        switch code {
        case "offline": return .offline(message)
        case "capability_missing": return .capabilityMissing(message)
        case "version_mismatch": return .versionMismatch(found: message, supported: ServiceIdentity.supportedProtocolVersion)
        case "not_found": return .notFound(message)
        case "conflict": return .conflict(message)
        case "invalid_input": return .invalidInput(message)
        case "lease_held": return .leaseHeld(message)
        default: return .other(code: code, message: message)
        }
    }
}
