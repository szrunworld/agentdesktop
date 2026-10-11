import AgentDesktopProtocol
import Foundation

// Lane UI-B (Desktops 与控制; docs/plan/11-parallel-lanes.md): this lane's mock
// methods and state. Only that lane edits this file.

/// Lane UI-B's mock state (read and written with the MockRuntime's lock held).
final class MockDesktopsLane: @unchecked Sendable {
    init() {}
}

extension MockRuntime {
    /// Methods lane UI-B models (each must be in RuntimeCatalog.implemented).
    static let desktopsLaneMethods: [String] = []

    /// Lane UI-B's answer to one of `desktopsLaneMethods` (lock held).
    func desktopsLane(_ method: String, _ p: JSONValue, context: RequestContext) throws -> JSONValue {
        throw RuntimeError.capabilityMissing("the mock does not model \(method)")
    }
}
