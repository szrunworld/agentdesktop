import Foundation

/// The framing of agentdesktop.runtime/1 on a stream socket: one UTF-8 JSON
/// message per LF-terminated line, at most `RuntimeAPI.maxFrameBytes` bytes
/// with the LF. Both ends use it; bytes after one line stay buffered for
/// the next read.
public final class LineChannel {
    public enum ReadResult: Equatable {
        case line(Data)
        /// Clean end of stream between messages.
        case eof
        /// End of stream inside a message.
        case truncated
        /// A message longer than the limit; the stream cannot be resynchronised.
        case tooLarge
        /// SO_RCVTIMEO elapsed.
        case timedOut
        case ioError(Int32)
    }

    public let fd: Int32
    public let limit: Int
    private var buffer = Data()

    public init(fd: Int32, limit: Int = RuntimeAPI.maxFrameBytes) {
        self.fd = fd
        self.limit = limit
    }

    public func readLine() -> ReadResult {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let lf = buffer.firstIndex(of: 0x0A) {
                let body = buffer[buffer.startIndex..<lf]
                if body.count + 1 > limit { return .tooLarge }
                let line = Data(body)
                buffer = Data(buffer[buffer.index(after: lf)...])
                return .line(line)
            }
            if buffer.count >= limit { return .tooLarge }
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return .timedOut }
                return .ioError(errno)
            }
            if n == 0 { return buffer.isEmpty ? .eof : .truncated }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    /// Write one message and its LF. False when the peer is gone.
    @discardableResult
    public func writeLine(_ body: Data) -> Bool {
        var data = body
        data.append(0x0A)
        return data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += n
            }
            return true
        }
    }
}

/// Socket options both ends set.
public enum SocketOptions {
    /// A write to a closed peer fails with EPIPE instead of raising SIGPIPE.
    public static func noSigPipe(_ fd: Int32) -> Bool {
        var on: Int32 = 1
        return setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0
    }

    public static func receiveTimeout(_ fd: Int32, seconds: Double) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// `sockaddr_un` for `path`, or nil when the path does not fit sun_path.
    public static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        return addr
    }
}
