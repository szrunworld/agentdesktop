import Foundation

// ACP stdio framing (docs/acp/02-protocol-version.md §3): one JSON-RPC
// message per line, delimited by "\n", UTF-8, no embedded newlines
// (spec: docs/protocol/v1/transports.mdx, "stdio").

/// One unit the splitter found in the byte stream.
public enum ACPFrameUnit: Equatable, Sendable {
    /// One line without its terminator (a trailing "\r" is removed too).
    case frame(Data)
    /// A line went past the limit; reported once, as soon as it crosses it.
    /// Its bytes are dropped up to the next newline, never buffered.
    case oversized(bytesSeen: Int)
}

/// Splits a byte stream into newline-delimited frames with a hard size
/// cap. Memory stays bounded by `maxFrameBytes` whatever the peer sends.
public struct ACPFrameSplitter: Sendable {
    public let maxFrameBytes: Int
    private var buffer = Data()
    private var discarding = false

    public init(maxFrameBytes: Int) {
        precondition(maxFrameBytes > 0)
        self.maxFrameBytes = maxFrameBytes
    }

    /// Feed bytes; returns the units they complete, in order. Blank lines
    /// are skipped (they carry no message).
    public mutating func feed(_ chunk: Data) -> [ACPFrameUnit] {
        var out: [ACPFrameUnit] = []
        var rest = chunk[...]
        // One extra byte tolerates the "\r" of a CRLF terminator.
        let cap = maxFrameBytes + 1
        while !rest.isEmpty {
            let nl = rest.firstIndex(of: 0x0A)
            let piece = rest[rest.startIndex..<(nl ?? rest.endIndex)]
            rest = nl.map { rest[rest.index(after: $0)...] } ?? rest[rest.endIndex...]
            if discarding {
                if nl != nil { discarding = false }
                continue
            }
            if buffer.count + piece.count > cap {
                out.append(.oversized(bytesSeen: buffer.count + piece.count))
                buffer = Data()
                discarding = nl == nil
                continue
            }
            buffer.append(contentsOf: piece)
            guard nl != nil else { continue }
            var line = buffer
            buffer = Data()
            if line.last == 0x0D { line.removeLast() }
            if line.count > maxFrameBytes {
                out.append(.oversized(bytesSeen: line.count))
            } else if !Self.isBlank(line) {
                out.append(.frame(line))
            }
        }
        return out
    }

    /// Bytes of an unfinished line at end of input (0 when clean).
    public var pendingByteCount: Int { buffer.count }

    private static func isBlank(_ d: Data) -> Bool {
        d.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }
    }
}
