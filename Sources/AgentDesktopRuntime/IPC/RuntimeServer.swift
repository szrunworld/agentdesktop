import AgentDesktopProtocol
import Foundation

/// The Runtime's local endpoint: one owner-only Unix socket per Runtime
/// instance. Ownership is an exclusive flock on `<endpoint>.lock`, held for
/// the server's life, so two hosts started at once cannot both serve the
/// path; the loser fails `start()` and leaves the winner's socket alone.
/// Each connection must come from this user (getpeereid) and is served in
/// order, one line in, one line out.
public final class RuntimeServer: @unchecked Sendable {
    public enum StartError: Error, Equatable, CustomStringConvertible {
        case alreadyServed(path: String, holderPID: Int32?)
        case pathTooLong(String)
        case notOwned(String)
        case io(String)

        public var description: String {
            switch self {
            case let .alreadyServed(path, pid):
                return "another Runtime\(pid.map { " (pid \($0))" } ?? "") already serves \(path)"
            case let .pathTooLong(p): return "endpoint path does not fit a Unix socket: \(p)"
            case let .notOwned(p): return "\(p) is not owned by this user"
            case let .io(m): return m
            }
        }
    }

    public let path: String
    public let service: RuntimeService
    private let lock = NSLock()
    private var lockFD: Int32 = -1
    private var socketInode: ino_t = 0
    /// Written by stop() to wake the accept thread.
    private var wakeFDs: [Int32] = [-1, -1]
    private var acceptThread: Thread?
    private var open = 0

    public init(path: String, service: RuntimeService) {
        self.path = path
        self.service = service
        service.connectionCount = { [weak self] in self?.lock.withLock { self?.open ?? 0 } ?? 0 }
    }

    public var lockPath: String { path + ".lock" }

    public func start() throws {
        guard var addr = SocketOptions.address(path) else { throw StartError.pathTooLong(path) }
        let dir = (path as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: dir) {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        var st = stat()
        guard stat(dir, &st) == 0, st.st_uid == getuid() else { throw StartError.notOwned(dir) }

        let lfd = Darwin.open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard lfd >= 0 else { throw StartError.io("open \(lockPath): \(String(cString: strerror(errno)))") }
        if flock(lfd, LOCK_EX | LOCK_NB) != 0 {
            let holder = (try? String(contentsOfFile: lockPath, encoding: .utf8))
                .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            Darwin.close(lfd)
            throw StartError.alreadyServed(path: path, holderPID: holder)
        }
        ftruncate(lfd, 0)
        let pidLine = "\(getpid())\n"
        _ = pidLine.withCString { Darwin.write(lfd, $0, strlen($0)) }

        // Holding the lock, anything at the path is a leftover of a host
        // that died: remove it if it is a socket, refuse anything else.
        var old = stat()
        if lstat(path, &old) == 0 {
            guard (old.st_mode & S_IFMT) == S_IFSOCK, old.st_uid == getuid() else {
                Darwin.close(lfd)
                throw StartError.notOwned(path)
            }
            unlink(path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            Darwin.close(lfd)
            throw StartError.io("socket(): \(String(cString: strerror(errno)))")
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, SOMAXCONN) == 0 else {
            let m = String(cString: strerror(errno))
            Darwin.close(fd)
            unlink(path)
            Darwin.close(lfd)
            throw StartError.io("cannot listen on \(path): \(m)")
        }
        var mine = stat()
        lstat(path, &mine)
        var wake: [Int32] = [-1, -1]
        guard pipe(&wake) == 0 else {
            Darwin.close(fd)
            unlink(path)
            Darwin.close(lfd)
            throw StartError.io("pipe(): \(String(cString: strerror(errno)))")
        }

        lock.withLock {
            lockFD = lfd
            socketInode = mine.st_ino
            wakeFDs = wake
        }
        // Dedicated threads, not a shared pool: a connection blocks its
        // thread for as long as the caller keeps it open.
        let thread = Thread { [self] in acceptLoop(listen: fd, wake: wake[0]) }
        thread.name = "agentdesktop.runtime.accept"
        acceptThread = thread
        thread.start()
    }

    /// Stop accepting, remove the socket if it is still ours, release the lock.
    public func stop() {
        let (lfd, inode, wake): (Int32, ino_t, Int32) = lock.withLock {
            defer { lockFD = -1; wakeFDs[1] = -1 }
            return (lockFD, socketInode, wakeFDs[1])
        }
        if wake >= 0 {
            var b: UInt8 = 1
            _ = Darwin.write(wake, &b, 1)
            Darwin.close(wake)
        }
        var st = stat()
        if lstat(path, &st) == 0, st.st_ino == inode { unlink(path) }
        if lfd >= 0 {
            flock(lfd, LOCK_UN)
            Darwin.close(lfd)
        }
    }

    private func acceptLoop(listen fd: Int32, wake: Int32) {
        defer {
            Darwin.close(fd)
            Darwin.close(wake)
        }
        var fds = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                   pollfd(fd: wake, events: Int16(POLLIN), revents: 0)]
        while true {
            let n = poll(&fds, 2, -1)
            if n < 0 {
                if errno == EINTR { continue }
                return
            }
            if fds[1].revents != 0 { return }
            guard fds[0].revents & Int16(POLLIN) != 0 else { continue }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }
            let thread = Thread { [self] in serve(client) }
            thread.name = "agentdesktop.runtime.connection"
            thread.start()
        }
    }

