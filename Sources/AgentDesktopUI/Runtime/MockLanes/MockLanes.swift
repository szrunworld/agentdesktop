import AgentDesktopProtocol
import Foundation

// Seams for the parallel UI lanes (docs/plan/11-parallel-lanes.md): each
// lane models its methods and keeps its state in its own file
// (MockRuntime+<Lane>.swift), so lanes never edit MockRuntime.swift or
// each other's files. This file is shared: change it only in its own PR.

/// Every lane's mock state, held by the MockRuntime (guarded by its lock).
final class MockLanes: @unchecked Sendable {
    let desktops = MockDesktopsLane()
    let agents = MockAgentsLane()
    let runs = MockRunsLane()
    let settings = MockSettingsLane()
    let explorer = MockExplorerLane()
}

extension MockRuntime {
    /// Methods the lanes model (part of `modeled`).
    static var laneModeled: [String] {
        desktopsLaneMethods + agentsLaneMethods + runsLaneMethods + settingsLaneMethods + explorerLaneMethods
    }

    /// A lane's answer to `method`, or nil when no lane models it. Called
    /// with the lock held, after the contract check of the params.
    func laneAnswer(_ method: String, _ p: JSONValue, context: RequestContext) throws -> JSONValue? {
        if Self.desktopsLaneMethods.contains(method) { return try desktopsLane(method, p, context: context) }
        if Self.agentsLaneMethods.contains(method) { return try agentsLane(method, p, context: context) }
        if Self.runsLaneMethods.contains(method) { return try runsLane(method, p, context: context) }
        if Self.settingsLaneMethods.contains(method) { return try settingsLane(method, p, context: context) }
        if Self.explorerLaneMethods.contains(method) { return try explorerLane(method, p, context: context) }
        return nil
    }
}
