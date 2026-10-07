// The task client contract, version 0: 2ndscreen docs/task-client-contract.md
// (PR #64). These types mirror that document field for field; the UI reads
// them and nothing else. Field names may still change before C03 lands.

import Foundation

/// Who answered a request. Every response carries it.
struct ServiceIdentity: Codable, Equatable {
    var product: String
    var bundleId: String
    var pid: Int
    var protocolVersion: String
    var runtimeVersion: String
    var engineRevision: String
    var capabilities: [String]

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

enum Operation: String, Codable, CaseIterable {
    case pause, resume, cancel, approve, deny, answer
    case bindAccount = "bind_account"
    case openOutput = "open_output"
    case resubmit
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
    /// A number, or "unknown": never shown as zero.
    enum Count: Codable, Equatable {
        case known(Int)
        case unknown

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let n = try? container.decode(Int.self) { self = .known(n) } else { self = .unknown }
        }
        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .known(let n): try container.encode(n)
            case .unknown: try container.encode("unknown")
            }
        }
        var text: String {
            switch self {
            case .known(let n): return String(n)
            case .unknown: return "未知"
            }
        }
    }
    struct Usage: Codable, Equatable {
        var modelCalls: Count
        var inputTokens: Count
        var outputTokens: Count
        var cost: Count?
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
    var allowed: [Operation]
    var executor: Executor?
    var error: Failure?
    var result: Result?
    var artifacts: [Artifact]
    var usage: Usage?
    var submittedAt: String?
    var startedAt: String?
    var endedAt: String?
}

struct ControlRequest: Codable, Equatable {
    var taskId: String
    var operation: Operation
    var payload: [String: String]?
    var requestId: String
}

struct ControlReceipt: Codable, Equatable {
    struct Reason: Codable, Equatable {
        var code: String
        var message: String
    }
    var requestId: String
    var taskId: String
    var operation: Operation
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
    /// The command could not be run or answered nothing usable.
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
