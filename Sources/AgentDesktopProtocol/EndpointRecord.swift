import Darwin
import Foundation

/// What the Runtime that holds an endpoint writes into its lock file
/// (`<endpoint>.lock`, owner-only): which instance it is and whether it has
/// started listening.
///
/// A record is a clue for diagnosis, never proof that a Runtime is running:
/// a crashed owner leaves its record behind, and its pid may since belong
/// to another process. Only a live answer on the socket, checked against
/// the record and the socket's peer, says who is there. It holds no secret.
public struct EndpointRecord: Equatable, Sendable {
    public var product: String
    public var productVersion: String
    public var pid: Int32
    public var instanceId: String
    public var endpoint: String
    /// True once the socket is bound and listening.
    public var listening: Bool
    /// When this owner took the lock.
    public var since: String

    public init(product: String, productVersion: String, pid: Int32, instanceId: String, endpoint: String,
                listening: Bool, since: String) {
        self.product = product
        self.productVersion = productVersion
        self.pid = pid
        self.instanceId = instanceId
        self.endpoint = endpoint
        self.listening = listening
        self.since = since
    }

    public var json: JSONValue {
        .obj([("product", .string(product)), ("productVersion", .string(productVersion)), ("pid", .int(Int(pid))),
              ("instanceId", .string(instanceId)), ("endpoint", .string(endpoint)), ("listening", .bool(listening)),
              ("since", .string(since))])
    }

    /// One line of JSON, as written to the lock file.
    public var line: String { json.encoded() + "\n" }

    /// A record from a lock file's contents. A file holding only a pid (as
    /// Runtimes before this record wrote) gives `legacyPID`.
    public static func parse(_ text: String) -> (record: EndpointRecord?, legacyPID: Int32?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let pid = Int32(trimmed) { return (nil, pid) }
        guard let v = try? StrictJSON.parse(Data(trimmed.utf8)),
              let product = v["product"]?.stringValue, let version = v["productVersion"]?.stringValue,
              let pid = v["pid"]?.intValue, let instance = v["instanceId"]?.stringValue,
              let endpoint = v["endpoint"]?.stringValue, let listening = v["listening"]?.boolValue,
              let since = v["since"]?.stringValue, let p = Int32(exactly: pid)
        else { return (nil, nil) }
        return (EndpointRecord(product: product, productVersion: version, pid: p, instanceId: instance,
                               endpoint: endpoint, listening: listening, since: since), nil)
    }

    /// The most a lock file may hold; anything longer is not a record.
    public static let maxBytes = 4096

    /// The lock file's text, read without following a link or waiting on a
    /// FIFO, only from a regular file, at most `maxBytes`. Nil otherwise.
    public static func readFile(_ path: String) -> String? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        return read(fd: fd)
    }

    /// The text of an open lock file, from its start, at most `maxBytes`;
    /// nil unless it is a regular file.
    public static func read(fd: Int32) -> String? {
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        var buffer = [UInt8](repeating: 0, count: maxBytes)
        let n = pread(fd, &buffer, maxBytes, 0)
        guard n >= 0 else { return nil }
        return String(decoding: buffer[0..<n], as: UTF8.self)
    }
}
