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
            let dir = ACPTestScratch.tmp("ptest")
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
        /// Why it was refused, so a CI failure says what happened.
        var reason = ""
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
            return Outcome(refused: error is ACPTestPinnedTransport.Refused, reason: "\(error)")
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
        #expect(!o.refused, "\(o.reason)")
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

    @Test("[Mock] the kernel's socket table cannot be read: refused")
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

    @Test("[Mock] a launched child inherits no descriptor but stdio")
    func childInheritsNoDescriptors() async throws {
        // A pipe open in this process while the child starts: once this
        // side closes its write end, the reader must see EOF even though
        // the child is still running.
        let eof = try await offPool { () -> Bool in
            var fds: [Int32] = [0, 0]
            precondition(pipe(&fds) == 0)
            for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) } // this process's own spawns must not keep it either
            let child = try ACPTestRuntimeChild.launch(executable: "/bin/sleep", arguments: ["30"], waitForEndpoint: false)
            defer { child.stop(); close(fds[0]) }
            close(fds[1])
            var p = pollfd(fd: fds[0], events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 2000) > 0 else { return false }
            var byte: UInt8 = 0
            return read(fds[0], &byte, 1) == 0
        }
        #expect(eof)
    }

    @Test("[Mock] product holders: a socket bound in the product directory names its holder")
    func productHoldersAreFound() {
        let dir = "/Users/x/Library/Application Support/AgentDesktop"
        let table: [(pid: pid_t, name: String)] = [(101, dir + "/runtime.sock"), (202, "/private/tmp/adt-1/side.runtime.sock"),
                                                   (303, dir + "-other/x.sock")]
        #expect(ACPTestPinnedTransport.holders(table, productDirs: [dir]) == [101])
    }

    @Test("[Mock] the kernel's socket table lists the child's listener, not this process's client socket")
    func realSocketTableIsRight() async throws {
        let (rows, childPid, endpoint) = try await offPool { () -> ([String], pid_t, String) in
            let child = try Self.standIn()
            defer { child.stop() }
            // A connected client in this process must not count as a holder.
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            defer { close(fd) }
            var addr = SocketOptions.address(child.runtimeEndpoint)!
            _ = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            let table = ACPTestPinnedTransport.unixSocketTable() ?? []
            let at = table.filter { $0.name == ACPTestPinnedTransport.normalised(child.runtimeEndpoint) }
            return (at.map { "\($0.pid)" }, child.pid, child.runtimeEndpoint)
        }
        #expect(Set(rows) == ["\(childPid)"], "\(endpoint): \(rows)")
    }

    @Test("[Mock] names are normalised through the directory's realpath")
    func namesAreNormalised() {
        #expect(ACPTestPinnedTransport.normalised("/tmp/x-does-not-matter/../") != "")
        #expect(ACPTestPinnedTransport.normalised("/tmp/s.sock") == "/private/tmp/s.sock")
    }

    @Test("[Mock] the product is recognised by its bundle id, not by living under /Applications")
    func productIsRecognisedByBundleId() throws {
        let root = ACPTestScratch.dir("bundle")
        defer { try? FileManager.default.removeItem(at: root) }
        func app(_ name: String, _ id: String) throws -> String {
            let contents = root.appendingPathComponent("\(name).app/Contents")
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            try (["CFBundleIdentifier": id] as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"))
            return contents.appendingPathComponent("MacOS/\(name)").path
        }
        #expect(ACPTestPinnedTransport.isProductExecutable(try app("Agent Desktop", "com.agentdesktop.app")))
        // CI's python lives in an Xcode bundle under /Applications: not the product.
        #expect(!ACPTestPinnedTransport.isProductExecutable(try app("Xcode_16.4", "com.apple.dt.Xcode")))
        #expect(!ACPTestPinnedTransport.isProductExecutable("/usr/bin/python3"))
    }

    @Test("[Mock] the stale sweep keeps a directory still served, recently changed, or when the socket table is unknown")
    func staleSweepKeepsWhatMayBeInUse() async throws {
        let result = try await offPool { () -> [String: Bool] in
            // A pid that is surely gone: a child that already exited and was reaped.
            var dead: pid_t = 0
            var argv: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
            defer { free(argv[0]) }
            precondition(posix_spawn(&dead, "/usr/bin/true", nil, nil, &argv, environ) == 0)
            var st: Int32 = 0
            waitpid(dead, &st, 0)
            let tmp = ACPTestScratch.dir("sweep")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            func make(_ id: String) throws -> String {
                let name = "adt-acp-\(dead)-\(id)"
                try FileManager.default.createDirectory(atPath: tmp.path + "/" + name, withIntermediateDirectories: true)
                return name
            }
            let served = try make("served"), idle = try make("idleOK"), fresh = try make("fresh1")
            // An orphaned Runtime would still have its socket bound in `served`.
            let socketName = ACPTestPinnedTransport.normalised(tmp.path + "/" + served + "/side.runtime.sock")
            let table: () -> [(pid: pid_t, name: String)]? = { [(pid_t(4242), socketName)] }
            let later = Date().addingTimeInterval(3 * 3600)
            let unknown = ACPTestScratch.sweep(tmp: tmp.path, table: { nil }, now: later)
            let recent = ACPTestScratch.sweep(tmp: tmp.path, table: table, now: Date())
            let removed = ACPTestScratch.sweep(tmp: tmp.path, table: table, now: later)
            let exists = { (n: String) in FileManager.default.fileExists(atPath: tmp.path + "/" + n) }
            return ["unknownTableRemovesNothing": unknown.isEmpty,
                    "recentRemovesNothing": recent.isEmpty,
                    "idleRemoved": removed == [idle] || Set(removed) == [idle, fresh],
                    "servedKept": exists(served),
                    "idleGone": !exists(idle)]
        }
        for (k, v) in result { #expect(v, "\(k)") }
    }

    @Test("[Mock] only this scheme's /tmp names are recognised for the stale sweep")
    func staleSweepNamesAreStrict() {
        #expect(ACPTestScratch.schemePid("adt-acp-123-AbC123") == 123)
        #expect(ACPTestScratch.schemePid("adt-ptest-9-1A2B3C4D") == 9)
        #expect(ACPTestScratch.schemePid("adt-curtest-vc-77-0F0F0F0F") == 77)
        for other in ["adt-acp", "adt-acp-AbC123", "adt-pwd", "adt-g2-last", "adt-acp-12-short", "adt-acc",
                      "adt-curtest-VC-1-abcdef", "ads-A92A25A7", "adt-acp-1-abc/def", "adt-x-1-abcdef"] {
            #expect(ACPTestScratch.schemePid(other) == nil, "\(other)")
        }
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
