import AgentDesktopProtocol
import Foundation

// Lane UI-D (设置; docs/plan/11-parallel-lanes.md): this lane's mock
// methods and state. Only that lane edits this file.

/// Lane UI-D's mock state (read and written with the MockRuntime's lock held).
final class MockSettingsLane: @unchecked Sendable {
    init() {}
}

extension MockRuntime {
    /// Methods lane UI-D models (each must be in RuntimeCatalog.implemented).
    static let settingsLaneMethods: [String] = []

    /// Lane UI-D's answer to one of `settingsLaneMethods` (lock held).
    func settingsLane(_ method: String, _ p: JSONValue, context: RequestContext) throws -> JSONValue {
        throw RuntimeError.capabilityMissing("the mock does not model \(method)")
    }
}
