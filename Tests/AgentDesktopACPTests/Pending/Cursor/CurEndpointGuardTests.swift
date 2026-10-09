import AgentDesktopProtocol
import Darwin
import Foundation
import Testing
@testable import AgentDesktopACP

/// [Mock] The Real-test endpoint allowlist cannot be bypassed by symlinks
/// or path tricks (Kevin's #141 security review points).
@Suite("[Mock] Cursor Real-test endpoint guard")
struct CurEndpointGuardTests {
    @Test("[Mock] a /tmp/adt-* symlink that points outside is refused")
    func symlinkOutsideIsRefused() throws {
        let link = ACPTestScratch.tmp("curtest-link")
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
        let dir = ACPTestScratch.tmp("curtest-ok")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(try CurTestReal.checkedEndpoint(dir + "/side.runtime.sock") == dir + "/side.runtime.sock")
        #expect(try CurTestReal.checkedEndpoint("/private" + dir + "/side.runtime.sock") == "/private" + dir + "/side.runtime.sock")
    }

    @Test("[Mock] a hard link inside /tmp/adt-* is refused")
    func hardLinkIsRefused() throws {
        let dir = ACPTestScratch.tmp("curtest-hl")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let original = dir + "/original.sock"
        let fd = try Self.bindSocket(original) // a real socket, so only the link count refuses it
        defer { close(fd) }
        let link = dir + "/side.runtime.sock"
        try FileManager.default.linkItem(atPath: original, toPath: link)
        #expect(throws: CurTestReal.NotATestCopy.self) { _ = try CurTestReal.checkedEndpoint(link) }
    }

    @Test("[Mock] a regular file in place of the socket is refused")
    func nonSocketIsRefused() throws {
        let dir = ACPTestScratch.tmp("curtest-rf")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        FileManager.default.createFile(atPath: dir + "/side.runtime.sock", contents: Data())
        #expect(throws: CurTestReal.NotATestCopy.self) { _ = try CurTestReal.checkedEndpoint(dir + "/side.runtime.sock") }
    }

    @Test("[Mock] a bound socket of this user is accepted")
    func ownSocketIsAccepted() throws {
        let dir = ACPTestScratch.tmp("curtest-so")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let fd = try Self.bindSocket(dir + "/side.runtime.sock")
        defer { close(fd) }
        #expect(try CurTestReal.checkedEndpoint(dir + "/side.runtime.sock") == dir + "/side.runtime.sock")
    }

    static func bindSocket(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = try #require(SocketOptions.address(path))
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(rc == 0)
        return fd
    }

    @Test("[Mock] a symlinked socket inside /tmp/adt-* is refused")
    func symlinkedSocketIsRefused() throws {
        let dir = ACPTestScratch.tmp("curtest-sl")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let link = dir + "/side.runtime.sock"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: NSHomeDirectory() + "/Library/Application Support/AgentDesktop/runtime.sock")
        #expect(throws: CurTestReal.NotATestCopy.self) { _ = try CurTestReal.checkedEndpoint(link) }
    }

    @Test("[Mock] a test copy directory that does not exist is refused")
    func missingDirectoryIsRefused() {
        #expect(throws: CurTestReal.NotATestCopy.self) { _ = try CurTestReal.checkedEndpoint("/tmp/adt-missing-\(UUID().uuidString)/side.runtime.sock") }
    }
}
