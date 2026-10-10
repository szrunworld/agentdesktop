import AgentDesktopProtocol
import CryptoKit
import Foundation

/// Who may call the Runtime, and what for (A4, docs/plan/04 §4.2–4.3):
/// registered clients, their grants, pairing requests and the audit of
/// authentication and authorization decisions. A client's credential is
/// stored only as its SHA-256; the plaintext lives in memory until it is
/// handed, once, to the connection that asked to pair.
public final class HubStore: @unchecked Sendable {
    /// What a grant can allow. Every Runtime method a paired client may call
    /// needs one of these; the rest are the owner's (A4 authorization table).
    public static let capabilities = ["observe", "act", "desktop.manage", "run", "unit.run"]
    /// How long an unanswered pairing request stays open.
    public static let pairingWindow: TimeInterval = 600
    /// Grant durations the owner can pick (plan 04: 1 h default, 8 h, up to 7 days).
    public static let maxGrantDuration: TimeInterval = 7 * 86400

    public struct Client: Equatable, Sendable {
        public var clientId: String
        public var agentName: String
        public var publisher: String?
        /// What the Runtime saw of the caller when it paired (pid, executable).
        public var callerFacts: JSONValue
        /// The code identity it paired with (A4 S2), from the socket's audit
        /// token; a `requirement` binds every later connection to it.
        public var codeIdentity: JSONValue = .obj([("level", .string("same_user")), ("hardenedRuntime", .bool(false))])
        public var state: String          // active | revoked
        public var registeredAt: String
        public var revokedAt: String?

        public var json: JSONValue {
            var m: [(String, JSONValue)] = [("clientId", .string(clientId)), ("agentName", .string(agentName)),
                                            ("publisher", publisher.map(JSONValue.string) ?? .null),
                                            ("callerFacts", callerFacts), ("codeIdentity", codeIdentity),
                                            ("state", .string(state)), ("registeredAt", .string(registeredAt))]
            if let revokedAt { m.append(("revokedAt", .string(revokedAt))) }
            return .obj(m)
        }
    }

    public struct Grant: Equatable, Sendable {
        public var clientId: String
        public var capabilities: [String]
        /// Desktop ids, and "created": the Desktops this client created.
        public var desktops: [String]
        /// Bundle ids the client may launch or bind.
        public var apps: [String]
        public var expiresAt: String
        public var revision: Int
        public var state: String          // active | revoked

        public var json: JSONValue {
            .obj([("clientId", .string(clientId)), ("capabilities", .array(capabilities.map(JSONValue.string))),
                  ("desktops", .array(desktops.map(JSONValue.string))), ("apps", .array(apps.map(JSONValue.string))),
                  ("expiresAt", .string(expiresAt)), ("revision", .int(revision)), ("state", .string(state))])
        }
    }

    /// One window a client may reach (docs/security/window-grants.md): the
    /// window ID together with the launch of its process and its app, on one
    /// Desktop, for one client. Never a window ID alone.
    public struct WindowGrant: Equatable, Sendable {
        public static let permissions = ["observe", "act", "persist"]
        public var windowGrantId: String
        public var clientId: String
        public var desktopId: String
        public var windowId: UInt32
        public var process: ProcessIdentity
        public var bundleId: String
        public var appName: String
        public var permissions: [String]
        public var state: String          // active | revoked | ended
        public var endedReason: String?
        public var createdAt: String
        public var expiresAt: String
        public var confirmationId: String?

        public var json: JSONValue {
            var m: [(String, JSONValue)] = [
                ("windowGrantId", .string(windowGrantId)), ("clientId", .string(clientId)), ("desktopId", .string(desktopId)),
                ("window", .obj([("windowId", .int(Int(windowId))), ("process", process.json), ("bundleId", .string(bundleId)),
                                 ("appName", .string(appName))])),
                ("permissions", .array(permissions.map(JSONValue.string))), ("state", .string(state)),
            ]
            if let endedReason { m.append(("endedReason", .string(endedReason))) }
            m += [("createdAt", .string(createdAt)), ("expiresAt", .string(expiresAt))]
            if let confirmationId { m.append(("confirmationId", .string(confirmationId))) }
            return .obj(m)
        }
    }

