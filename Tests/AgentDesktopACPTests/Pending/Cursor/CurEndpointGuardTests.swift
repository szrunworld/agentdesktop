import Foundation
import Testing
@testable import AgentDesktopACP

/// [Mock] The Real-test endpoint allowlist cannot be bypassed by symlinks
/// or path tricks (Kevin's #141 security review points).
@Suite("[Mock] Cursor Real-test endpoint guard")
struct CurEndpointGuardTests {
    @Test("[Mock] a /tmp/adt-* symlink that points outside is refused")
    func symlinkOutsideIsRefused() throws {
        let link = "/tmp/adt-curtest-link-\(UUID().uuidString)"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: NSHomeDirectory())
        defer { try? FileManager.default.removeItem(atPath: link) }
        #expect(throws: CurTestReal.NotATestCopy.self) { _ = try CurTestReal.checkedEndpoint(link + "/runtime.sock") }
    }

    @Test("[Mock] .. cannot climb out of /tmp/adt-*", arguments: [
        "/tmp/adt-x/../../Users/someone/Library/Application Support/AgentDesktop/runtime.sock",
        "/tmp/adt-x/../../etc/runtime.sock",
        "/Users/someone/Library/Application Support/AgentDesktop/control.sock",
        "relative/adt-x/runtime.sock",
    ])
    func pathTricksAreRefused(_ raw: String) {
        #expect(throws: CurTestReal.NotATestCopy.self) { _ = try CurTestReal.checkedEndpoint(raw) }
    }

    @Test("[Mock] a real test copy directory is accepted, with or without /private")
    func testCopyIsAccepted() throws {
        let dir = "/tmp/adt-curtest-ok-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(try CurTestReal.checkedEndpoint(dir + "/side.runtime.sock") == dir + "/side.runtime.sock")
        #expect(try CurTestReal.checkedEndpoint("/private" + dir + "/side.runtime.sock") == "/private" + dir + "/side.runtime.sock")
    }

    @Test("[Mock] a test copy directory that does not exist is refused")
    func missingDirectoryIsRefused() {
        #expect(throws: CurTestReal.NotATestCopy.self) { _ = try CurTestReal.checkedEndpoint("/tmp/adt-missing-\(UUID().uuidString)/side.runtime.sock") }
    }
}