    /// How long a subscribed connection waits for the client between
    /// checks for new events.
    static let pushInterval: Int32 = 200

    /// A subscribed connection: frames as events arrive, until the client
    /// unsubscribes (true: back to requests) or goes away (false). A Run's
    /// own stream also ends once that Run has ended and was fully sent.
    private func push(_ channel: LineChannel, _ connection: ConnectionState) -> Bool {
        while connection.isSubscribed {
            let frames = service.pendingEventFrames(connection)
            for f in frames {
                guard channel.writeLine(f.encodedData()) else { return false }
            }
            if !frames.isEmpty { continue }
            if service.subscriptionDrained(connection) { return false }
            guard channel.readable(within: Self.pushInterval) else { continue }
            guard case let .line(body) = channel.readLine() else { return false }
            guard channel.writeLine(service.respond(to: body, on: connection).json.encodedData()) else { return false }
        }
        return true
    }

    private func serve(_ fd: Int32) {
        defer { Darwin.close(fd) }
        // A connection whose writes could raise SIGPIPE is not served.
        guard SocketOptions.noSigPipe(fd) else { return }
        let channel = LineChannel(fd: fd)
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            let refusal = RuntimeResponse.failure(nil, RuntimeError(
                "permission_denied", "the Runtime serves only its own user", phase: .connect))
            channel.writeLine(refusal.json.encodedData())
            return
        }
        lock.withLock { open += 1 }
        defer { lock.withLock { open -= 1 } }
        let connection = ConnectionState(socketPeer: uid)
        defer { service.connectionClosed(connection) }
        while true {
            switch channel.readLine() {
            case let .line(body):
                let response = service.respond(to: body, on: connection)
                guard channel.writeLine(response.json.encodedData()) else { return }
                if connection.isSubscribed, !push(channel, connection) { return }
            case .tooLarge:
                channel.writeLine(RuntimeResponse.failure(nil, RuntimeError(
                    "frame_too_large", "a message exceeds \(RuntimeAPI.maxFrameBytes) bytes", phase: .request)).json.encodedData())
                return
            case .truncated:
                channel.writeLine(RuntimeResponse.failure(nil, .schemaInvalid(
                    "the stream ended inside a message")).json.encodedData())
                return
            case .eof, .timedOut, .ioError:
                return
            }
        }
    }
}
