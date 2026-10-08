import AgentDesktopProtocol
import Foundation

/// A connected request channel to the Runtime.
public protocol RuntimeTransport: AnyObject {
    /// Send one message and wait for its reply line.
    func exchange(_ message: Data) throws -> Data
    /// The next line the Runtime pushed (event subscriptions); nil when
    /// none arrived within the receive timeout.
    func receive() throws -> Data?
    func close()
}

extension RuntimeTransport {
    public func receive() throws -> Data? {
        throw RuntimeError("capability_missing", "this transport does not carry event subscriptions", phase: .local)
    }
}

/// Line-framed JSON over the owner-only Unix socket.
public final class UnixSocketTransport: RuntimeTransport {
    private var channel: LineChannel?
    public let path: String

    /// Connect, or throw `runtime_offline` / `permission_denied` with
    /// `notSent: true`: nothing has been sent when connecting fails.
    public init(path: String, timeout: Double) throws {
        self.path = path
        if let refusal = EndpointResolver.inspect(path) { throw refusal }
        guard var addr = SocketOptions.address(path) else {
            throw RuntimeError("invalid_argument", "endpoint path is longer than a Unix socket allows: \(path)",
                               phase: .local, notSent: true)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw RuntimeError.runtimeOffline("socket(): \(String(cString: strerror(errno)))", endpoint: path)
        }
        guard SocketOptions.noSigPipe(fd) else {
            Darwin.close(fd)
            throw RuntimeError.runtimeOffline("cannot guard the socket against SIGPIPE", endpoint: path)
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 {
            let e = errno
            Darwin.close(fd)
            if e == EACCES || e == EPERM {
                throw RuntimeError("permission_denied", "connect \(path): \(String(cString: strerror(e)))",
                                   phase: .connect, notSent: true)
            }
            throw RuntimeError.runtimeOffline("no Runtime is accepting on \(path) (\(String(cString: strerror(e))))",
                                              endpoint: path)
        }
        SocketOptions.receiveTimeout(fd, seconds: timeout)
        channel = LineChannel(fd: fd)
    }

    public func exchange(_ message: Data) throws -> Data {
        guard let channel else { throw RuntimeError.connectionLost("the connection is closed") }
        guard channel.writeLine(message) else {
            throw RuntimeError.connectionLost("the Runtime closed the connection while the request was sent")
        }
        switch channel.readLine() {
        case let .line(data): return data
        case .timedOut: throw RuntimeError.connectionLost("no reply from the Runtime within the timeout")
        case .eof, .truncated: throw RuntimeError.connectionLost("the Runtime closed the connection before replying")
        case .tooLarge: throw RuntimeError.connectionLost("the reply exceeds \(RuntimeAPI.maxFrameBytes) bytes")
        case let .ioError(e): throw RuntimeError.connectionLost("read: \(String(cString: strerror(e)))")
        }
    }

    public func receive() throws -> Data? {
        guard let channel else { throw RuntimeError.connectionLost("the connection is closed") }
        // Back within a second when idle, so a watcher can notice Ctrl-C.
        guard channel.readable(within: 1000) else { return nil }
        switch channel.readLine() {
        case let .line(data): return data
        case .timedOut: return nil
        case .eof: throw RuntimeError.connectionLost("the Runtime closed the subscription")
        case .truncated: throw RuntimeError.connectionLost("the Runtime closed the connection inside a message")
        case .tooLarge: throw RuntimeError.connectionLost("a pushed message exceeds \(RuntimeAPI.maxFrameBytes) bytes")
        case let .ioError(e): throw RuntimeError.connectionLost("read: \(String(cString: strerror(e)))")
        }
    }

    public func close() {
        if let channel { Darwin.close(channel.fd) }
        channel = nil
    }

    deinit { close() }
}
