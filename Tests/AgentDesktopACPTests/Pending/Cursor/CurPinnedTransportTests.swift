import AgentDesktopClient
import AgentDesktopProtocol
import Darwin
import Foundation
import Testing

/// [Mock] Kernel-pinned Real-test transport (Kevin on #141: the test
/// launches its own Runtime; isolation rests on the kernel's view of the
/// connected peer, never on a pid or path anyone passes in). Children are
/// stand-ins (a small python listener) so these run everywhere; the same
/// cases against a real AgentDesktopApp are in RuntimeBridgeSmokeTests.
/// A listener in this test process plays "another process"; the bytes it
/// receives prove that a refused connection sends nothing.
@Suite("[Mock] Real-test pinned transport", .serialized)
struct CurPinnedTransportTests {
    /// Listens once, accepts one connection, counts every byte until EOF.
    final class Listener: @unchecked Sendable {
        let path: String
        private let ownDir: String?
        private let fd: Int32
        private let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var received = Data()

        convenience init() throws {
            let dir = "/tmp/adt-ptest-\(UUID().uuidString.prefix(8))"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try self.init(path: dir + "/side.runtime.sock", ownDir: dir)
        }

        /// Bind `path` (e.g. a child's endpoint after it left).
        init(path: String, ownDir: String? = nil) throws {
            self.path = path
            self.ownDir = ownDir
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var addr = SocketOptions.address(path)!
            let sfd = fd
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sfd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            precondition(rc == 0 && listen(sfd, 4) == 0, "bind \(path) errno \(errno)")
            Thread.detachNewThread { [self] in
                let c = accept(sfd, nil, nil)
                if c >= 0 {
                    var buf = [UInt8](repeating: 0, count: 4096)
                    while true {
                        let n = read(c, &buf, buf.count)
                        if n <= 0 { break }
                        lock.lock(); received.append(contentsOf: buf[0..<n]); lock.unlock()
                        if buf[0..<n].contains(10) { _ = "{}\n".withCString { write(c, $0, 3) } }
                    }
                    close(c)
                }
                done.signal()
            }
        }

        /// Bytes received once the peer closed (or after a short wait).
        func bytesAfterClose() -> Int {
            _ = done.wait(timeout: .now() + 2)
            lock.lock(); defer { lock.unlock() }
            return received.count
        }

        deinit {
            close(fd)
            if let ownDir { try? FileManager.default.removeItem(atPath: ownDir) } else { unlink(path) }
        }
    }

    /// A stand-in Runtime: listens on its endpoint and answers each line.
    static let standInScript = """
    import socket, sys
    s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(4)
    while True:
        c, _ = s.accept()
        for line in c.makefile('rb'):
            c.sendall(b'{}\\n')
        c.close()
    """

    static func standIn(listening: Bool = true) throws -> ACPTestRuntimeChild {
        listening
            ? try ACPTestRuntimeChild.launch(executable: "/usr/bin/python3", arguments: ["-c", standInScript, "{endpoint}"])
            : try ACPTestRuntimeChild.launch(executable: "/bin/sleep", arguments: ["30"], waitForEndpoint: false)
    }

    private func connect(_ child: ACPTestRuntimeChild?, path: String? = nil,
                         holders: Set<pid_t>? = []) -> Result<Data?, Error> {
        do {
            let t = try ACPTestPinnedTransport(path: path ?? child?.runtimeEndpoint ?? "/tmp/adt-none/x.sock",
                                               timeout: 2, child: child, productHolders: { holders })
            defer { t.close() }
            return .success(try? t.exchange(Data("{\"method\":\"runtime.handshake\"}".utf8)))
        } catch { return .failure(error) }
    }

    private func refused(_ r: Result<Data?, Error>) -> Bool {
        if case let .failure(e) = r { return e is ACPTestPinnedTransport.Refused }
        return false
    }

    @Test("[Mock] the child this test launched is accepted and answers")
    func launchedChildIsAccepted() throws {
        let child = try Self.standIn()
        defer { child.stop() }
        guard case let .success(reply) = connect(child) else { Issue.record("refused"); return }
        #expect(reply == Data("{}".utf8))
    }

