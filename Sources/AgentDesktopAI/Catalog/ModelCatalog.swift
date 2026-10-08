import AgentDesktopProtocol
import Foundation

/// Cached model lists per connection (spec §05.3 `ai.models.*`). A list
/// says which model ids an endpoint offers; it never marks any capability
/// verified (CFG-008). A failed refresh keeps the previous list, marked stale.
extension ConfigStore {
    public func catalog(connectionId: String) throws -> (revision: Int, entries: [JSONValue], refreshedAt: String, stale: Bool)? {
        guard let r = try db.row("SELECT connection_revision, entries, refreshed_at, stale FROM model_catalog WHERE connection_id=?",
                                 [.text(connectionId)]) else { return nil }
        return (Int(r[0].int!), try StrictJSON.parse(r[1].text!).arrayValue ?? [], r[2].text!, r[3].int == 1)
    }

    func saveCatalog(connectionId: String, revision: Int, entries: [JSONValue], at: String) throws {
        try db.run("INSERT OR REPLACE INTO model_catalog VALUES(?,?,?,?,0)",
                   [.text(connectionId), .int(Int64(revision)), .text(JSONValue.array(entries).encoded()), .text(at)])
    }

    func markCatalogStale(connectionId: String) throws {
        try db.run("UPDATE model_catalog SET stale=1 WHERE connection_id=?", [.text(connectionId)])
    }

    /// `ai.models.list`: the cached list, paged by position.
    public func listModels(connectionId: String, limit: Int?, cursor: String?) throws -> JSONValue {
        guard let conn = try load(.connection, connectionId) else {
            throw ContractError(.notFound, "aiConnection not found")
        }
        let n = limit ?? 20
        guard (1...100).contains(n) else { throw ContractError(.validationError, "limit must be 1...100") }
        let cached = try catalog(connectionId: connectionId)
        let entries = cached?.entries ?? []
        var start = 0
        if let cursor {
            guard let text = Data(base64Encoded: cursor).flatMap({ String(data: $0, encoding: .utf8) }),
                  text.hasPrefix("models|\(connectionId)|"), let i = Int(text.split(separator: "|").last ?? ""),
                  i >= 0 else {
                throw ContractError(.validationError, "invalid cursor")
            }
            start = min(i, entries.count)
        }
        let page = Array(entries[start..<min(start + n, entries.count)])
        let nextIndex = start + page.count
        let next: JSONValue = nextIndex < entries.count
            ? .string(Data("models|\(connectionId)|\(nextIndex)".utf8).base64EncodedString()) : .null
        return .obj([
            ("connectionId", .string(connectionId)),
            ("connectionRevision", .int(cached?.revision ?? conn.currentRevision)),
            ("items", .array(page)), ("nextCursor", next),
            ("refreshedAt", cached.map { .string($0.refreshedAt) } ?? .null),
        ])
    }

    /// The connection at its current revision, for a refresh. CAS on
    /// `expectedRevision`; a disabled connection is not refreshed.
    func connectionForRefresh(_ id: String, expectedRevision: Int) throws -> (body: JSONValue, credential: String) {
        guard let row = try load(.connection, id) else { throw ContractError(.notFound, "aiConnection not found") }
        guard row.currentRevision == expectedRevision else {
            throw ContractError(.configConflict, "the resource changed; reload and retry",
                                details: .obj([("currentRevision", .int(row.currentRevision))]))
        }
        guard row.state == "enabled" else { throw ContractError(.resourceDisabled, "the connection is disabled") }
        guard let cred = row.credentialId else { throw ContractError(.credentialRequired, "no credential is configured") }
        return (row.body, cred)
    }

    var timestampNow: String { Self.timestamp(clock.now()) }
}

/// Fetches `GET <base>/models` through the same transport as model calls:
/// no redirects, bounded body, the key only in the Authorization header.
public struct ModelCatalogFetcher: Sendable {
    public static let maxResponseBytes = 2 * 1024 * 1024
    public static let maxEntries = 10_000

    public let http: HTTPTransport

    public init(http: HTTPTransport) {
        self.http = http
    }

    public static func modelsURL(base: URL) throws -> URL {
        _ = try EndpointRules.chatCompletionsURL(base: base)
        var b = base.absoluteString
        if !b.hasSuffix("/") { b += "/" }
        guard let root = URL(string: b), let url = URL(string: "models", relativeTo: root)?.absoluteURL else {
            throw ContractError(.validationError, "baseUrl is not a valid URL")
        }
        return url
    }

    /// Model ids the endpoint lists, as catalog entries discovered `at`.
    public func fetch(base: URL, apiKey: String, timeoutMs: Int, at: String) async throws -> [JSONValue] {
        var req = URLRequest(url: try Self.modelsURL(base: base))
        req.httpMethod = "GET"
        req.timeoutInterval = max(0.1, Double(timeoutMs) / 1000)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpShouldHandleCookies = false
        let result: HTTPResult
        do {
            result = try await http.send(req, maxResponseBytes: Self.maxResponseBytes)
        } catch let e as HTTPTransportError {
            throw OpenAIChatTransport.map(e)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ContractError(.upstreamUnavailable, "the model endpoint could not be reached")
        }
        let status: JSONValue = .obj([("httpStatus", .int(result.status))])
        switch result.status {
        case 200...299: break
        case 401, 403: throw ContractError(.authFailed, "the model endpoint refused the credential", retryable: false, details: status)
        case 429: throw ContractError(.rateLimited, "the model endpoint is rate limiting", details: status)
        case 500...599: throw ContractError(.upstreamUnavailable, "the model endpoint failed", details: status)
        default: throw ContractError(.upstreamProtocolError, "the model endpoint answered \(result.status)", retryable: false, details: status)
        }
        guard let json = try? StrictJSON.parse(result.body), let data = json["data"]?.arrayValue else {
            throw ContractError(.upstreamProtocolError, "the model list is not the expected JSON", retryable: false)
        }
        var seen = Set<String>()
        var out: [JSONValue] = []
        for item in data.prefix(Self.maxEntries) {
            guard let id = item["id"]?.stringValue, (1...160).contains(id.count), seen.insert(id).inserted else { continue }
            out.append(.obj([
                ("modelId", .string(id)), ("displayName", .string(id)),
                // A list entry says nothing reliable about image input.
                ("imageInput", .string("unknown")),
                ("source", .string("upstream_models")), ("discoveredAt", .string(at)),
            ]))
        }
        return out
    }
}
