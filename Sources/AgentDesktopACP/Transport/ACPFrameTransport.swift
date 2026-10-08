import Darwin
import Foundation

/// A byte pipe to one editor. `chunks` ends when the peer closes its side
/// or reading fails; `write` throws once the peer is gone.
public protocol ACPFrameTransport: AnyObject, Sendable {
    var chunks: AsyncStream<Data> { get }
    func write(_ data: Data) async throws
    /// Stop writing and reading; idempotent.
    func close()
}

public struct ACPFrameTransportClosed: Error, Equatable, Sendable {
    public var reason: String
    public init(reason: String) { self.reason = reason }
}

// MARK: - stdio / file descriptors

/// The stdio transport: reads `input` on a dedicated thread with blocking
/// `read(2)`, writes `output` with `write(2)`. A broken output pipe is an
/// error, never a SIGPIPE: the descriptor gets F_SETNOSIGPIPE.
public final class ACPStdioFileTransport: ACPFrameTransport, @unchecked Sendable {
    public let chunks: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let inputFD: Int32
    private let outputFD: Int32
    private let lock = NSLock()
    private var closed = false
    private var started = false
    private let readSize: Int

    /// - Parameters: input/output default to the process's stdin/stdout.
    public init(input: FileHandle = .standardInput, output: FileHandle = .standardOutput,
                readSize: Int = 64 * 1024) {
        inputFD = input.fileDescriptor
        outputFD = output.fileDescriptor
        self.readSize = readSize
        (chunks, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        // Writing to a closed pipe must return EPIPE instead of killing us.
        _ = fcntl(outputFD, F_SETNOSIGPIPE, 1)
    }

    /// Start the reader thread. Called by the connection; idempotent.
    public func start() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()
        let fd = inputFD, size = readSize, cont = continuation
        let thread = Thread {
            var buf = [UInt8](repeating: 0, count: size)
            while true {
                let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, size) }
                if n > 0 {
                    cont.yield(Data(buf[0..<n]))
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    break  // EOF or error: the editor's side is gone.
                }
            }
            cont.finish()
        }
        thread.name = "acp-stdio-reader"
        thread.start()
    }

    public func write(_ data: Data) async throws {
        try writeSync(data)
    }

    private func writeSync(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw ACPFrameTransportClosed(reason: "transport closed") }
        try data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = Darwin.write(outputFD, raw.baseAddress! + off, raw.count - off)
                if n > 0 { off += n; continue }
                if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                throw ACPFrameTransportClosed(reason: "write failed: \(String(cString: strerror(errno)))")
            }
        }
    }

    public func close() {
        lock.lock()
        let was = closed
        closed = true
        lock.unlock()
        if !was { continuation.finish() }
    }
}

// MARK: - in-memory pair (tests, in-process editors)

/// One end of an in-memory duplex pipe. `pair()` returns two ends whose
/// writes arrive as the other's chunks.
public final class ACPStdioMemoryTransport: ACPFrameTransport, @unchecked Sendable {
    public let chunks: AsyncStream<Data>
    fileprivate let continuation: AsyncStream<Data>.Continuation
    fileprivate weak var peer: ACPStdioMemoryTransport?
    private let lock = NSLock()
    private var closed = false

    private init() {
        (chunks, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
    }

    public static func pair() -> (ACPStdioMemoryTransport, ACPStdioMemoryTransport) {
        let a = ACPStdioMemoryTransport(), b = ACPStdioMemoryTransport()
        a.peer = b; b.peer = a
        return (a, b)
    }

    public func write(_ data: Data) async throws {
        guard !isClosed, let peer, !peer.isClosed else {
            throw ACPFrameTransportClosed(reason: "peer closed")
        }
        if case .terminated = peer.continuation.yield(data) {
            throw ACPFrameTransportClosed(reason: "peer closed")
        }
    }

    fileprivate var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    /// Close this end: the other end sees end of input.
    public func close() {
        lock.lock()
        let was = closed
        closed = true
        lock.unlock()
        guard !was else { return }
        continuation.finish()
        peer?.continuation.finish()
    }

    /// Half-close: the other end reads EOF, this end can still read.
    public func closeWriteSide() {
        peer?.continuation.finish()
    }
}
