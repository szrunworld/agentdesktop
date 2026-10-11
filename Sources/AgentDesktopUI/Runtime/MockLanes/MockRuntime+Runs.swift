import AgentDesktopProtocol
import Foundation

// Lane UI-A (Runs、Inbox 与 Store; docs/plan/11-parallel-lanes.md): this lane's mock
// methods and state. Only that lane edits this file.

/// Lane UI-A's mock state (read and written with the MockRuntime's lock held).
final class MockRunsLane: @unchecked Sendable {
    init() {}
}

extension MockRuntime {
    /// Methods lane UI-A models (each must be in RuntimeCatalog.implemented).
    static let runsLaneMethods: [String] = []

    /// Lane UI-A's answer to one of `runsLaneMethods` (lock held).
    func runsLane(_ method: String, _ p: JSONValue, context: RequestContext) throws -> JSONValue {
        throw RuntimeError.capabilityMissing("the mock does not model \(method)")
    }
}
