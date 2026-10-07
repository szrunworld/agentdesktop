import AgentDesktopContracts
import Foundation

/// Serves contract v1 on a Unix socket: one LF-terminated request per
/// connection, one response line, then close (spec §05.1). The directory is
/// made 0700 and the socket 0600; a peer of another user is dropped before
/// anything is read. Closing a connection never cancels an accepted run.
///
/// The product endpoint is the engine's control socket, which will decode
/// both v1 and legacy frames into the same Runtime; until it does, this
/// server lets the CLI and tests talk to the service directly.
public final class RpcSocketServer: @unchecked Sendable {
    public let path: String
    private let routerFor: @Sendable (uid_t) -> RpcRouter?
    private var listener: Int32 = -1
    private let queue = DispatchQueue(label: "agentdesktop.rpc.accept")
    private let lock = NSLock()
    private var stopped = false

    /// - Parameter routerFor: the router for a connected peer's uid, or nil
    ///   to refuse it. The default allows only this process's user.
    public init(path: String, routerFor: @escaping @Sendable (uid_t) -> RpcRouter?) {
        self.path = path
        self.routerFor = routerFor
    }

    public convenience init(path: String, router: RpcRouter) {
        let me = getuid()
        self.init(path: path) { $0 == me ? router : nil }
    }

    public func start() throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard chmod(dir, 0o700) == 0 else { throw posix("chmod") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posix("socket") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw ContractError(.validationError, "socket path is too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes); $0[bytes.count] = 0 }
        // Refuse to take over a live endpoint; only a dead socket file is replaced.
        if FileManager.default.fileExists(atPath: path) {
            if Self.isListening(path) { close(fd); throw ContractError(.desktopBusy, "another server owns \(path)") }
            unlink(path)
        }
        // Never change the process umask here: it is shared by every thread,
        // and a directory another thread creates meanwhile would lose its
        // execute bit. The 0700 directory keeps the socket private until
        // chmod makes it 0600.
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw posix("bind")
        }
        listener = fd
        queue.async { [self] in acceptLoop(fd) }
    }

    public func stop() {
        lock.lock()
        let fd = listener
        stopped = true
        listener = -1
        lock.unlock()
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
            unlink(path)
        }
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    private func acceptLoop(_ fd: Int32) {
        while !isStopped {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            // A peer that leaves early must cost a write error, never the process.
            var on: Int32 = 1
            var uid: uid_t = 0, gid: gid_t = 0
            guard setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0,
                  getpeereid(client, &uid, &gid) == 0, let router = routerFor(uid) else {
                close(client)
                continue
            }
            Task.detached {
                let read = FrameReader.read(fd: client)
                // A connection that sent nothing (a liveness probe) gets no answer.
                if case let .truncated(body) = read, body.isEmpty {
                    close(client)
                    return
                }
                let reply = await router.respond(to: read)
                reply.withUnsafeBytes { buf in
                    var off = 0
                    while off < buf.count {
                        let n = write(client, buf.baseAddress! + off, buf.count - off)
                        if n < 0 && errno == EINTR { continue }
                        if n <= 0 { break }
                        off += n
                    }
                }
                close(client)
            }
        }
    }

    static func isListening(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes); $0[bytes.count] = 0 }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
    }

    private func posix(_ what: String) -> ContractError {
        ContractError(.internalError, "\(what): \(String(cString: strerror(errno)))")
    }
}