    @Test("[Mock] another process holds the child's socket path: refused, nothing is sent")
    func anotherProcessOnTheSocketIsRefused() throws {
        let child = try Self.standIn(listening: false) // alive, but not listening
        defer { child.stop() }
        let impostor = try Listener(path: child.runtimeEndpoint)
        #expect(refused(connect(child)))
        #expect(impostor.bytesAfterClose() == 0)
    }

    @Test("[Mock] the child exited (still unreaped) and another process reuses its path: refused, nothing is sent")
    func pathReusedAfterExitIsRefused() throws {
        let child = try Self.standIn()
        defer { child.stop() }
        child.terminate(reap: false) // zombie: its pid is still taken
        unlink(child.runtimeEndpoint)
        let impostor = try Listener(path: child.runtimeEndpoint)
        #expect(refused(connect(child)))
        #expect(impostor.bytesAfterClose() == 0)
    }

    @Test("[Mock] the child was reaped and another process reuses its path: refused, nothing is sent")
    func pathReusedAfterReapIsRefused() throws {
        let child = try Self.standIn()
        defer { child.stop() }
        child.terminate(reap: true) // its pid may now be reused by anyone
        unlink(child.runtimeEndpoint)
        let impostor = try Listener(path: child.runtimeEndpoint)
        #expect(refused(connect(child)))
        #expect(impostor.bytesAfterClose() == 0)
    }

    @Test("[Mock] a socket swapped in after the path check: refused, nothing is sent")
    func swappedSocketIsRefused() throws {
        let child = try Self.standIn()
        defer { child.stop() }
        // Replace the child's socket file with this process's listener.
        unlink(child.runtimeEndpoint)
        let impostor = try Listener(path: child.runtimeEndpoint)
        #expect(refused(connect(child)))
        #expect(impostor.bytesAfterClose() == 0)
    }

    @Test("[Mock] a path other than the child's endpoint: refused before connecting")
    func otherPathIsRefused() throws {
        let child = try Self.standIn()
        defer { child.stop() }
        let elsewhere = try Listener()
        #expect(refused(connect(child, path: elsewhere.path)))
        #expect(elsewhere.bytesAfterClose() == 0)
    }

    @Test("[Mock] the child holds a product socket: refused")
    func productHolderIsRefused() throws {
        let child = try Self.standIn()
        defer { child.stop() }
        #expect(refused(connect(child, holders: [child.pid])))
    }

    @Test("[Mock] holders cannot be determined (lsof failed): refused")
    func unknownHoldersFailClosed() throws {
        let child = try Self.standIn()
        defer { child.stop() }
        #expect(refused(connect(child, holders: nil)))
    }

    @Test("[Mock] no launched child: fail closed, nothing is sent")
    func missingChildFailsClosed() throws {
        let l = try Listener()
        #expect(refused(connect(nil, path: l.path)))
        #expect(l.bytesAfterClose() == 0)
    }

    @Test("[Mock] stop() reaps the child and removes only its own /tmp/adt-acp-* directory")
    func stopCleansUp() throws {
        let child = try Self.standIn()
        let dir = child.directory
        #expect(dir.hasPrefix(ACPTestRuntimeChild.directoryPrefix))
        child.stop()
        #expect(!child.isRunning)
        #expect(!FileManager.default.fileExists(atPath: dir))
    }

    @Test("[Mock] lsof fields: a socket bound in the product directory names its holder")
    func lsofFieldsAreParsed() {
        let dir = "/Users/x/Library/Application Support/AgentDesktop"
        let text = "p101\nn\(dir)/runtime.sock\np202\nn/tmp/adt-1/side.runtime.sock\np303\nn\(dir)-other/x.sock\n"
        #expect(ACPTestPinnedTransport.holders(lsofFields: text, productDirs: [dir]) == [101])
    }

    @Test("[Mock] the real lsof query runs and answers (no product needed)")
    func realHolderQueryAnswers() {
        #expect(ACPTestPinnedTransport.productSocketHolders() != nil)
    }
}
