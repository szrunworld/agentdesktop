import AgentDesktopClient
import AgentDesktopProtocol
import Darwin
import Foundation
import Testing

/// [Mock] Kernel-pinned Real-test transport (Kevin on #141). A real Unix
/// socket listener in this test process stands in for "whatever is behind the
/// path"; the bytes it receives prove that a refused connection sends nothing.
@Suite("[Mock] Real-test pinned transport", .serialized)
struct CurPinnedTransportTests {
    /// Listens once, accepts one connection, counts every byte until EOF.
    final class Listener: @unchecked Sendable {
        let dir: String
        let path: String
        private let fd: Int32
        private let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var received = Data()

        init() throws {
            dir = "/tmp/adt-ptest-\(UUID().uuidString.prefix(8))"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            path = dir + "/side.runtime.sock"
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var addr = SocketOptions.address(path)!
            let sfd = fd
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sfd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            precondition(rc == 0 && listen(sfd, 4) == 0)
            Thread.detachNewThread { [self] in
                let c = accept(sfd, nil, nil)
                if c >= 0 {
                    var buf = [UInt8](repeating: 0, count: 4096)
                    while true {
                        let n = read(c, &buf, buf.count)
                        if n <= 0 { break }
                        lock.lock(); received.append(contentsOf: buf[0..<n]); lock.unlock()
                        // Answer one line so an accepted client can complete an exchange.
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

        deinit { close(fd); try? FileManager.default.removeItem(atPath: dir) }
    }

    private func attempt(_ l: Listener, expected: pid_t?, holders: Set<pid_t>? = []) -> Error? {
        do {
            let t = try ACPTestPinnedTransport(path: l.path, timeout: 1, expectedPid: expected, productHolders: { holders })
            _ = try? t.exchange(Data("{\"method\":\"runtime.handshake\"}".utf8))
            t.close()
            return nil
        } catch { return error }
    }

    @Test("[Mock] the launched test Runtime is accepted and served")
    func expectedPeerIsAccepted() throws {
        let l = try Listener()
        #expect(attempt(l, expected: getpid()) == nil)
        #expect(l.bytesAfterClose() > 0)
    }

    @Test("[Mock] socket replaced after the path check: another process answers, nothing is sent")
    func swappedSocketIsRefusedBeforeAnyByte() throws {
        // The operator launched a test Runtime (stand-in: a child process),
        // but the path is now served by this process instead.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { child.terminate() }
        let l = try Listener()
        let e = attempt(l, expected: child.processIdentifier)
        #expect(e is ACPTestPinnedTransport.Refused)
        #expect(l.bytesAfterClose() == 0)
    }

    @Test("[Mock] a forged handshake endpoint never matters: refused before the handshake")
    func forgedHandshakeIsNeverReached() throws {
        let l = try Listener()
        let e = attempt(l, expected: getpid() == 1 ? 2 : 1)
        #expect(e is ACPTestPinnedTransport.Refused)
        #expect(l.bytesAfterClose() == 0)
    }

    @Test("[Mock] a peer holding the product's sockets is refused, nothing is sent")
    func productRuntimeIsRefused() throws {
        let l = try Listener()
        let e = attempt(l, expected: getpid(), holders: [getpid()])
        #expect(e is ACPTestPinnedTransport.Refused)
        #expect(l.bytesAfterClose() == 0)
    }

    @Test("[Mock] holders cannot be determined (lsof failed): fail closed, nothing is sent")
    func unknownHoldersFailClosed() throws {
        let l = try Listener()
        let e = attempt(l, expected: getpid(), holders: nil)
        #expect(e is ACPTestPinnedTransport.Refused)
        #expect(l.bytesAfterClose() == 0)
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

    @Test("[Mock] no expected pid: fail closed, nothing is sent")
    func missingPidFailsClosed() throws {
        let l = try Listener()
        let e = attempt(l, expected: nil)
        #expect(e is ACPTestPinnedTransport.Refused)
        #expect(l.bytesAfterClose() == 0)
    }
}
