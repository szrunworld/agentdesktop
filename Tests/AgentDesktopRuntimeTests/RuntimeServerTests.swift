import AgentDesktopClient
import AgentDesktopContracts
import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopRuntime

func startServer(_ path: String, backend: RuntimeBackend = FixedBackend()) throws -> RuntimeServer {
    let server = RuntimeServer(path: path, service: makeService(backend: backend, endpoint: path))
    try server.start()
    return server
}

@Test func theSocketIsOwnerOnlyAndGoneAfterStop() throws {
    let dir = try socketDirectory()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/runtime.sock"
    let server = try startServer(path)
    var st = stat()
    #expect(lstat(path, &st) == 0)
    #expect(st.st_mode & 0o777 == 0o600)
    #expect(st.st_uid == getuid())
    server.stop()
    #expect(!FileManager.default.fileExists(atPath: path))
}

@Test func aSecondServerOnTheSamePathIsRefusedAndTheFirstKeepsServing() throws {
    let dir = try socketDirectory()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/runtime.sock"
    let first = try startServer(path)
    defer { first.stop() }
    let second = RuntimeServer(path: path, service: makeService(endpoint: path))
    #expect(throws: RuntimeServer.StartError.alreadyServed(path: path, holderPID: getpid())) { try second.start() }
    let c = SocketRuntimeClient(endpoint: Endpoint(path: path, source: .option), info: ClientInfo(name: "t", version: "1"))
    defer { c.close() }
    #expect(try c.handshake().instanceId == "rt_test")
}

@Test func aLeftoverSocketIsReplacedButAnotherFileIsNot() throws {
    let dir = try socketDirectory()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/runtime.sock"
    // A server that died without stop() leaves its socket file behind.
    let stale = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = SocketOptions.address(path)!
    _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(stale, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    close(stale)
    let server = try startServer(path)
    server.stop()

    let other = dir + "/other.sock"
    try Data("keep".utf8).write(to: URL(fileURLWithPath: other))
    #expect(throws: RuntimeServer.StartError.notOwned(other)) { try startServer(other) }
    #expect(try String(contentsOfFile: other, encoding: .utf8) == "keep")
}

@Test func oneConnectionAnswersRequestsInOrderIncludingPipelinedOnes() throws {
    let dir = try socketDirectory()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let server = try startServer(dir + "/r.sock")
    defer { server.stop() }
    let conn = try RawConnection(dir + "/r.sock")
    conn.send(handshakeLine + "\n" + requestLine("desktop.list", id: "a1") + "\n" + requestLine("runtime.status", id: "a2") + "\n")
    #expect(try conn.read()["requestId"]?.stringValue == "hs_1")
    #expect(try conn.read()["requestId"]?.stringValue == "a1")
    let status = try conn.read()
    #expect(status["requestId"]?.stringValue == "a2")
    #expect(status["data"]?["connections"]?.intValue == 1)
}

@Test func anOversizedMessageIsRefusedAndTheConnectionClosed() throws {
    let dir = try socketDirectory()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let server = try startServer(dir + "/r.sock")
    defer { server.stop() }
    let conn = try RawConnection(dir + "/r.sock")
    conn.send(String(repeating: "x", count: RuntimeAPI.maxFrameBytes) + "\n")
    let r = try conn.read()
    #expect(r["error"]?["code"]?.stringValue == "frame_too_large")
    #expect(r["requestId"] == .null)
    #expect(conn.channel.readLine() == .eof)
}

@Test func aClientThatLeavesEarlyDoesNotStopTheServer() throws {
    let dir = try socketDirectory()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let server = try startServer(dir + "/r.sock")
    defer { server.stop() }
    for _ in 0..<20 {
        let conn = try RawConnection(dir + "/r.sock")
        conn.send(handshakeLine)  // no LF, then gone
    }
    let c = SocketRuntimeClient(endpoint: Endpoint(path: dir + "/r.sock", source: .option), info: ClientInfo(name: "t", version: "1"))
    defer { c.close() }
    #expect(try c.call(RuntimeRequest(.desktopList))["desktops"] == .array([]))
}

@Test func concurrentClientsAreServedIndependently() async throws {
    let dir = try socketDirectory()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/r.sock"
    let server = try startServer(path)
    defer { server.stop() }
    let results = await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<16 {
            group.addTask {
                let c = SocketRuntimeClient(endpoint: Endpoint(path: path, source: .option), info: ClientInfo(name: "t", version: "1"))
                defer { c.close() }
                return (try? c.call(RuntimeRequest(.windowList))["windows"]?.arrayValue?.count) == 2
            }
        }
        var all: [Bool] = []
        for await r in group { all.append(r) }
        return all
    }
    #expect(results.count == 16 && results.allSatisfy { $0 })
}
