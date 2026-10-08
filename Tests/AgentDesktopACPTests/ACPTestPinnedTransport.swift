import AgentDesktopClient
import AgentDesktopProtocol
import Darwin
import Foundation
@testable import AgentDesktopACP

/// A transport for ACP Real-Runtime tests whose peer is pinned by the kernel,
/// not by anything the peer says (Kevin on #141: test isolation must rest on
/// an OS-trusted identity, never on the tested process's own claims).
///
/// After `connect(2)` and before a single byte is written it reads the peer
/// process from the kernel (`LOCAL_PEERPID` on this very descriptor) and
/// requires that:
/// 1. it is the test Runtime the operator launched (`expectedPid`, given by
///    whoever started the test copy; no pid → refuse, fail closed);
/// 2. its executable is not the installed product under /Applications;
/// 3. it is not a process that holds the product's data-directory sockets
///    open (looked up read-only, never by connecting to them).
/// Any failure closes the descriptor unused. Because the check is on the
/// connected descriptor itself, a socket swapped between the path check and
/// the connect, or a handshake that forges its endpoint, cannot pass.
final class ACPTestPinnedTransport: RuntimeTransport {
    struct Refused: Error, CustomStringConvertible {
        let reason: String
        var description: String { "refusing the Real-test connection: \(reason)" }
    }

    /// Who may hold the product's sockets; injectable for tests.
    typealias ProductHolders = () -> Set<pid_t>

    private var channel: LineChannel?
    let peerPid: pid_t

    init(path: String, timeout: Double, expectedPid: pid_t?,
         productHolders: ProductHolders = ACPTestPinnedTransport.productSocketHolders) throws {
        _ = try ACPTestEndpointGuard.check(path)
        guard let expectedPid, expectedPid > 0 else {
            throw Refused(reason: "no expected test Runtime pid was given (fail closed)")
        }
        guard var addr = SocketOptions.address(path) else { throw Refused(reason: "bad socket path \(path)") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Refused(reason: "socket() failed") }
        var keep = false
        defer { if !keep { Darwin.close(fd) } }
        guard SocketOptions.noSigPipe(fd) else { throw Refused(reason: "SO_NOSIGPIPE failed") }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { throw Refused(reason: "connect failed: \(String(cString: strerror(errno)))") }

        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) == 0, pid > 0 else {
            throw Refused(reason: "the kernel did not report the peer process")
        }
        // Same user, by the kernel's word on this descriptor.
        var peerUid: uid_t = 0, peerGid: gid_t = 0
        guard getpeereid(fd, &peerUid, &peerGid) == 0, peerUid == getuid() else {
            throw Refused(reason: "the peer is not running as this user")
        }
        guard pid == expectedPid else {
            throw Refused(reason: "peer pid \(pid) is not the launched test Runtime \(expectedPid)")
        }
        if let exe = Self.executablePath(pid), exe.hasPrefix("/Applications/") {
            throw Refused(reason: "peer \(pid) runs the installed product \(exe)")
        }
        if productHolders().contains(pid) {
            throw Refused(reason: "peer \(pid) holds the product's sockets")
        }
        SocketOptions.receiveTimeout(fd, seconds: timeout)
        peerPid = pid
        channel = LineChannel(fd: fd)
        keep = true
    }

    func exchange(_ message: Data) throws -> Data {
        guard let channel else { throw RuntimeError.connectionLost("the connection is closed") }
        guard channel.writeLine(message) else { throw RuntimeError.connectionLost("write failed") }
        switch channel.readLine() {
        case let .line(data): return data
        default: throw RuntimeError.connectionLost("no reply line from the test Runtime")
        }
    }

    func receive() throws -> Data? {
        guard let channel else { throw RuntimeError.connectionLost("the connection is closed") }
        guard channel.readable(within: 1000) else { return nil }
        switch channel.readLine() {
        case let .line(data): return data
        case .timedOut: return nil
        default: throw RuntimeError.connectionLost("the test Runtime closed the stream")
        }
    }

    func close() {
        if let channel { Darwin.close(channel.fd) }
        channel = nil
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    /// Processes holding any entry of the product data directory open, via
    /// `lsof -t` (read-only; never connects). If lsof cannot run, nothing is
    /// known, and the pid pin plus the /Applications check still apply.
    static func productSocketHolders() -> Set<pid_t> {
        let paths = ACPTestEndpointGuard.productSockets()
        guard !paths.isEmpty else { return [] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-t"] + paths
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return Set(text.split(whereSeparator: \.isNewline).compactMap { pid_t($0) })
    }

    /// A client factory for Real tests: every connection is kernel-pinned
    /// (layer 1) and the stated endpoint is checked after the handshake
    /// (layer 2). Without the pid variable every connection is refused.
    static func verifiedFactory(path: String, pidEnv: String, name: String) throws -> ACPBridgeClientFactory {
        let checked = try ACPTestEndpointGuard.check(path)
        let expected = expectedPid(env: pidEnv)
        let ep = Endpoint(path: checked, source: .environment)
        return { role in
            ACPTestVerifiedClient(SocketRuntimeClient(
                endpoint: ep, info: ClientInfo(name: name, version: "0"),
                timeout: role == .control ? 10 : 1,
                connect: { p, t in try ACPTestPinnedTransport(path: p, timeout: t, expectedPid: expected) }))
        }
    }

    /// The operator-supplied pid of the launched test Runtime, from `name`.
    static func expectedPid(env name: String) -> pid_t? {
        ProcessInfo.processInfo.environment[name].flatMap { pid_t($0) }
    }
}
