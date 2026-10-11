import AgentDesktopProtocol
import Foundation

// Lane UI-E (Explorer 页; docs/plan/11-parallel-lanes.md): this lane's mock
// methods and state. Only that lane edits this file.

/// Lane UI-E's mock state (read and written with the MockRuntime's lock held).
final class MockExplorerLane: @unchecked Sendable {
    init() {}
}

extension MockRuntime {
    /// Methods lane UI-E models (each must be in RuntimeCatalog.implemented).
    static let explorerLaneMethods: [String] = []

    /// Lane UI-E's answer to one of `explorerLaneMethods` (lock held).
    func explorerLane(_ method: String, _ p: JSONValue, context: RequestContext) throws -> JSONValue {
        throw RuntimeError.capabilityMissing("the mock does not model \(method)")
    }
}
