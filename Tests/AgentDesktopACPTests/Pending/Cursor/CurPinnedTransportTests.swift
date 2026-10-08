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
    /// The accept thread holds only a `State`, never the Listener, and polls
    /// a stop flag, so a Listener nobody connects to is still released and
    /// its directory removed (b9, third review: leaked /tmp/adt-ptest-*).
    final class Listener: @unchecked Sendable {
        final class State: @unchecked Sendable {
            let lock = NSLock()
            var received = Data()
            var stopped = false
            let done = DispatchSemaphore(value: 0)
        }

        let path: String
        private let ownDir: String?
        private let fd: Int32
        private let state = State()

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
            let state = self.state
            Thread.detachNewThread {
                defer { state.done.signal() }
                var c: Int32 = -1
                while c < 0 {
                    state.lock.lock(); let stop = state.stopped; state.lock.unlock()
                    if stop { return }
                    var p = pollfd(fd: sfd, events: Int16(POLLIN), revents: 0)
                    if poll(&p, 1, 50) > 0 { c = accept(sfd, nil, nil) }
                }
                var buf = [UInt8](repeating: 0, count: 4096)
                while true {
                    let n = read(c, &buf, buf.count)
                    if n <= 0 { break }
                    state.lock.lock(); state.received.append(contentsOf: buf[0..<n]); state.lock.unlock()
                    if buf[0..<n].contains(10) { _ = "{}\n".withCString { write(c, $0, 3) } }
                }
                close(c)
            }
        }

        /// Bytes received once the peer closed (or after a short wait).
        func bytesAfterClose() -> Int {
            _ = state.done.wait(timeout: .now() + 2)
            state.lock.lock(); defer { state.lock.unlock() }
            return state.received.count
        }

        deinit {
            state.lock.lock(); state.stopped = true; state.lock.unlock()
            _ = state.done.wait(timeout: .now() + 2)
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

    /// What one attempt did: refused or answered, and how many bytes an
    /// impostor listener (if any) received.
    struct Outcome: Sendable {
        var refused = false
        var reply: Data?
        var impostorBytes = 0
    }

    /// `extra` rows are added to the live socket table; `tableFails` makes
    /// the table unreadable. Blocking; call inside `offPool`.
    private static func connect(_ child: ACPTestRuntimeChild?, path: String? = nil,
                                extra: [(pid: pid_t, name: String)] = [], tableFails: Bool = false) -> Outcome {
        do {
            let t = try ACPTestPinnedTransport(path: path ?? child?.runtimeEndpoint ?? "/tmp/adt-none/x.sock",
                                               timeout: 2, child: child,
                                               socketTable: { tableFails ? nil : ACPTestPinnedTransport.unixSocketTable().map { $0 + extra } })
            defer { t.close() }
            return Outcome(reply: try? t.exchange(Data("{\"method\":\"runtime.handshake\"}".utf8)))
        } catch {
            return Outcome(refused: error is ACPTestPinnedTransport.Refused)
        }
    }

    /// Launch a stand-in, prepare, connect with an impostor on the path when
    /// asked, stop everything; all off the cooperative pool.
    private static func scenario(listening: Bool = true, prepare: @escaping @Sendable (ACPTestRuntimeChild) -> Void = { _ in },
                                 impostor: Bool, path: (@Sendable (ACPTestRuntimeChild) -> String)? = nil,
                                 extra: @escaping @Sendable (ACPTestRuntimeChild) -> [(pid: pid_t, name: String)] = { _ in [] },
                                 tableFails: Bool = false) async throws -> Outcome {
        try await offPool {
            let child = try standIn(listening: listening)
            defer { child.stop() }
            prepare(child)
            let listener = impostor ? try Listener(path: child.runtimeEndpoint) : nil
            var out = connect(child, path: path?(child), extra: extra(child), tableFails: tableFails)
            out.impostorBytes = listener?.bytesAfterClose() ?? 0
            return out
        }
    }

    @Test("[Mock] the child this test launched is accepted and answers")
    func launchedChildIsAccepted() async throws {
        let o = try await Self.scenario(impostor: false)
        #expect(!o.refused)
        #expect(o.reply == Data("{}".utf8))
    }

    @Test("[Mock] another process holds the child's socket path: refused, nothing is sent")
    func anotherProcessOnTheSocketIsRefused() async throws {
        let o = try await Self.scenario(listening: false, impostor: true) // child alive, not listening
        #expect(o.refused)
        #expect(o.impostorBytes == 0)
    }

    @Test("[Mock] the child exited (still unreaped) and another process reuses its path: refused, nothing is sent")
    func pathReusedAfterExitIsRefused() async throws {
        let o = try await Self.scenario(prepare: { c in c.terminate(reap: false); unlink(c.runtimeEndpoint) }, impostor: true)
        #expect(o.refused)
        #expect(o.impostorBytes == 0)
    }

    @Test("[Mock] the child was reaped and another process reuses its path: refused, nothing is sent")
    func pathReusedAfterReapIsRefused() async throws {
        let o = try await Self.scenario(prepare: { c in c.terminate(reap: true); unlink(c.runtimeEndpoint) }, impostor: true)
        #expect(o.refused)
        #expect(o.impostorBytes == 0)
    }

    @Test("[Mock] a socket swapped in after the path check: refused, nothing is sent")
    func swappedSocketIsRefused() async throws {
        let o = try await Self.scenario(prepare: { c in unlink(c.runtimeEndpoint) }, impostor: true)
        #expect(o.refused)
        #expect(o.impostorBytes == 0)
    }

    @Test("[Mock] a path other than the child's endpoint: refused before connecting")
    func otherPathIsRefused() async throws {
        let (o, bytes) = try await offPool { () -> (Outcome, Int) in
            let child = try Self.standIn()
            defer { child.stop() }
            let elsewhere = try Listener()
            let o = Self.connect(child, path: elsewhere.path)
            return (o, elsewhere.bytesAfterClose())
        }
        #expect(o.refused)
        #expect(bytes == 0)
    }

    @Test("[Mock] the child holds a product socket: refused")
    func productHolderIsRefused() async throws {
        let product = ACPTestPinnedTransport.productDirectories()[0] + "/runtime.sock"
        let o = try await Self.scenario(impostor: false, extra: { c in [(c.pid, product)] })
        #expect(o.refused)
    }

    @Test("[Mock] a second process also holds the endpoint's socket: refused")
    func sharedEndpointIsRefused() async throws {
        // Models a listening socket inherited by another process.
        let o = try await Self.scenario(impostor: false, extra: { c in [(getppid(), c.runtimeEndpoint)] })
        #expect(o.refused)
    }

    @Test("[Mock] the socket table cannot be read (lsof failed): refused")
    func unknownSocketTableFailsClosed() async throws {
        let o = try await Self.scenario(impostor: false, tableFails: true)
        #expect(o.refused)
    }

    @Test("[Mock] no launched child: fail closed, nothing is sent")
    func missingChildFailsClosed() async throws {
        let (o, bytes) = try await offPool { () -> (Outcome, Int) in
            let l = try Listener()
            return (Self.connect(nil, path: l.path), l.bytesAfterClose())
        }
        #expect(o.refused)
        #expect(bytes == 0)
    }

    @Test("[Mock] stop() reaps the child and removes only its own /tmp/adt-acp-* directory")
    func stopCleansUp() async throws {
        let (dir, running, exists) = try await offPool { () -> (String, Bool, Bool) in
            let child = try Self.standIn()
            let dir = child.directory
            child.stop()
            return (dir, child.isRunning, FileManager.default.fileExists(atPath: dir))
        }
        #expect(dir.hasPrefix(ACPTestRuntimeChild.directoryPrefix))
        #expect(!running)
        #expect(!exists)
    }

    @Test("[Mock] lsof fields: a socket bound in the product directory names its holder")
    func lsofFieldsAreParsed() {
        let dir = "/Users/x/Library/Application Support/AgentDesktop"
        let text = "p101\nn\(dir)/runtime.sock\np202\nn/tmp/adt-1/side.runtime.sock\np303\nn\(dir)-other/x.sock\n"
        let table = ACPTestPinnedTransport.table(lsofFields: text)
        #expect(table.count == 3)
        #expect(ACPTestPinnedTransport.holders(table, productDirs: [dir]) == [101])
    }

    @Test("[Mock] the real socket table is readable (no product needed)")
    func realSocketTableAnswers() async throws {
        #expect(try await offPool { ACPTestPinnedTransport.unixSocketTable() != nil })
    }

    @Test("[Mock] Listeners nobody connects to leave no directory behind")
    func unusedListenersDoNotLeak() async throws {
        let leftovers = try await offPool { () -> [String] in
            var dirs: [String] = []
            for _ in 0..<2 {
                let l = try Listener()
                dirs.append((l.path as NSString).deletingLastPathComponent)
            }
            return dirs.filter { FileManager.default.fileExists(atPath: $0) }
        }
        #expect(leftovers.isEmpty, "\(leftovers)")
    }
}