    public struct Pairing: Equatable, Sendable {
        public var pairingId: String
        public var shortCode: String
        public var connectionId: String
        public var agentName: String
        public var publisher: String?
        public var requested: JSONValue
        public var callerFacts: JSONValue
        public var codeIdentity: JSONValue = .obj([("level", .string("same_user")), ("hardenedRuntime", .bool(false))])
        public var state: String          // requested | approved | denied | expired
        public var expiresAt: String
        public var clientId: String?

        public var json: JSONValue {
            .obj([("pairingId", .string(pairingId)), ("shortCode", .string(shortCode)),
                  ("agentName", .string(agentName)), ("publisher", publisher.map(JSONValue.string) ?? .null),
                  ("requested", requested), ("callerFacts", callerFacts), ("codeIdentity", codeIdentity), ("state", .string(state)),
                  ("expiresAt", .string(expiresAt)), ("clientId", clientId.map(JSONValue.string) ?? .null)])
        }
    }

    private let db: SQLiteDatabase
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    /// Credentials issued and not yet collected, by pairingId.
    private var undelivered: [String: String] = [:]
    /// Bumped by every revocation or narrowing; checks read the current one.
    public private(set) var policyEpoch = 0

    /// `path` nil keeps everything in memory (tests).
    public init(path: String?, now: @escaping @Sendable () -> Date = { Date() }) throws {
        db = try SQLiteDatabase(path: path)
        self.now = now
        try db.execute("""
            CREATE TABLE IF NOT EXISTS clients (client_id TEXT PRIMARY KEY, agent_name TEXT NOT NULL, publisher TEXT,
              caller_facts TEXT NOT NULL, credential_hash TEXT NOT NULL, state TEXT NOT NULL,
              registered_at TEXT NOT NULL, revoked_at TEXT)
            """)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS grants (client_id TEXT PRIMARY KEY, capabilities TEXT NOT NULL, desktops TEXT NOT NULL,
              apps TEXT NOT NULL, expires_at TEXT NOT NULL, revision INTEGER NOT NULL, state TEXT NOT NULL)
            """)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS pairings (pairing_id TEXT PRIMARY KEY, short_code TEXT NOT NULL, connection_id TEXT NOT NULL,
              agent_name TEXT NOT NULL, publisher TEXT, requested TEXT NOT NULL, caller_facts TEXT NOT NULL,
              state TEXT NOT NULL, expires_at TEXT NOT NULL, client_id TEXT)
            """)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS auth_events (at TEXT NOT NULL, connection_id TEXT NOT NULL, client_id TEXT NOT NULL,
              method TEXT NOT NULL, decision TEXT NOT NULL, reason TEXT NOT NULL, run_id TEXT)
            """)
        try db.execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value INTEGER NOT NULL)")
        try db.execute("""
            CREATE TABLE IF NOT EXISTS window_grants (window_grant_id TEXT PRIMARY KEY, client_id TEXT NOT NULL, desktop_id TEXT NOT NULL,
              window_id INTEGER NOT NULL, pid INTEGER NOT NULL, process_started_at TEXT, bundle_id TEXT NOT NULL, app_name TEXT NOT NULL,
              permissions TEXT NOT NULL, state TEXT NOT NULL, ended_reason TEXT, created_at TEXT NOT NULL, expires_at TEXT NOT NULL,
              confirmation_id TEXT)
            """)
        // S2: the code identity a client paired with (added after the first A4 builds).
        for table in ["clients", "pairings"] {
            let cols = (try db.query("PRAGMA table_info(\(table))")).compactMap { $0[1] as? String }
            if !cols.contains("code_identity") { try db.execute("ALTER TABLE \(table) ADD COLUMN code_identity TEXT") }
        }
        policyEpoch = Int((try db.query("SELECT value FROM meta WHERE key = 'policy_epoch'").first?[0] as? Int64) ?? 0)
        // An unanswered request does not outlive the process that held its
        // connection: nothing could collect the credential any more.
        try db.execute("UPDATE pairings SET state = 'expired' WHERE state = 'requested'")
    }

    var nowString: String { Timestamp.string(now()) }

    // MARK: Credentials

    static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return "adt1_" + Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Constant-time comparison of two hex digests.
    static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    public enum Authentication: Equatable {
        case client(Client)
        case revoked
        case unknown
    }

    /// The client a credential proves, if it does.
    public func authenticate(clientId: String, token: String) -> Authentication {
        guard let row = try? db.query("SELECT credential_hash, state FROM clients WHERE client_id = ?", [.text(clientId)]).first,
              let stored = row[0] as? String, let state = row[1] as? String else { return .unknown }
        guard Self.same(stored, Self.hash(token)) else { return .unknown }
        guard state == "active", let c = client(clientId) else { return .revoked }
        return .client(c)
    }

    // MARK: Clients and grants

    public func client(_ id: String) -> Client? {
        clients(where: "client_id = ?", [.text(id)]).first
    }

    public func clients() -> [Client] { clients(where: "1 = 1", []) }

    private func clients(where clause: String, _ args: [SQLiteDatabase.Value]) -> [Client] {
        ((try? db.query("""
            SELECT client_id, agent_name, publisher, caller_facts, state, registered_at, revoked_at, code_identity FROM clients
            WHERE \(clause) ORDER BY registered_at DESC
            """, args)) ?? []).map { r in
            var c = Client(clientId: r[0] as! String, agentName: r[1] as! String, publisher: r[2] as? String,
                   callerFacts: (try? StrictJSON.parse(r[3] as! String)) ?? .obj([]), state: r[4] as! String,
                   registeredAt: r[5] as! String, revokedAt: r[6] as? String)
            if let ci = (r[7] as? String).flatMap({ try? StrictJSON.parse($0) }) { c.codeIdentity = ci }
            return c
        }
    }

    public func grant(_ clientId: String) -> Grant? {
        guard let r = try? db.query("""
            SELECT client_id, capabilities, desktops, apps, expires_at, revision, state FROM grants WHERE client_id = ?
            """, [.text(clientId)]).first else { return nil }
        func list(_ v: Any?) -> [String] { ((try? StrictJSON.parse(v as! String))?.arrayValue ?? []).compactMap(\.stringValue) }
        return Grant(clientId: r[0] as! String, capabilities: list(r[1]), desktops: list(r[2]), apps: list(r[3]),
                     expiresAt: r[4] as! String, revision: Int(r[5] as! Int64), state: r[6] as! String)
    }

    /// Tests: every grant write fails to save; or only the nth from now.
    var failsGrantWrites = false
    var grantWritesBeforeFailure: Int?

    func putGrant(_ g: Grant) throws {
        if failsGrantWrites { throw RuntimeStoreError("grant store unavailable (test)") }
        if let n = grantWritesBeforeFailure {
            grantWritesBeforeFailure = n - 1
            if n <= 0 { throw RuntimeStoreError("grant store unavailable (test)") }
        }
        func enc(_ a: [String]) -> String { JSONValue.array(a.map(JSONValue.string)).encoded() }
        try db.execute("""
            INSERT OR REPLACE INTO grants (client_id, capabilities, desktops, apps, expires_at, revision, state)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, [.text(g.clientId), .text(enc(g.capabilities)), .text(enc(g.desktops)), .text(enc(g.apps)),
                  .text(g.expiresAt), .int(Int64(g.revision)), .text(g.state)])
    }

    /// Replace a client's grant. Anything narrower than before bumps the
    /// policy epoch, so in-flight checks see it at once.
    public func setGrant(_ g: Grant, expectedRevision: Int? = nil) throws -> Grant {
        try setGrant(g, expectedRevision: expectedRevision, endingWindowGrants: nil).grant
    }

    /// Replace a client's grant and, in the same transaction, end the window
    /// grants it no longer backs (window-grants.md; Codex on 48c46a8: a
    /// narrowing is never saved without them). `endingWindowGrants` says why
    /// a window grant ends under the new grant, or nil to keep it; a grant
    /// that is not active ends every one. The ended ones are returned.
    public func setGrant(_ g: Grant, expectedRevision: Int? = nil, endingWindowGrants: ((WindowGrant) -> String?)?) throws
        -> (grant: Grant, ended: [(id: String, reason: String)]) {
        // Read, compare and write as one: a change the user confirmed against
        // revision N is not applied over revision N+1 (round-four review H1).
        writeLock.lock()
        defer { writeLock.unlock() }
        var g = g
        let old = grant(g.clientId)
        if let expectedRevision {
            guard old?.revision == expectedRevision, old?.state == "active", client(g.clientId)?.state == "active" else {
                throw RuntimeStoreError("the grant of \(g.clientId) changed while the user was asked", kind: .revisionMismatch)
            }
        }
        g.revision = (old?.revision ?? 0) + 1
        var ended: [(id: String, reason: String)] = []
        try db.transaction {
            try putGrant(g)
            // A revoked grant revokes its ended window grants too: what was kept
            // under them goes out of reach for good (Codex on 0232db6).
            // Ended ones are swept too (Codex on 31fd421): taking an app or
            // Desktop away takes back what was kept under them, so an ended
            // grant then becomes revoked.
            for w in try loadWindowGrants(where: "client_id = ? AND state IN ('active', 'ended')", [.text(g.clientId)]) {
                let why = g.state != "active" ? "grant_revoked" : endingWindowGrants?(w)
                guard let why else { continue }
                let to = g.state != "active" || w.state == "ended" ? "revoked" : "ended"
                try endWindowGrantRow(w.windowGrantId, state: to, reason: why)
                ended.append((w.windowGrantId, why))
            }
            if let old, !Set(g.capabilities).isSuperset(of: old.capabilities) || !Set(g.desktops).isSuperset(of: old.desktops)
                || !Set(g.apps).isSuperset(of: old.apps) || g.expiresAt < old.expiresAt || g.state != "active" {
                try bumpEpoch()
            }
        }
        return (g, ended)
    }

    /// Take one Desktop out of the grants of the named clients (nil: every
    /// client), as one transaction under the grant write lock (Codex on
    /// fdb5477): each grant is read and written inside it, so a concurrent
    /// hub.grants.set is never overwritten with a stale copy, and either
    /// every client loses the Desktop or none does. With `endingReason` the
    /// window grants on that Desktop end in the same transaction (an ended
    /// one becomes revoked, as setGrant sweeps). Returned: each grant as
    /// saved, with the window grants it ended.
    public func removeDesktop(_ desktopId: String, fromGrantsOf clientIds: [String]?, endingReason: String?) throws
        -> [(grant: Grant, ended: [(id: String, reason: String)])] {
        writeLock.lock()
        defer { writeLock.unlock() }
        return try db.transaction {
            var out: [(grant: Grant, ended: [(id: String, reason: String)])] = []
            for c in clients() where clientIds == nil || clientIds!.contains(c.clientId) {
                guard var g = grant(c.clientId), g.desktops.contains(desktopId) else { continue }
                g.desktops.removeAll { $0 == desktopId }
                g.revision += 1
                try putGrant(g)
                var ended: [(id: String, reason: String)] = []
                if let endingReason {
                    for w in try loadWindowGrants(where: "client_id = ? AND desktop_id = ? AND state IN ('active', 'ended')",
                                                  [.text(c.clientId), .text(desktopId)]) {
                        try endWindowGrantRow(w.windowGrantId, state: w.state == "ended" ? "revoked" : "ended", reason: endingReason)
                        ended.append((w.windowGrantId, endingReason))
                    }
                }
                try bumpEpoch()
                out.append((g, ended))
            }
            return out
        }
    }

    /// The client keeps its record (soft delete) but nothing of it works.
    private let writeLock = NSLock()

    public func revoke(_ clientId: String) throws -> Client? {
        try revokeEndingWindowGrants(clientId)?.client
    }

    /// Revoke a client and say which window grants this revoked, read in the
    /// same transaction (Codex on 72e8b63).
    public func revokeEndingWindowGrants(_ clientId: String) throws -> (client: Client, windowGrants: [String])? {
        // The same lock as setGrant: a confirmed change cannot write a grant
        // back over this revocation (round-five review Low-1).
        writeLock.lock()
        defer { writeLock.unlock() }
        guard client(clientId) != nil else { return nil }
        // One transaction: the client, its grant and its window grants go
        // together or not at all.
        let ended: [String] = try db.transaction {
            try db.execute("UPDATE clients SET state = 'revoked', revoked_at = ? WHERE client_id = ?", [.text(nowString), .text(clientId)])
            try db.execute("UPDATE grants SET state = 'revoked', revision = revision + 1 WHERE client_id = ?", [.text(clientId)])
            var ids: [String] = []
            for w in try loadWindowGrants(where: "client_id = ? AND state IN ('active', 'ended')", [.text(clientId)]) {
                try endWindowGrantRow(w.windowGrantId, state: "revoked", reason: "client_revoked")
                ids.append(w.windowGrantId)
            }
            try bumpEpoch()
            return ids
        }
        return client(clientId).map { ($0, ended) }
    }

    // MARK: Window grants

    /// Record a window grant, only while the client's grant is still the
    /// revision its scope was checked against (`parentRevision`, under the
    /// same lock as every grant change; Codex on 59ea934) and still names
    /// the window's app.
    public func addWindowGrant(_ g: WindowGrant, parentRevision: Int? = nil) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        // A client removed, or its grant changed, while the user was asked gets nothing.
        guard client(g.clientId)?.state == "active", let parent = grant(g.clientId), parent.state == "active",
              parent.apps.contains(g.bundleId), parentRevision.map({ $0 == parent.revision }) ?? true else {
            throw RuntimeStoreError("\(g.clientId) lost its access while the user was asked", kind: .revisionMismatch)
        }
        try db.execute("""
            INSERT INTO window_grants (window_grant_id, client_id, desktop_id, window_id, pid, process_started_at, bundle_id, app_name,
              permissions, state, ended_reason, created_at, expires_at, confirmation_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.text(g.windowGrantId), .text(g.clientId), .text(g.desktopId), .int(Int64(g.windowId)), .int(Int64(g.process.pid)),
                  g.process.startedAt.map { .text($0) } ?? .null, .text(g.bundleId), .text(g.appName),
                  .text(JSONValue.array(g.permissions.map(JSONValue.string)).encoded()), .text(g.state),
                  g.endedReason.map { .text($0) } ?? .null, .text(g.createdAt), .text(g.expiresAt),
                  g.confirmationId.map { .text($0) } ?? .null])
    }

    public func windowGrant(_ id: String) -> WindowGrant? {
        windowGrants(where: "window_grant_id = ?", [.text(id)]).first
    }

    /// A client's window grants (all clients' with nil), newest first.
    public func windowGrants(clientId: String? = nil, includeEnded: Bool = false) -> [WindowGrant] {
        var clauses: [String] = [], args: [SQLiteDatabase.Value] = []
        if let clientId { clauses.append("client_id = ?"); args.append(.text(clientId)) }
        if !includeEnded { clauses.append("state = 'active'") }
        return windowGrants(where: clauses.isEmpty ? "1 = 1" : clauses.joined(separator: " AND "), args)
    }

    private func windowGrants(where clause: String, _ args: [SQLiteDatabase.Value]) -> [WindowGrant] {
        let rows = (try? loadWindowGrants(where: clause, args)) ?? []
        let pending = lock.withLock { tombstones }
        guard !pending.isEmpty else { return rows }
        // An ending not saved yet still holds; try to save it again.
        var out: [WindowGrant] = []
        for var g in rows {
            if let t = pending[g.windowGrantId], g.state == "active" {
                if (try? db.transaction({ try endWindowGrantRow(g.windowGrantId, state: t.state, reason: t.reason) })) != nil {
                    lock.withLock { _ = tombstones.removeValue(forKey: g.windowGrantId) }
                }
                g.state = t.state
                g.endedReason = t.reason
                if clause.contains("state = 'active'") { continue }
            }
            out.append(g)
        }
        return out
    }

    /// The throwing read, for sweeps inside a transaction: a failed read
    /// fails the transaction instead of looking like no grants (Codex on 5f040d4).
    private func loadWindowGrants(where clause: String, _ args: [SQLiteDatabase.Value]) throws -> [WindowGrant] {
        (try db.query("""
            SELECT window_grant_id, client_id, desktop_id, window_id, pid, process_started_at, bundle_id, app_name, permissions, state,
              ended_reason, created_at, expires_at, confirmation_id FROM window_grants WHERE \(clause) ORDER BY rowid DESC
            """, args)).map { r in
            WindowGrant(windowGrantId: r[0] as! String, clientId: r[1] as! String, desktopId: r[2] as! String,
                        windowId: UInt32(truncatingIfNeeded: r[3] as! Int64),
                        process: ProcessIdentity(pid: Int32(truncatingIfNeeded: r[4] as! Int64), startedAt: r[5] as? String),
                        bundleId: r[6] as! String, appName: r[7] as! String,
                        permissions: ((try? StrictJSON.parse(r[8] as! String))?.arrayValue ?? []).compactMap(\.stringValue),
                        state: r[9] as! String, endedReason: r[10] as? String, createdAt: r[11] as! String,
                        expiresAt: r[12] as! String, confirmationId: r[13] as? String)
        }
    }

    /// End one window grant for good (sticky): nothing brings it back.
    /// True when this call ended it (it was active).
    @discardableResult
    /// `tombstone` false (an explicit revocation): nothing changes unless it
    /// is saved, so the caller can report the failure as such (Codex on 17bb318).
    public func endWindowGrant(_ id: String, state: String, reason: String, tombstone: Bool = true) throws -> Bool {
        guard tombstone else { return try db.transaction { try endWindowGrantRow(id, state: state, reason: reason) } }
        // Ended in memory first (Codex on 8e9eb9d): a store that cannot save
        // it does not let the grant come back while this process runs; the
        // write is tried again whenever it is read.
        lock.withLock { if tombstones[id] == nil { tombstones[id] = (state, reason) } }
        let ended = try db.transaction { try endWindowGrantRow(id, state: state, reason: reason) }
        lock.withLock { _ = tombstones.removeValue(forKey: id) }
        return ended
    }

    /// Tests: every window grant ending fails to save.
    var failsWindowGrantWrites = false
    /// Window grants ended in this process whose ending is not saved yet.
    private var tombstones: [String: (state: String, reason: String)] = [:]

    /// An ended grant revoked after all: its kept screenshots then go out of
    /// the client's reach (window-grants.md).
    public func revokeEndedWindowGrant(_ id: String) throws {
        if failsWindowGrantWrites { throw RuntimeStoreError("window grant store unavailable (test)") }
        try db.execute("UPDATE window_grants SET state = 'revoked', ended_reason = 'window_grant_revoked' WHERE window_grant_id = ? AND state = 'ended'",
                       [.text(id)])
    }

    /// Inside a transaction the caller holds.
    @discardableResult
    private func endWindowGrantRow(_ id: String, state: String, reason: String) throws -> Bool {
        if failsWindowGrantWrites { throw RuntimeStoreError("window grant store unavailable (test)") }
        // Active ones end; an ended one can only become revoked, and then
        // says why it was revoked (Codex on 30eb124).
        try db.execute("""
            UPDATE window_grants SET state = ?, ended_reason = ?
            WHERE window_grant_id = ? AND (state = 'active' OR (state = 'ended' AND ? = 'revoked'))
            """, [.text(state), .text(reason), .text(id), .text(state)])
        return db.changes == 1
    }

    /// End every active window grant of a client (or of one Desktop); the
    /// ids that ended.
    @discardableResult
    public func endWindowGrants(clientId: String? = nil, desktopId: String? = nil, state: String = "ended", reason: String) throws -> [String] {
        var clauses = ["state = 'active'"], args: [SQLiteDatabase.Value] = []
        if let clientId { clauses.append("client_id = ?"); args.append(.text(clientId)) }
        if let desktopId { clauses.append("desktop_id = ?"); args.append(.text(desktopId)) }
        return try db.transaction {
            let ids = try db.query("SELECT window_grant_id FROM window_grants WHERE " + clauses.joined(separator: " AND "), args)
                .compactMap { $0[0] as? String }
            for id in ids { try endWindowGrantRow(id, state: state, reason: reason) }
            return ids
        }
    }

    private func bumpEpoch() throws {
        lock.withLock { policyEpoch += 1 }
        try db.execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('policy_epoch', ?)", [.int(Int64(policyEpoch))])
    }

    // MARK: Pairing

    public func startPairing(connectionId: String, agentName: String, publisher: String?, requested: JSONValue,
                             callerFacts: JSONValue, codeIdentity: JSONValue? = nil) throws -> Pairing {
        var p = Pairing(pairingId: DesktopRegistry.newId(prefix: "pair"),
                        shortCode: String(format: "%06d", Int.random(in: 0..<1_000_000)), connectionId: connectionId,
                        agentName: agentName, publisher: publisher, requested: requested, callerFacts: callerFacts,
                        state: "requested", expiresAt: Timestamp.string(now().addingTimeInterval(Self.pairingWindow)),
                        clientId: nil)
        if let codeIdentity { p.codeIdentity = codeIdentity }
        try db.execute("""
            INSERT INTO pairings (pairing_id, short_code, connection_id, agent_name, publisher, requested, caller_facts,
              state, expires_at, client_id, code_identity) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?)
            """, [.text(p.pairingId), .text(p.shortCode), .text(connectionId), .text(agentName),
                  publisher.map { .text($0) } ?? .null, .text(requested.encoded()), .text(callerFacts.encoded()),
                  .text(p.state), .text(p.expiresAt), .text(p.codeIdentity.encoded())])
        return p
    }

    public func pairing(_ id: String) -> Pairing? { pairings(where: "pairing_id = ?", [.text(id)]).first }

    public func pairings(includeClosed: Bool = false) -> [Pairing] {
        pairings(where: includeClosed ? "1 = 1" : "state = 'requested'", [])
    }

    private func pairings(where clause: String, _ args: [SQLiteDatabase.Value]) -> [Pairing] {
        try? db.execute("UPDATE pairings SET state = 'expired' WHERE state = 'requested' AND expires_at < ?", [.text(nowString)])
        return ((try? db.query("""
            SELECT pairing_id, short_code, connection_id, agent_name, publisher, requested, caller_facts, state,
              expires_at, client_id, code_identity FROM pairings WHERE \(clause) ORDER BY expires_at DESC
            """, args)) ?? []).map { r in
            var p = Pairing(pairingId: r[0] as! String, shortCode: r[1] as! String, connectionId: r[2] as! String,
                    agentName: r[3] as! String, publisher: r[4] as? String,
                    requested: (try? StrictJSON.parse(r[5] as! String)) ?? .obj([]),
                    callerFacts: (try? StrictJSON.parse(r[6] as! String)) ?? .obj([]),
                    state: r[7] as! String, expiresAt: r[8] as! String, clientId: r[9] as? String)
            if let ci = (r[10] as? String).flatMap({ try? StrictJSON.parse($0) }) { p.codeIdentity = ci }
            return p
        }
    }

    /// Register the client and its grant; the credential waits in memory for
    /// the pairing connection to collect it.
    public func approve(_ p: Pairing, grant: Grant) throws -> (Client, Grant) {
        let clientId = "app:" + DesktopRegistry.newId(prefix: "c").dropFirst(2)
        let token = Self.newToken()
        try db.transaction {
            // Only a request still open becomes a client, once (review L1).
            try db.execute("UPDATE pairings SET state = 'approved', client_id = ? WHERE pairing_id = ? AND state = 'requested'",
                           [.text(clientId), .text(p.pairingId)])
            guard db.changes == 1 else { throw RuntimeStoreError("pairing \(p.pairingId) is no longer open") }
            try db.execute("""
                INSERT INTO clients (client_id, agent_name, publisher, caller_facts, credential_hash, state, registered_at,
                  code_identity) VALUES (?, ?, ?, ?, ?, 'active', ?, ?)
                """, [.text(clientId), .text(p.agentName), p.publisher.map { .text($0) } ?? .null,
                      .text(p.callerFacts.encoded()), .text(Self.hash(token)), .text(nowString), .text(p.codeIdentity.encoded())])
            var g = grant
            g.clientId = clientId
            g.revision = 1
            g.state = "active"
            try putGrant(g)
        }
        lock.withLock { undelivered[p.pairingId] = token }
        return (client(clientId)!, self.grant(clientId)!)
    }

    public func deny(_ p: Pairing, connectionId: String? = nil, clientId: String? = nil) throws {
        try db.transaction {
            try db.execute("UPDATE pairings SET state = 'denied' WHERE pairing_id = ? AND state = 'requested'", [.text(p.pairingId)])
            guard db.changes == 1 else { throw RuntimeStoreError("pairing is no longer open", kind: .revisionMismatch) }
            if let connectionId, let clientId {
                try db.execute("""
                    INSERT INTO auth_events (at, connection_id, client_id, method, decision, reason, run_id)
                    VALUES (?, ?, ?, 'hub.pairing.deny', 'denied', ?, NULL)
                    """, [.text(nowString), .text(connectionId), .text(clientId), .text(p.pairingId)])
            }
        }
    }

    /// The connection that asked is gone: nothing could collect a credential,
    /// so its open requests end (review L1).
    public func expirePairings(connectionId: String) {
        try? db.execute("UPDATE pairings SET state = 'expired' WHERE connection_id = ? AND state = 'requested'", [.text(connectionId)])
    }

    /// The credential of an approved pairing, once.
    public func collect(_ pairingId: String) -> String? {
        lock.withLock { undelivered.removeValue(forKey: pairingId) }
    }

    // MARK: Audit

    public func audit(connectionId: String, clientId: String, method: String, decision: String, reason: String,
                      runId: String? = nil) {
        try? db.execute("""
            INSERT INTO auth_events (at, connection_id, client_id, method, decision, reason, run_id)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, [.text(nowString), .text(connectionId), .text(clientId), .text(method), .text(decision), .text(reason),
                  runId.map { .text($0) } ?? .null])
        // Bounded, but not flushable (re-review): anyone may cause refusals of
        // unpaired connections, so only those are pruned, oldest first, to
        // their own cap; what paired clients did and every decision about
        // access (asked, confirmed, approved, granted, revoked, cut) stays,
        // up to a much larger cap no stranger can fill.
        if lock.withLock({ auditWrites += 1; return auditWrites % auditPruneEvery == 0 }) {
            try? db.execute("""
                DELETE FROM auth_events WHERE rowid IN (SELECT rowid FROM auth_events
                  WHERE client_id LIKE 'unpaired:%' AND decision IN ('denied', 'requested')
                  ORDER BY rowid DESC LIMIT -1 OFFSET ?)
                """, [.int(Int64(auditKeptUnpaired))])
            // Paired clients' refusals too have their own cap (round-four
            // review L4); the overall cap removes only refusals and the
            // record of each use of a window grant, never a decision about
            // access.
            try? db.execute("""
                DELETE FROM auth_events WHERE rowid IN (SELECT rowid FROM auth_events
                  WHERE decision IN ('denied', 'withheld') ORDER BY rowid DESC LIMIT -1 OFFSET ?)
                """, [.int(Int64(auditKeptRefusals))])
            try? db.execute("""
                DELETE FROM auth_events WHERE rowid IN (SELECT rowid FROM auth_events
                  ORDER BY rowid DESC LIMIT -1 OFFSET ?) AND decision IN ('denied', 'withheld', 'requested', 'used')
                """, [.int(Int64(auditKept))])
            try? db.execute("DELETE FROM pairings WHERE state != 'requested' AND client_id IS NULL AND expires_at < ?",
                            [.text(Timestamp.string(now().addingTimeInterval(-86_400)))])
        }
    }

    /// Retention (tests shrink them).
    var auditKept = 500_000
    var auditKeptUnpaired = 20_000
    var auditKeptRefusals = 100_000
    var auditPruneEvery = 500
    private var auditWrites = 0

    public func auditEvents(limit: Int = 200) -> [JSONValue] {
        ((try? db.query("""
            SELECT at, connection_id, client_id, method, decision, reason, run_id FROM auth_events ORDER BY rowid DESC LIMIT ?
            """, [.int(Int64(limit))])) ?? []).map { r in
            .obj([("at", .string(r[0] as! String)), ("connectionId", .string(r[1] as! String)),
                  ("clientId", .string(r[2] as! String)), ("method", .string(r[3] as! String)),
                  ("decision", .string(r[4] as! String)), ("reason", .string(r[5] as! String)),
                  ("runId", (r[6] as? String).map(JSONValue.string) ?? .null)])
        }
    }
}
