import AgentDesktopClient
import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopRuntime

// Endpoint ownership (from #66's scenarios, on the Runtime's own server) and
// the ownership record the lock file now carries. The record is a clue for
// diagnosis, never proof that a Runtime runs.

private func record(_ path: String) -> EndpointRecord? {
    (try? String(contentsOfFile: path + ".lock", encoding: .utf8)).flatMap { EndpointRecord.parse($0).record }
}

/// The pid of a process that has exited (a crashed owner).
private func deadPID() throws -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try p.run()
    p.waitUntilExit()
    return p.processIdentifier
}

private func staleSocket(_ path: String) {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = SocketOptions.address(path)!
    _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    close(fd)
}

@Test func theLockFileSaysWhoHoldsTheEndpointAndWhetherItListens() throws {
    let dir = try socketDirectory()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/runtime.sock"
    let server = try startServer(path)
    let r = try #require(record(path))
    #expect(r.product == "AgentDesktop" && r.pid == getpid() && r.instanceId == "rt_test" && r.endpoint == path)
    #expect(r.listening)
    var st = stat()
    #expect(lstat(path + ".lock", &st) == 0 && st.st_mode & 0o777 == 0o600)
    server.stop()
    let after = try #require(record(path))
    #expect(!after.listening, "a stopped owner leaves its record, marked not listening")
}

@Test func concurrentStartsMakeExactlyOneOwnerAndTheLosersTouchNothing() throws {
    let dir = try socketDirectory()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/runtime.sock"
    final class Results: @unchecked Sendable { let lock = NSLock(); var started: [RuntimeServer] = []; var refused = 0 }
    let results = Results()
    let servers = (0..<8).map { _ in RuntimeServer(path: path, service: makeService(endpoint: path)) }
    DispatchQueue.concurrentPerform(iterations: servers.count) { i in
        do { try servers[i].start(); results.lock.withLock { results.started.append(servers[i]) } }
        catch { results.lock.withLock { results.refused += 1 } }
    }
    #expect(results.started.count == 1 && results.refused == 7)
    let owner = try #require(results.started.first)
    // The losers removed nothing: the owner still answers and its record stands.
    let c = SocketRuntimeClient(endpoint: Endpoint(path: path, source: .option), info: ClientInfo(name: "t", version: "1"))
    #expect(try c.handshake().pid == getpid())
    c.close()
    #expect(record(path)?.listening == true)
    owner.stop()
}

@Test func aCrashedOwnersLeftoversAreReplacedByTheNextStart() throws {
    let dir = try socketDirectory()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/runtime.sock"
    // What a crash leaves: a socket nobody listens on, and the old record
    // (its pid gone; the kernel dropped the lock with the process).
    staleSocket(path)
    let ghost = EndpointRecord(product: "AgentDesktop", productVersion: "0.0.1", pid: try deadPID(), instanceId: "rt_ghost",
                               endpoint: path, listening: true, since: "2026-10-01T00:00:00.000Z")
    try Data(ghost.line.utf8).write(to: URL(fileURLWithPath: path + ".lock"))
    let server = try startServer(path)
    defer { server.stop() }
    #expect(record(path)?.instanceId == "rt_test" && record(path)?.pid == getpid())
}

@Test func aStoppedOwnerLetsTheNextOneStart() throws {
    let dir = try socketDirectory()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/runtime.sock"
    try startServer(path).stop()
    let next = try startServer(path)
    defer { next.stop() }
    #expect(record(path)?.listening == true)
}

@Test func anOwnerFromBeforeRecordsIsStillNamedWhenItHoldsTheLock() throws {
    let dir = try socketDirectory()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/runtime.sock"
    // A holder of the lock whose file says only a pid (older Runtimes).
    let fd = open(path + ".lock", O_RDWR | O_CREAT, 0o600)
    defer { close(fd) }
    #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
    _ = "4242\n".withCString { write(fd, $0, strlen($0)) }
    let second = RuntimeServer(path: path, service: makeService(endpoint: path))
    #expect(throws: RuntimeServer.StartError.alreadyServed(path: path, holderPID: 4242)) { try second.start() }
    #expect(!FileManager.default.fileExists(atPath: path), "the loser created no socket")
}

@Test func aPathTooLongForASocketTakesNoLock() throws {
    let dir = try socketDirectory()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/" + String(repeating: "x", count: 120) + ".sock"
    #expect(throws: RuntimeServer.StartError.pathTooLong(path)) { try startServer(path) }
    #expect(!FileManager.default.fileExists(atPath: path + ".lock"))
}

@Test func recordsParseOnlyWhatTheyShould() {
    let r = EndpointRecord(product: "AgentDesktop", productVersion: "1", pid: 7, instanceId: "rt_x", endpoint: "/p",
                           listening: false, since: "2026-10-09T00:00:00.000Z")
    #expect(EndpointRecord.parse(r.line).record == r)
    #expect(EndpointRecord.parse("1234\n").legacyPID == 1234)
    #expect(EndpointRecord.parse("{not json").record == nil && EndpointRecord.parse("{not json").legacyPID == nil)
    #expect(!r.line.contains("token") && !r.line.contains("credential"))
}


// Stopping reads the record from the descriptor it holds: whatever is put at
// the path meanwhile (a FIFO) cannot hold the app's exit up.
@Test func stoppingDoesNotWaitOnWhateverIsAtTheLockPath() throws {
    let dir = try socketDirectory()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/runtime.sock"
    let server = try startServer(path)
    try FileManager.default.removeItem(atPath: path + ".lock")
    #expect(mkfifo(path + ".lock", 0o600) == 0)
    let started = Date()
    server.stop()
    #expect(Date().timeIntervalSince(started) < 2)
}

// b9's review of 98134e1: a lock path that is a link is not followed (the
// mode change and the record would land on its target), and the start fails.
@Test func aLockPathThatIsALinkIsRefusedAndItsTargetUntouched() throws {
    let dir = try socketDirectory()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/runtime.sock"
    let target = dir + "/elsewhere"
    FileManager.default.createFile(atPath: target, contents: Data("keep".utf8), attributes: [.posixPermissions: 0o644])
    symlink(target, path + ".lock")
    let server = RuntimeServer(path: path, service: makeService(endpoint: path))
    #expect(throws: (any Error).self) { try server.start() }
    var st = stat()
    #expect(stat(target, &st) == 0 && st.st_mode & 0o777 == 0o644)
    #expect(try String(contentsOfFile: target, encoding: .utf8) == "keep")
    #expect(lstat(path, &st) != 0, "no socket was made")
}

@Test func anExistingLockFileBecomesOwnerOnly() throws {
    let dir = try socketDirectory()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/runtime.sock"
    FileManager.default.createFile(atPath: path + ".lock", contents: Data(), attributes: [.posixPermissions: 0o644])
    let server = try startServer(path)
    defer { server.stop() }
    var st = stat()
    #expect(lstat(path + ".lock", &st) == 0 && st.st_mode & 0o777 == 0o600)
}
