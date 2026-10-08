import Foundation
import Testing
@testable import AgentDesktopProtocol
@testable import AgentDesktopRuntime

// SEC-01: the Runtime's records are owner-only on a clean instance, and a
// directory or database an earlier build left readable is repaired.

private func mode(_ path: String) -> Int {
    (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) ?? -1
}

@Test func runtimeRecordsAreOwnerOnlyAndRepaired() throws {
    let root = try socketDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let records = root + "/records"
    let identity = RuntimeIdentity(instanceId: "rt_sec", pid: getpid(), startedAt: Timestamp.string(Date()),
                                   endpoint: root + "/r.sock", buildSource: "unknown")
    do {
        let s = try RuntimeService.persistent(identity: identity, backend: FixedBackend(), platform: nil, records: records)
        _ = s.runs.list(RunStore.ListFilter(), after: nil, limit: 1)
    }
    for f in ["requests.sqlite", "runs.sqlite"] { #expect(mode(records + "/" + f) == 0o600, "\(f)") }
    #expect(mode(records) == 0o700)

    // An earlier build's readable files and directory.
    chmod(records, 0o755)
    for f in try FileManager.default.contentsOfDirectory(atPath: records) where f.hasSuffix("sqlite") || f.contains("sqlite-") {
        chmod(records + "/" + f, 0o644)
    }
    _ = try RuntimeService.persistent(identity: identity, backend: FixedBackend(), platform: nil, records: records)
    #expect(mode(records) == 0o700)
    for f in try FileManager.default.contentsOfDirectory(atPath: records) where f.contains("sqlite") {
        #expect(mode(records + "/" + f) == 0o600, "\(f)")
    }
}
