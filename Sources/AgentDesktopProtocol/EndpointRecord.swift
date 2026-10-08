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
}
