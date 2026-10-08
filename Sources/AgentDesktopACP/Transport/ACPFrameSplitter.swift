import AgentDesktopProtocol
import Foundation

// ACP stdio framing (docs/acp/02-protocol-version.md §3): one JSON-RPC
// message per line, delimited by "\n", UTF-8, no embedded newlines
// (spec: docs/protocol/v1/transports.mdx, "stdio").

/// One unit the splitter found in the byte stream.
public enum ACPFrameUnit: Equatable, Sendable {
    /// One line without its terminator (a trailing "\r" is removed too).
    case frame(Data)
    /// A line went past the limit; reported once, as soon as it crosses it.
    /// Its bytes are dropped up to the next newline, never buffered. `head`
    /// is the line's first bytes (at most `ACPFrameSplitter.headBytes`), so
    /// the request id can still be answered.
    case oversized(bytesSeen: Int, head: Data)
}

/// Splits a byte stream into newline-delimited frames with a hard size
/// cap. Memory stays bounded by `maxFrameBytes` whatever the peer sends.
public struct ACPFrameSplitter: Sendable {
    public let maxFrameBytes: Int
    /// How much of an oversized line is kept to find its request id.
    public static let headBytes = 4096
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
                let head = Data((buffer + piece).prefix(Self.headBytes))
                out.append(.oversized(bytesSeen: buffer.count + piece.count, head: head))
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
                out.append(.oversized(bytesSeen: line.count, head: Data(line.prefix(Self.headBytes))))
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

extension ACPFrameSplitter {
    /// The top-level `"id"` of a JSON object whose text may be cut off, when
    /// it appears complete in `head` before the cut: an integer or a string.
    /// Lets an oversized request get its error under its own id, so the
    /// editor is not left waiting. Anything unclear gives nil (answer with
    /// id null).
    public static func peekRequestId(_ head: Data) -> JSONValue? {
        let b = [UInt8](head)
        var i = 0
        func ws() { while i < b.count, b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0D || b[i] == 0x0A { i += 1 } }
        /// A complete JSON string at i (on '"'); returns its raw bytes between quotes.
        func string() -> [UInt8]? {
            guard i < b.count, b[i] == 0x22 else { return nil }
            i += 1
            let start = i
            while i < b.count {
                if b[i] == 0x5C { i += 2; continue }
                if b[i] == 0x22 { let s = Array(b[start..<i]); i += 1; return s }
                i += 1
            }
            return nil
        }
        /// Skip one complete value; false if it is cut off or malformed.
        func skipValue() -> Bool {
            guard i < b.count else { return false }
            switch b[i] {
            case 0x22: return string() != nil
            case 0x7B, 0x5B:
                var depth = 0
                while i < b.count {
                    switch b[i] {
                    case 0x22: if string() == nil { return false }; continue
                    case 0x7B, 0x5B: depth += 1
                    case 0x7D, 0x5D: depth -= 1; if depth == 0 { i += 1; return true }
                    default: break
                    }
                    i += 1
                }
                return false
            default:
                let start = i
                while i < b.count, !(b[i] == 0x2C || b[i] == 0x7D || b[i] == 0x5D || b[i] == 0x20
                                     || b[i] == 0x09 || b[i] == 0x0D || b[i] == 0x0A) { i += 1 }
                return i > start && i < b.count
            }
        }
        ws()
        guard i < b.count, b[i] == 0x7B else { return nil }
        i += 1
        while true {
            ws()
            guard let key = string() else { return nil }
            ws()
            guard i < b.count, b[i] == 0x3A else { return nil }
            i += 1
            ws()
            if key == Array("id".utf8) {
                let start = i
                guard skipValue() else { return nil }
                let text = Data(b[start..<i])
                guard let v = try? StrictJSON.parse(text), ACPJsonRpcCodec.isValidId(v), !v.isNull else { return nil }
                if case .number = v, v.intValue == nil { return nil }
                return v
            }
            guard skipValue() else { return nil }
            ws()
            guard i < b.count, b[i] == 0x2C else { return nil }
            i += 1
        }
    }
}
