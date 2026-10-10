import Foundation
import Testing

// Layer: Mock (filesystem only, no Runtime).
@Suite("UR · Mock · Real-test endpoint guard", .serialized)
struct URTestEndpointGuardTests {
    private func makeTestCopy() throws -> URL {
        let u = URL(fileURLWithPath: "/tmp/adt-urtest-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @Test("[Mock] guardAcceptsASocketInATestCopy") func guardAcceptsASocketInATestCopy() throws {
        let dir = try makeTestCopy()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resolved = try ACPTestEndpointGuard.check(dir.path + "/control.sock")
        #expect(resolved.hasSuffix("/control.sock"))
        #expect(resolved.contains("/tmp/adt-urtest-"))
    }

    @Test("[Mock] guardRefusesEscapes") func guardRefusesEscapes() throws {
        let dir = try makeTestCopy()
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // A /tmp/adt-* symlink to $HOME.
        let link = "/tmp/adt-urtest-link-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: home)
        defer { try? FileManager.default.removeItem(atPath: link) }
        // A socket name that is itself a symlink out of the test copy.
        try FileManager.default.createSymbolicLink(atPath: dir.path + "/control.sock",
                                                   withDestinationPath: home + "/Library/Application Support/AgentDesktop/control.sock" as String)
        let product = home + "/Library/Application Support/AgentDesktop/control.sock"
        let homeRel = String(home.dropFirst())
        let appSock = "/Library/Application Support/AgentDesktop/control.sock"
        var bad: [String] = []
        bad.append(link + appSock)
        bad.append(dir.path + "/../../" + homeRel + appSock)
        bad.append("/tmp/adt-../" + homeRel + "/x.sock")
        bad.append(dir.path + "/control.sock")
        bad.append(product)
        bad.append("relative/adt-x.sock")
        bad.append("/tmp/adt-missing-" + UUID().uuidString + "/c.sock")
        bad.append(dir.path + "/..")
        for bad in bad {
            #expect(throws: ACPTestEndpointGuard.NotATestCopy.self, "accepted \(bad)") { try ACPTestEndpointGuard.check(bad) }
        }
    }
}
