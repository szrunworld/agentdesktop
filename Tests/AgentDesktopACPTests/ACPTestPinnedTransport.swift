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
/// process from the kernel (the `LOCAL_PEERTOKEN` audit token on this very
/// descriptor) and requires that:
/// 1. it is the Runtime child this test launched and still owns, unreaped
///    (`ACPTestRuntimeChild.owns`: pid and pid version); no child → refuse.
///    There is no pid-only mode (Kevin: never fall back to matching a pid);
/// 2. it runs as this user;
/// 3. its executable is readable and not the installed product under
///    /Applications;
/// 4. it has no socket bound in the product data directory (read-only
///    lookup, never by connecting); unknown → refuse.
/// Any failure closes the descriptor unused. Because the check is on the
/// connected descriptor itself, a socket swapped between the path check and
/// the connect, a reused path after the child exited, or a handshake that
/// forges its endpoint, cannot pass.
final class ACPTestPinnedTransport: RuntimeTransport {
    struct Refused: Error, CustomStringConvertible {
        let reason: String
        var description: String { "refusing the Real-test connection: \(reason)" }
    }

    /// Who holds the product's sockets; nil when that cannot be determined
    /// (then the connection is refused). Injectable for tests.
    typealias ProductHolders = () -> Set<pid_t>?

    private var channel: LineChannel?
    let peerPid: pid_t

    init(path: String, timeout: Double, child: ACPTestRuntimeChild?,
         productHolders: ProductHolders = ACPTestPinnedTransport.productSocketHolders) throws {
        _ = try ACPTestEndpointGuard.check(path)
        guard let child else {
            throw Refused(reason: "no test-launched Runtime child (fail closed)")
        }
        guard path == child.runtimeEndpoint else {
            throw Refused(reason: "\(path) is not the endpoint of the launched test Runtime")
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
        var token = audit_token_t()
        var tlen = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &tlen) == 0,
              pid_t(bitPattern: token.val.5) == pid else {
            throw Refused(reason: "the kernel's audit token does not match the peer pid")
        }
        guard child.owns(peerPid: pid, peerPidVersion: token.val.7) else {
            throw Refused(reason: "peer \(pid) is not the test Runtime child \(child.pid) this test launched")
        }
        // Unknown executable or unknown holders: refuse (fail closed).
        guard let exe = Self.executablePath(pid) else {
            throw Refused(reason: "the peer's executable cannot be read")
        }
        if exe.hasPrefix("/Applications/") {
            throw Refused(reason: "peer \(pid) runs the installed product \(exe)")
        }
        guard let holders = productHolders() else {
            throw Refused(reason: "the product's socket holders cannot be determined")
        }
        if holders.contains(pid) {
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

    /// Processes with a Unix socket bound under the product data directory,
    /// matched on the socket's bound name from `lsof -U` (read-only; never
    /// connects), so a socket whose file was renamed or unlinked still
    /// counts. nil when lsof fails: the caller then refuses.
    static func productSocketHolders() -> Set<pid_t>? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-b", "-nP", "-U", "-F", "pn"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        // Any non-zero exit is unknown (b9): with -U there are always sockets.
        guard p.terminationStatus == 0 else { return nil }
        return holders(lsofFields: String(decoding: data, as: UTF8.self), productDirs: productDirectories())
    }

    /// `lsof -F pn` output → pids whose socket name is in a product directory.
    static func holders(lsofFields text: String, productDirs: [String]) -> Set<pid_t> {
        var out = Set<pid_t>()
        var current: pid_t?
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("p") { current = pid_t(line.dropFirst()) }
            else if line.hasPrefix("n"), let pid = current {
                let name = String(line.dropFirst())
                if productDirs.contains(where: { name.hasPrefix($0 + "/") }) { out.insert(pid) }
            }
        }
        return out
    }

    static func productDirectories() -> [String] {
        var homes = [NSHomeDirectory()]
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { homes.append(String(cString: dir)) }
        var dirs = Set<String>()
        for home in homes {
            let d = home + "/Library/Application Support/AgentDesktop"
            dirs.insert(d)
            if let r = realpath(d, nil) { dirs.insert(String(cString: r)); free(r) }
        }
        return Array(dirs)
    }

    /// A client factory for Real tests: every connection is kernel-pinned
    /// (layer 1) and the stated endpoint is checked after the handshake
    /// (layer 2). Only the given child is ever accepted.
    static func verifiedFactory(child: ACPTestRuntimeChild, name: String) throws -> ACPBridgeClientFactory {
        let checked = try ACPTestEndpointGuard.check(child.runtimeEndpoint)
        let ep = Endpoint(path: checked, source: .environment)
        return { role in
            ACPTestVerifiedClient(SocketRuntimeClient(
                endpoint: ep, info: ClientInfo(name: name, version: "0"),
                timeout: role == .control ? 10 : 1,
                connect: { p, t in try ACPTestPinnedTransport(path: p, timeout: t, child: child) }))
        }
    }
}
