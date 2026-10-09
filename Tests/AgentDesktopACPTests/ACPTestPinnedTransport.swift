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
///    (`ACPTestRuntimeChild.owns`), and the socket bound at the endpoint is
///    held by that child alone; no child → refuse.
///    There is no pid-only mode (Kevin: never fall back to matching a pid);
/// 2. it runs as this user;
/// 3. its executable is readable and not the installed product under
///    /Applications;
/// 4. it has no socket bound in the product data directory (read from the
///    kernel, never by connecting); an unreadable process list → refuse.
/// Any failure closes the descriptor unused. Because the check is on the
/// connected descriptor itself, a socket swapped between the path check and
/// the connect, a reused path after the child exited, or a handshake that
/// forges its endpoint, cannot pass.
final class ACPTestPinnedTransport: RuntimeTransport {
    struct Refused: Error, CustomStringConvertible {
        let reason: String
        var description: String { "refusing the Real-test connection: \(reason)" }
    }

    /// Every bound Unix socket name and the pids holding it; nil when that
    /// cannot be determined (then the connection is refused). Injectable.
    typealias SocketTable = () -> [(pid: pid_t, name: String)]?

    private var channel: LineChannel?
    let peerPid: pid_t

    init(path: String, timeout: Double, child: ACPTestRuntimeChild?,
         socketTable: SocketTable = ACPTestPinnedTransport.unixSocketTable) throws {
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
        guard child.owns(peerPid: pid) else {
            throw Refused(reason: "peer \(pid) is not the test Runtime child \(child.pid) this test launched")
        }
        // Unknown executable or unknown holders: refuse (fail closed).
        guard let exe = Self.executablePath(pid) else {
            throw Refused(reason: "the peer's executable cannot be read")
        }
        if exe.hasPrefix("/Applications/") {
            throw Refused(reason: "peer \(pid) runs the installed product \(exe)")
        }
        guard let table = socketTable() else {
            throw Refused(reason: "the kernel's process list cannot be read")
        }
        if Self.holders(table, productDirs: Self.productDirectories()).contains(pid) {
            throw Refused(reason: "peer \(pid) holds the product's sockets")
        }
        // The socket bound at the endpoint must be held by the child alone.
        // LOCAL_PEERPID is fixed when the socket is created; this closes the
        // case of a socket made by an earlier holder of the same pid and
        // inherited by another process (b9, third review). The table comes
        // from the kernel, not lsof, whose NAME column format varies.
        let endpoint = Self.normalised(child.runtimeEndpoint)
        let atEndpoint = Set(table.filter { $0.name == endpoint }.map(\.pid))
        guard atEndpoint == [child.pid] else {
            throw Refused(reason: "the endpoint is held by \(atEndpoint.sorted()), not only the child \(child.pid)")
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

    /// Every Unix socket with a bound name in every process this user can
    /// inspect, read from the kernel (proc_listallpids, PROC_PIDLISTFDS,
    /// PROC_PIDFDSOCKETINFO); never connects, no external tool. Names are
    /// normalised (directory realpath), so a socket bound through a /tmp
    /// alias, or whose file was renamed or unlinked, still counts. A client
    /// socket has no bound name and is not listed. nil when the process
    /// list cannot be read: the caller then refuses. Processes of other
    /// users cannot be inspected; they cannot bind inside the child's 0700
    /// directory either.
    static func unixSocketTable() -> [(pid: pid_t, name: String)]? {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return nil }
        var rows: [(pid: pid_t, name: String)] = []
        for pid in pids.prefix(Int(got)) where pid > 0 {
            let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard size > 0 else { continue }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.size + 16)
            let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.size))
            guard used > 0 else { continue }
            for f in fds.prefix(Int(used) / MemoryLayout<proc_fdinfo>.size) where f.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                var info = socket_fdinfo()
                let want = Int32(MemoryLayout<socket_fdinfo>.size)
                guard proc_pidfdinfo(pid, f.proc_fd, PROC_PIDFDSOCKETINFO, &info, want) == want,
                      info.psi.soi_kind == SOCKINFO_UN else { continue }
                var path = info.psi.soi_proto.pri_un.unsi_addr.ua_sun.sun_path
                let capacity = MemoryLayout.size(ofValue: path)
                let name = withUnsafePointer(to: &path) {
                    $0.withMemoryRebound(to: UInt8.self, capacity: capacity) {
                        String(decoding: UnsafeBufferPointer(start: $0, count: strnlen(UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self), capacity)), as: UTF8.self)
                    }
                }
                guard !name.isEmpty else { continue }
                rows.append((pid, normalised(name)))
            }
        }
        return rows
    }

    /// realpath of the directory plus the file name (the file itself may be
    /// gone); the name unchanged when the directory cannot be resolved.
    static func normalised(_ path: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        guard let r = realpath(dir, nil) else { return path }
        defer { free(r) }
        return String(cString: r) + "/" + (path as NSString).lastPathComponent
    }

    /// Pids with a socket bound in a product directory.
    static func holders(_ table: [(pid: pid_t, name: String)], productDirs: [String]) -> Set<pid_t> {
        Set(table.filter { row in productDirs.contains { row.name.hasPrefix($0 + "/") } }.map(\.pid))
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
