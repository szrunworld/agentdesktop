import AgentDesktopProtocol
import CryptoKit
import Foundation

public protocol ConfigClock: Sendable {
    func now() -> Date
}

public struct SystemConfigClock: ConfigClock {
    public init() {}
    public func now() -> Date { Date() }
}

public struct ConfigOptions: Sendable {
    /// Allow http:// to an explicit loopback host (the "local model" option).
    public var allowLoopbackHTTP: Bool
    /// Allow GUI profiles with the test-only `fixture_json_v1` adapter.
    public var allowFixtureAdapter: Bool
    /// How long an idempotency record is kept (at least 24 h).
    public var idempotencyRetention: TimeInterval
    /// Owner scope of the default pointer.
    public var defaultScope: String

    public init(allowLoopbackHTTP: Bool = false, allowFixtureAdapter: Bool = false,
                idempotencyRetention: TimeInterval = 24 * 3600, defaultScope: String = "local-user") {
        precondition(idempotencyRetention >= 24 * 3600)
        self.allowLoopbackHTTP = allowLoopbackHTTP
        self.allowFixtureAdapter = allowFixtureAdapter
        self.idempotencyRetention = idempotencyRetention
        self.defaultScope = defaultScope
    }
}

public enum ConfigResourceKind: String, Sendable, CaseIterable {
    case connection = "aiConnection"
    case modelProfile = "aiModelProfile"
    case guiProfile = "guiAiProfile"

    var table: String {
        switch self {
        case .connection: return "ai_connections"
        case .modelProfile: return "ai_model_profiles"
        case .guiProfile: return "gui_profiles"
        }
    }

    var revisionTable: String {
        switch self {
        case .connection: return "ai_connection_revisions"
        case .modelProfile: return "ai_model_profile_revisions"
        case .guiProfile: return "gui_profile_revisions"
        }
    }

    var idField: String {
        switch self {
        case .connection: return "connectionId"
        case .modelProfile: return "modelProfileId"
        case .guiProfile: return "guiProfileId"
        }
    }

    var idPrefix: String {
        switch self {
        case .connection: return "conn"
        case .modelProfile: return "mp"
        case .guiProfile: return "gp"
        }
    }
}

/// Points where a test can simulate the process dying mid-mutation.
public enum ConfigFaultPoint: String, Sendable {
    case afterPendingIdentity, afterSecretWrite, afterActivate
}

/// Thrown by a fault hook to stop a mutation exactly like a crash would:
/// nothing that follows runs, including cleanup.
public struct SimulatedCrash: Error, Sendable {
    public init() {}
}

public enum CapabilityLayer: String, Sendable, CaseIterable {
    case network, authModel, imageInput, guiContract
}

/// Configuration of AI connections, model profiles, GUI profiles and the
/// default GUI profile, with immutable revisions, CAS updates, tombstones,
/// idempotent mutations and the credential create/rotate outbox (§04,
/// §05.4, §10). Secrets live only in `CredentialStore`.
public actor ConfigStore: GuiContractEvidence {
    public static let schemaVersion = 4

    let db: SQLiteDatabase
    let credentials: CredentialStore
    let clock: ConfigClock
    let options: ConfigOptions
    private let digestKey: SymmetricKey
    private let newId: @Sendable (String) -> String
    private var fault: (@Sendable (ConfigFaultPoint) throws -> Void)?
    private var revocationListeners: [@Sendable (String) -> Void] = []
    private var activeRunCheck: @Sendable (ConfigResourceKind, String) -> Bool = { _, _ in false }
    /// Budget scopes whose last attempt end could not be written.
    var blockedBudgetScopes: Set<String> = []
    var ledgerFaults: Set<LedgerFault> = []

    public init(path: String, credentials: CredentialStore, digestKey: Data,
                clock: ConfigClock = SystemConfigClock(), options: ConfigOptions = ConfigOptions(),
                newId: @escaping @Sendable (String) -> String = { ConfigStore.randomId($0) }) throws {
        precondition(digestKey.count >= 32, "the idempotency digest key needs 32 bytes")
        try Self.restrictToOwner(databasePath: path)
        self.db = try SQLiteDatabase(path: path)
        self.credentials = credentials
        self.digestKey = SymmetricKey(data: digestKey)
        self.clock = clock
        self.options = options
        self.newId = newId
        try Self.migrate(db, now: Self.timestamp(clock.now()), defaultScope: options.defaultScope)
    }

    /// The database holds credential references, model settings and the
    /// inference ledger: owner-only (0600) in an owner-only directory
    /// (0700), set before SQLite opens it so it is never readable by others,
    /// also when it already exists from an earlier build (SEC-01). SQLite
    /// gives its -wal and -shm files the main file's mode.
    static func restrictToOwner(databasePath path: String) throws {
        guard !path.isEmpty, path != ":memory:", !path.hasPrefix("file:") else { return }
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard chmod(dir, 0o700) == 0 else { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: dir]) }
        }
        let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: path]) }
        defer { close(fd) }
        guard fchmod(fd, 0o600) == 0 else { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: path]) }
        for suffix in ["-wal", "-shm", "-journal"] where fm.fileExists(atPath: path + suffix) {
            guard chmod(path + suffix, 0o600) == 0 else {
                throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: path + suffix])
            }
        }
    }

    public static func randomId(_ prefix: String) -> String {
        prefix + "_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(20)
    }

    /// The 32-byte key for idempotency digests, kept in the credential store.
    public static func loadOrCreateDigestKey(in store: CredentialStore,
                                             account: String = "idempotency-digest-key") throws -> Data {
        if let existing = try store.read(credentialId: account), let d = Data(base64Encoded: existing), d.count >= 32 {
            return d
        }
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try store.write(credentialId: account, secret: key.base64EncodedString())
        return key
    }

    // MARK: Hooks

    public func setFaultHook(_ hook: (@Sendable (ConfigFaultPoint) throws -> Void)?) { fault = hook }

    /// Called with a credential id once it is revoked (rotation or delete),
    /// so in-flight inference using it can be cancelled. May repeat.
    public func onCredentialRevoked(_ listener: @escaping @Sendable (String) -> Void) {
        revocationListeners.append(listener)
    }

    /// Whether a live GUI unit Run pins a resource (protects delete). Set by
    /// the unit.run executor (A6); the Runtime keeps the Runs themselves.
    public func setActiveRunCheck(_ check: @escaping @Sendable (ConfigResourceKind, String) -> Bool) {
        activeRunCheck = check
    }

    // MARK: Schema

    private static func migrate(_ db: SQLiteDatabase, now: String, defaultScope: String) throws {
        try db.exec("CREATE TABLE IF NOT EXISTS schema_migrations(version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL)")
        let current = try db.row("SELECT COALESCE(MAX(version),0) FROM schema_migrations")?[0].int ?? 0
        guard current <= schemaVersion else {
            throw ContractError(.internalError, "configuration database is newer than this build")
        }
        if current < 1 { try migrateV1(db, now: now, defaultScope: defaultScope) }
        if current < 2 { try migrateV2(db, now: now) }
        if current < 3 { try migrateV3(db, now: now) }
        if current < 4 { try migrateV4(db, now: now) }
    }

    /// GUI contract evidence per tested scope (codex on bedbff7): a primary
    /// and a fallback GUI profile on one model profile revision, with
    /// different adapters or coordinate protocols, each keep their own.
    private static func migrateV4(_ db: SQLiteDatabase, now: String) throws {
        try db.transaction {
            try db.exec("""
            CREATE TABLE gui_contract_evidence(model_profile_id TEXT NOT NULL, model_profile_revision INTEGER NOT NULL,
              connection_revision INTEGER NOT NULL, adapter_id TEXT NOT NULL, adapter_version TEXT NOT NULL,
              prompt_version TEXT NOT NULL, parser_version TEXT NOT NULL, coordinate_protocol TEXT NOT NULL, body TEXT NOT NULL,
              PRIMARY KEY(model_profile_id, model_profile_revision, connection_revision, adapter_id, adapter_version,
                          prompt_version, parser_version, coordinate_protocol))
            """)
            try db.run("INSERT INTO schema_migrations VALUES(4, ?)", [.text(now)])
        }
    }

    private static func migrateV1(_ db: SQLiteDatabase, now: String, defaultScope: String) throws {
        try db.transaction {
            for kind in ConfigResourceKind.allCases {
                try db.exec("""
                CREATE TABLE \(kind.table)(
                  id TEXT PRIMARY KEY, seq INTEGER NOT NULL UNIQUE,
                  current_revision INTEGER NOT NULL CHECK(current_revision >= 1),
                  state TEXT NOT NULL CHECK(state IN ('enabled','disabled')),
                  created_at TEXT NOT NULL, deleted_at TEXT, deleted_revision INTEGER)
                """)
                try db.exec("""
                CREATE TABLE \(kind.revisionTable)(
                  id TEXT NOT NULL REFERENCES \(kind.table)(id), revision INTEGER NOT NULL,
                  body TEXT NOT NULL, ref_id TEXT, ref_revision INTEGER,
                  fallback_id TEXT, fallback_revision INTEGER, credential_id TEXT,
                  created_at TEXT NOT NULL, PRIMARY KEY(id, revision))
                """)
            }
            try db.exec("""
            CREATE TABLE ai_defaults(scope TEXT NOT NULL, purpose TEXT NOT NULL,
              revision INTEGER NOT NULL CHECK(revision >= 1), gui_profile_id TEXT,
              updated_at TEXT NOT NULL, PRIMARY KEY(scope, purpose))
            """)
            try db.exec("""
            CREATE TABLE credential_identities(credential_id TEXT PRIMARY KEY, connection_id TEXT,
              state TEXT NOT NULL CHECK(state IN ('pending','active','revoked')),
              created_at TEXT NOT NULL, activated_at TEXT, revoked_at TEXT)
            """)
            try db.exec("""
            CREATE TABLE capability_evidence(model_profile_id TEXT NOT NULL, model_profile_revision INTEGER NOT NULL,
              layer TEXT NOT NULL, body TEXT NOT NULL,
              PRIMARY KEY(model_profile_id, model_profile_revision, layer))
            """)
            try db.exec("CREATE TABLE capability_tests(operation_id TEXT PRIMARY KEY, body TEXT NOT NULL, created_at TEXT NOT NULL)")
            try db.exec("""
            CREATE TABLE mutation_keys(scope TEXT NOT NULL, command TEXT NOT NULL, key TEXT NOT NULL,
              digest TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('pending','done','failed')),
              result TEXT, created_at TEXT NOT NULL, expires_at INTEGER NOT NULL,
              PRIMARY KEY(scope, command, key))
            """)
            try db.exec("""
            CREATE TABLE outbox(seq INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, payload TEXT NOT NULL,
              state TEXT NOT NULL CHECK(state IN ('pending','done')), created_at TEXT NOT NULL, done_at TEXT)
            """)
            try db.run("INSERT INTO ai_defaults VALUES(?, 'gui', 1, NULL, ?)", [.text(defaultScope), .text(now)])
            try db.run("INSERT INTO schema_migrations VALUES(1, ?)", [.text(now)])
        }
    }

    /// Model call ledger, model catalog cache and asynchronous operations.
    private static func migrateV2(_ db: SQLiteDatabase, now: String) throws {
        try db.transaction {
            // One row per started model call (spec §09.3, §18.1). A GUI step
            // has a run and no operation; a capability test the reverse.
            try db.exec("""
            CREATE TABLE inference_attempts(
              attempt_id TEXT PRIMARY KEY,
              purpose TEXT NOT NULL CHECK(purpose IN ('gui_step','capability_test')),
              run_id TEXT, operation_id TEXT, step_index INTEGER, level TEXT,
              caller_scope TEXT NOT NULL, budget_scope TEXT NOT NULL,
              connection_id TEXT NOT NULL, connection_revision INTEGER NOT NULL,
              model_profile_id TEXT NOT NULL, model_profile_revision INTEGER NOT NULL,
              credential_id TEXT NOT NULL, requested_model_id TEXT NOT NULL,
              state TEXT NOT NULL CHECK(state IN ('reserved','succeeded','failed','cancelled','interrupted')),
              reserved_at TEXT NOT NULL, started_at TEXT, ended_at TEXT, latency_ms INTEGER,
              actual_model_id TEXT, upstream_request_id TEXT, http_status INTEGER, finish_reason TEXT,
              input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER,
              cache_write_tokens INTEGER, total_tokens INTEGER,
              cost_amount TEXT, cost_currency TEXT, cost_source TEXT, pricing_revision TEXT,
              error_code TEXT, discarded INTEGER NOT NULL DEFAULT 0,
              CHECK((purpose='gui_step' AND run_id IS NOT NULL AND operation_id IS NULL)
                 OR (purpose='capability_test' AND operation_id IS NOT NULL AND run_id IS NULL)))
            """)
            try db.exec("CREATE INDEX inference_attempts_scope ON inference_attempts(caller_scope, reserved_at)")
            try db.exec("CREATE INDEX inference_attempts_budget ON inference_attempts(budget_scope, state)")
            try db.exec("""
            CREATE TABLE model_catalog(connection_id TEXT PRIMARY KEY, connection_revision INTEGER NOT NULL,
              entries TEXT NOT NULL, refreshed_at TEXT NOT NULL, stale INTEGER NOT NULL DEFAULT 0)
            """)
            try db.exec("""
            CREATE TABLE ai_operations(operation_id TEXT PRIMARY KEY,
              kind TEXT NOT NULL CHECK(kind IN ('capability_test','model_refresh')),
              caller_scope TEXT NOT NULL, resource_id TEXT NOT NULL, resource_revision INTEGER NOT NULL,
              state TEXT NOT NULL CHECK(state IN ('queued','running','cancelling','succeeded','failed','cancelled')),
              result TEXT, error TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL)
            """)
            try db.run("INSERT INTO schema_migrations VALUES(2, ?)", [.text(now)])
        }
    }

    /// GUI runs, their events, inference and action receipts, and the
    /// runtime epoch (spec §05.3, §07.4, §09.3, §10.3). Unused since A6
    /// (unit Runs live in the Runtime's RunStore); kept so stores created
    /// before it open unchanged.
    private static func migrateV3(_ db: SQLiteDatabase, now: String) throws {
        try db.transaction {
            try db.exec("""
            CREATE TABLE gui_runs(run_id TEXT PRIMARY KEY, caller_scope TEXT NOT NULL,
              idempotency_key TEXT NOT NULL, digest TEXT NOT NULL,
              binding TEXT NOT NULL, start_result TEXT NOT NULL, snapshot TEXT NOT NULL,
              state TEXT NOT NULL, last_sequence INTEGER NOT NULL DEFAULT 0, kept_from INTEGER,
              created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
              UNIQUE(caller_scope, idempotency_key))
            """)
            try db.exec("CREATE INDEX gui_runs_state ON gui_runs(state)")
            try db.exec("""
            CREATE TABLE gui_run_refs(run_id TEXT NOT NULL REFERENCES gui_runs(run_id),
              kind TEXT NOT NULL, resource_id TEXT NOT NULL, PRIMARY KEY(run_id, kind, resource_id))
            """)
            try db.exec("CREATE INDEX gui_run_refs_resource ON gui_run_refs(kind, resource_id)")
            try db.exec("""
            CREATE TABLE gui_events(run_id TEXT NOT NULL REFERENCES gui_runs(run_id),
              sequence INTEGER NOT NULL, body TEXT NOT NULL, PRIMARY KEY(run_id, sequence))
            """)
            try db.exec("""
            CREATE TABLE gui_inference_steps(run_id TEXT NOT NULL REFERENCES gui_runs(run_id),
              step_index INTEGER NOT NULL, snapshot_id TEXT NOT NULL, reserved_at TEXT NOT NULL)
            """)
            try db.exec("""
            CREATE TABLE gui_inference_receipts(attempt_id TEXT PRIMARY KEY,
              run_id TEXT NOT NULL REFERENCES gui_runs(run_id), step_index INTEGER NOT NULL,
              body TEXT NOT NULL, recorded_at TEXT NOT NULL)
            """)
            try db.exec("""
            CREATE TABLE action_receipts(action_id TEXT PRIMARY KEY,
              run_id TEXT NOT NULL REFERENCES gui_runs(run_id), proposal_id TEXT NOT NULL,
              desktop_id TEXT NOT NULL, snapshot_id TEXT NOT NULL, binding_epoch INTEGER NOT NULL,
              run_generation INTEGER NOT NULL, action_type TEXT NOT NULL,
              state TEXT NOT NULL CHECK(state IN ('pending','not_sent','submitted','confirmed','unknown','rejected')),
              target TEXT, body TEXT, runtime_epoch INTEGER NOT NULL, reconciled INTEGER NOT NULL DEFAULT 0,
              reserved_at TEXT NOT NULL, updated_at TEXT NOT NULL)
            """)
            try db.exec("CREATE INDEX action_receipts_run ON action_receipts(run_id, state)")
            try db.exec("CREATE TABLE runtime_state(key TEXT PRIMARY KEY, value INTEGER NOT NULL)")
            try db.run("INSERT INTO runtime_state VALUES('epoch', 1)")
            try db.run("INSERT INTO schema_migrations VALUES(3, ?)", [.text(now)])
        }
    }

    // MARK: Time and ids

    static func timestamp(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    private var now: String { Self.timestamp(clock.now()) }

    // MARK: Idempotency (§05.4)

    /// Run a mutation once per (scope, command, key). Same semantic content
    /// returns the stored result; different content is IDEMPOTENCY_CONFLICT.
    /// The digest is an HMAC with a local key, so a secret in `semantic`
    /// is never stored or comparable outside this process.
    public func idempotent(scope: String, command: String, key: String?, semantic: JSONValue,
                           _ body: () throws -> JSONValue) throws -> JSONValue {
        guard let key else { return try body() }
        let nowDate = clock.now()
        try db.run("DELETE FROM mutation_keys WHERE expires_at <= ? AND state <> 'pending'",
                   [.int(Int64(nowDate.timeIntervalSince1970))])
        let digest = self.digest(command: command, semantic: semantic)
        if let row = try db.row("SELECT digest, state, result FROM mutation_keys WHERE scope=? AND command=? AND key=?",
                                [.text(scope), .text(command), .text(key)]) {
            guard row[0].text == digest else {
                throw ContractError(.idempotencyConflict, "this idempotency key was used for a different request")
            }
            switch row[1].text {
            case "done":
                return try StrictJSON.parse(row[2].text ?? "null")
            case "failed":
                throw Self.storedError(row[2].text)
            default:
                throw ContractError(.internalError, "an earlier request with this key is still being recovered", retryable: true)
            }
        }
        try db.run("INSERT INTO mutation_keys VALUES(?,?,?,?,'pending',NULL,?,?)",
                   [.text(scope), .text(command), .text(key), .text(digest), .text(Self.timestamp(nowDate)),
                    .int(Int64(nowDate.timeIntervalSince1970 + options.idempotencyRetention))])
        do {
            let result = try body()
            try db.run("UPDATE mutation_keys SET state='done', result=? WHERE scope=? AND command=? AND key=?",
                       [.text(result.encoded()), .text(scope), .text(command), .text(key)])
            return result
        } catch is SimulatedCrash {
            throw SimulatedCrash()
        } catch {
            // Every mutation is transactional or cleans up after itself on a
            // non-crash failure, so nothing happened: forget the key.
            _ = try? db.run("DELETE FROM mutation_keys WHERE scope=? AND command=? AND key=?",
                        [.text(scope), .text(command), .text(key)])
            throw error
        }
    }

    private func digest(command: String, semantic: JSONValue) -> String {
        let canonical = JSONValue.obj([("command", .string(command)), ("params", Self.canonical(semantic))]).encoded()
        let mac = HMAC<SHA256>.authenticationCode(for: Data(canonical.utf8), using: digestKey)
        return Data(mac).base64EncodedString()
    }

    static func canonical(_ v: JSONValue) -> JSONValue {
        switch v {
        case let .object(members):
            return .object(members.sorted { $0.key < $1.key }.map { (key: $0.key, value: canonical($0.value)) })
        case let .array(items):
            return .array(items.map(canonical))
        default:
            return v
        }
    }

    private static func storedError(_ text: String?) -> ContractError {
        guard let text, let v = try? StrictJSON.parse(text), let code = v["code"]?.stringValue.flatMap(ErrorCode.init(rawValue:)) else {
            return ContractError(.internalError, "an earlier request with this key failed")
        }
        return ContractError(code, v["message"]?.stringValue ?? "", retryable: v["retryable"]?.boolValue)
    }

    // MARK: Generic resource rows

    struct Row {
        let id: String
        let currentRevision: Int
        let state: String
        let deleted: Bool
        let body: JSONValue
        let refId: String?
        let refRevision: Int?
        let fallbackId: String?
        let fallbackRevision: Int?
        let credentialId: String?
    }

    func load(_ kind: ConfigResourceKind, _ id: String, includeDeleted: Bool = false) throws -> Row? {
        guard let r = try db.row("""
            SELECT c.id, c.current_revision, c.state, c.deleted_at, r.body, r.ref_id, r.ref_revision,
                   r.fallback_id, r.fallback_revision, r.credential_id
            FROM \(kind.table) c JOIN \(kind.revisionTable) r ON r.id = c.id AND r.revision = c.current_revision
            WHERE c.id = ?
            """, [.text(id)]) else { return nil }
        let deleted = r[3] != .null
        if deleted && !includeDeleted { return nil }
        return Row(id: r[0].text!, currentRevision: Int(r[1].int!), state: r[2].text!, deleted: deleted,
                   body: try StrictJSON.parse(r[4].text!), refId: r[5].text, refRevision: r[6].int.map(Int.init),
                   fallbackId: r[7].text, fallbackRevision: r[8].int.map(Int.init), credentialId: r[9].text)
    }

    /// The body of one exact revision (immutable snapshot).
    public func revisionBody(_ kind: ConfigResourceKind, _ id: String, _ revision: Int) throws -> JSONValue? {
        guard let r = try db.row("SELECT body FROM \(kind.revisionTable) WHERE id=? AND revision=?",
                                 [.text(id), .int(Int64(revision))]) else { return nil }
        let body = try StrictJSON.parse(r[0].text!)
        return kind == .modelProfile ? try renderModelProfile(body) : body
    }

    private func requireCurrent(_ kind: ConfigResourceKind, _ id: String, expectedRevision: Int) throws -> Row {
        guard let row = try load(kind, id) else { throw notFound(kind) }
        guard row.currentRevision == expectedRevision else { throw conflict(row.currentRevision) }
        return row
    }

    private func notFound(_ kind: ConfigResourceKind) -> ContractError {
        ContractError(.notFound, "\(kind.rawValue) not found")
    }

    private func conflict(_ current: Int) -> ContractError {
        ContractError(.configConflict, "the resource changed; reload and retry",
                      details: .obj([("currentRevision", .int(current))]))
    }

    private func insertRevision(_ kind: ConfigResourceKind, id: String, revision: Int, body: JSONValue,
                                refId: String? = nil, refRevision: Int? = nil,
                                fallbackId: String? = nil, fallbackRevision: Int? = nil,
                                credentialId: String? = nil) throws {
        try db.run("INSERT INTO \(kind.revisionTable) VALUES(?,?,?,?,?,?,?,?,?)", [
            .text(id), .int(Int64(revision)), .text(body.encoded()),
            refId.map(SQLValue.text) ?? .null, refRevision.map { .int(Int64($0)) } ?? .null,
            fallbackId.map(SQLValue.text) ?? .null, fallbackRevision.map { .int(Int64($0)) } ?? .null,
            credentialId.map(SQLValue.text) ?? .null, .text(now),
        ])
    }

    private func insertNew(_ kind: ConfigResourceKind, id: String, body: JSONValue, refId: String? = nil,
                           refRevision: Int? = nil, fallbackId: String? = nil, fallbackRevision: Int? = nil,
                           credentialId: String? = nil) throws {
        let seq = (try db.row("SELECT COALESCE(MAX(seq),0)+1 FROM \(kind.table)")?[0].int) ?? 1
        try db.run("INSERT INTO \(kind.table) VALUES(?,?,1,'enabled',?,NULL,NULL)", [.text(id), .int(seq), .text(now)])
        try insertRevision(kind, id: id, revision: 1, body: body, refId: refId, refRevision: refRevision,
                           fallbackId: fallbackId, fallbackRevision: fallbackRevision, credentialId: credentialId)
    }

    private func advance(_ kind: ConfigResourceKind, _ row: Row, body: JSONValue, refId: String?, refRevision: Int?,
                         fallbackId: String?, fallbackRevision: Int?, credentialId: String?) throws -> Int {
        let next = row.currentRevision + 1
        let state = body["state"]?.stringValue ?? row.state
        let changed = try db.run("UPDATE \(kind.table) SET current_revision=?, state=? WHERE id=? AND current_revision=? AND deleted_at IS NULL",
                                 [.int(Int64(next)), .text(state), .text(row.id), .int(Int64(row.currentRevision))])
        guard changed == 1 else { throw conflict(row.currentRevision) }
        try insertRevision(kind, id: row.id, revision: next, body: body, refId: refId, refRevision: refRevision,
                           fallbackId: fallbackId, fallbackRevision: fallbackRevision, credentialId: credentialId)
        return next
    }

    // MARK: Listing

    public func list(_ kind: ConfigResourceKind, limit: Int?, cursor: String?, includeDisabled: Bool,
                     connectionId: String? = nil) throws -> JSONValue {
        let n = limit ?? 20
        guard (1...100).contains(n) else { throw ContractError(.validationError, "limit must be 1...100") }
        let filter = "\(kind.rawValue)|\(includeDisabled)|\(connectionId ?? "")"
        let filterTag = String(Data(SHA256.hash(data: Data(filter.utf8))).base64EncodedString().prefix(12))
        var after: Int64 = 0
        if let cursor {
            guard let data = Data(base64Encoded: cursor), let text = String(data: data, encoding: .utf8) else {
                throw ContractError(.validationError, "invalid cursor")
            }
            let parts = text.split(separator: "|")
            guard parts.count == 3, parts[0] == "v1", let seq = Int64(parts[2]) else {
                throw ContractError(.validationError, "invalid cursor")
            }
            guard parts[1] == filterTag else {
                throw ContractError(.validationError, "the cursor belongs to a different filter")
            }
            after = seq
        }
        var sql = """
            SELECT c.id, c.seq FROM \(kind.table) c JOIN \(kind.revisionTable) r ON r.id=c.id AND r.revision=c.current_revision
            WHERE c.deleted_at IS NULL AND c.seq > ?
            """
        var args: [SQLValue] = [.int(after)]
        if !includeDisabled { sql += " AND c.state = 'enabled'" }
        if let connectionId { sql += " AND r.ref_id = ?"; args.append(.text(connectionId)) }
        sql += " ORDER BY c.seq LIMIT ?"
        args.append(.int(Int64(n + 1)))
        let rows = try db.rows(sql, args)
        var items: [JSONValue] = []
        for r in rows.prefix(n) {
            if let body = try load(kind, r[0].text!)?.body {
                items.append(kind == .modelProfile ? try renderModelProfile(body) : body)
            }
        }
        var next: JSONValue = .null
        if rows.count > n, let last = rows.prefix(n).last?[1].int {
            next = .string(Data("v1|\(filterTag)|\(last)".utf8).base64EncodedString())
        }
        return .obj([("items", .array(items)), ("nextCursor", next)])
    }

    public func get(_ kind: ConfigResourceKind, _ id: String) throws -> JSONValue {
        guard let row = try load(kind, id) else { throw notFound(kind) }
        return kind == .modelProfile ? try renderModelProfile(row.body) : row.body
    }

    // MARK: Connections

    public func createConnection(name: String, protocol proto: String, baseUrl: String, timeoutMs: Int,
                                 apiKey: String) throws -> JSONValue {
        try checkProtocol(proto)
        let url = try EndpointPolicy.normalize(baseUrl, allowLoopbackHTTP: options.allowLoopbackHTTP)
        let connectionId = newId(ConfigResourceKind.connection.idPrefix)
        let credentialId = try storeNewCredential(apiKey, connectionId: connectionId)
        let t = now
        let body = JSONValue.obj([
            ("connectionId", .string(connectionId)), ("revision", .int(1)), ("name", .string(name)),
            ("protocol", .string(proto)), ("baseUrl", .string(url.absoluteString)),
            ("credentialRef", .string(credentialId)), ("state", .string("enabled")),
            ("timeoutMs", .int(timeoutMs)), ("createdAt", .string(t)), ("updatedAt", .string(t)),
        ])
        try db.transaction {
            try insertNew(.connection, id: connectionId, body: body, credentialId: credentialId)
            try db.run("UPDATE credential_identities SET state='active', activated_at=? WHERE credential_id=? AND state='pending'",
                       [.text(t), .text(credentialId)])
        }
        return body
    }

    public func updateConnection(_ id: String, expectedRevision: Int, patch: JSONValue) throws -> JSONValue {
        let row = try requireCurrent(.connection, id, expectedRevision: expectedRevision)
        var body = row.body
        if let p = patch["protocol"]?.stringValue { try checkProtocol(p); body = body.setting("protocol", .string(p)) }
        if let n = patch["name"] { body = body.setting("name", n) }
        if let u = patch["baseUrl"]?.stringValue {
            let url = try EndpointPolicy.normalize(u, allowLoopbackHTTP: options.allowLoopbackHTTP)
            body = body.setting("baseUrl", .string(url.absoluteString))
        }
        if let t = patch["timeoutMs"] { body = body.setting("timeoutMs", t) }
        if let s = patch["state"] { body = body.setting("state", s) }
        return try writeConnectionRevision(row, body: body, credentialId: row.credentialId)
    }

    public func disable(_ kind: ConfigResourceKind, _ id: String, expectedRevision: Int) throws -> JSONValue {
        let row = try requireCurrent(kind, id, expectedRevision: expectedRevision)
        if row.state == "disabled" {
            return kind == .modelProfile ? try renderModelProfile(row.body) : row.body
        }
        let body = row.body.setting("state", .string("disabled"))
        switch kind {
        case .connection: return try writeConnectionRevision(row, body: body, credentialId: row.credentialId)
        case .modelProfile, .guiProfile:
            return try db.transaction {
                let next = try advance(kind, row, body: stamp(body, row.currentRevision + 1), refId: row.refId,
                                       refRevision: row.refRevision, fallbackId: row.fallbackId,
                                       fallbackRevision: row.fallbackRevision, credentialId: nil)
                return try revisionBody(kind, id, next)!
            }
        }
    }

    private func writeConnectionRevision(_ row: Row, body: JSONValue, credentialId: String?) throws -> JSONValue {
        try db.transaction {
            let b = stamp(body, row.currentRevision + 1)
            _ = try advance(.connection, row, body: b, refId: nil, refRevision: nil, fallbackId: nil,
                            fallbackRevision: nil, credentialId: credentialId)
            return b
        }
    }

    private func stamp(_ body: JSONValue, _ revision: Int) -> JSONValue {
        body.setting("revision", .int(revision)).setting("updatedAt", .string(now))
    }

    private func checkProtocol(_ p: String) throws {
        guard p == "openai_chat" else {
            throw ContractError(.unsupportedProtocol, "only openai_chat is implemented in this version")
        }
    }

    // MARK: Credentials (§10.2)

    private func storeNewCredential(_ secret: String, connectionId: String) throws -> String {
        let credentialId = newId("cred")
        try db.run("INSERT INTO credential_identities VALUES(?,?, 'pending', ?, NULL, NULL)",
                   [.text(credentialId), .text(connectionId), .text(now)])
        try fault?(.afterPendingIdentity)
        do {
            try credentials.write(credentialId: credentialId, secret: secret)
        } catch {
            _ = try? db.run("DELETE FROM credential_identities WHERE credential_id=? AND state='pending'", [.text(credentialId)])
            throw ContractError(.internalError, "the system credential store refused the key", retryable: true)
        }
        try fault?(.afterSecretWrite)
        return credentialId
    }

    public func rotateCredential(_ connectionId: String, expectedRevision: Int, apiKey: String) throws -> JSONValue {
        let row = try requireCurrent(.connection, connectionId, expectedRevision: expectedRevision)
        let newCredential = try storeNewCredential(apiKey, connectionId: connectionId)
        let old = row.credentialId
        let t = now
        let body: JSONValue
        do {
            body = try db.transaction {
                let b = stamp(row.body.setting("credentialRef", .string(newCredential)), row.currentRevision + 1)
                _ = try advance(.connection, row, body: b, refId: nil, refRevision: nil, fallbackId: nil,
                                fallbackRevision: nil, credentialId: newCredential)
                try db.run("UPDATE credential_identities SET state='active', activated_at=? WHERE credential_id=?",
                           [.text(t), .text(newCredential)])
                if let old { try revokeInTransaction(old, at: t) }
                return b
            }
        } catch let e as ContractError {
            try? credentials.delete(credentialId: newCredential)
            _ = try? db.run("DELETE FROM credential_identities WHERE credential_id=? AND state='pending'", [.text(newCredential)])
            throw e
        }
        try fault?(.afterActivate)
        applyOutbox()
        return body
    }

    private func revokeInTransaction(_ credentialId: String, at t: String) throws {
        try db.run("UPDATE credential_identities SET state='revoked', revoked_at=? WHERE credential_id=? AND state<>'revoked'",
                   [.text(t), .text(credentialId)])
        let payload = JSONValue.obj([("credentialId", .string(credentialId))]).encoded()
        try db.run("INSERT INTO outbox(kind, payload, state, created_at) VALUES('credential_revoked', ?, 'pending', ?)",
                   [.text(payload), .text(t)])
    }

    /// Deliver committed revocations: notify listeners, then remove the old
    /// secret. A failed removal stays pending and is retried; the identity
    /// is already revoked, so it can never be resolved again either way.
    @discardableResult
    public func applyOutbox() -> Int {
        guard let rows = try? db.rows("SELECT seq, payload FROM outbox WHERE state='pending' ORDER BY seq") else { return 0 }
        var done = 0
        for r in rows {
            guard let id = (try? StrictJSON.parse(r[1].text ?? ""))?["credentialId"]?.stringValue else { continue }
            for l in revocationListeners { l(id) }
            guard (try? credentials.delete(credentialId: id)) != nil else { continue }
            if (try? db.run("UPDATE outbox SET state='done', done_at=? WHERE seq=?", [.text(now), r[0]])) != nil {
                done += 1
            }
        }
        return done
    }

    /// Crash recovery: drop pending identities (and their secrets) that no
    /// connection activated, fail interrupted mutations, replay the outbox.
    public func recover() throws {
        for r in try db.rows("SELECT credential_id FROM credential_identities WHERE state='pending'") {
            let id = r[0].text!
            try? credentials.delete(credentialId: id)
            try db.run("DELETE FROM credential_identities WHERE credential_id=? AND state='pending'", [.text(id)])
        }
        let interrupted = ContractError(.internalError, "the request was interrupted; check the resource and retry with a new key")
        try db.run("UPDATE mutation_keys SET state='failed', result=? WHERE state='pending'", [.text(interrupted.json.encoded())])
        applyOutbox()
    }

    /// The API key for a credential identity. Revoked or unknown identities
    /// never resolve, and there is no fallback to environment variables or
    /// any other account (SEC-002).
    public func resolveSecret(credentialId: String) throws -> String {
        guard let r = try db.row("SELECT state FROM credential_identities WHERE credential_id=?", [.text(credentialId)]) else {
            throw ContractError(.credentialRequired, "no credential is configured")
        }
        switch r[0].text {
        case "active":
            guard let secret = try? credentials.read(credentialId: credentialId), !secret.isEmpty else {
                throw ContractError(.credentialRequired, "the stored credential is missing or locked")
            }
            return secret
        case "revoked":
            throw ContractError(.credentialRevoked, "the credential was revoked")
        default:
            throw ContractError(.credentialRequired, "the credential is not active")
        }
    }

    public func credentialState(_ credentialId: String) throws -> String? {
        try db.row("SELECT state FROM credential_identities WHERE credential_id=?", [.text(credentialId)])?[0].text
    }

    // MARK: Delete (tombstones)

    public func delete(_ kind: ConfigResourceKind, _ id: String, expectedRevision: Int) throws -> JSONValue {
        let row = try requireCurrent(kind, id, expectedRevision: expectedRevision)
        if try isReferenced(kind, id) || activeRunCheck(kind, id) {
            throw ContractError(.resourceInUse, "\(kind.rawValue) is still referenced; change those references first")
        }
        let t = now
        let tombstoneRevision = row.currentRevision + 1
        try db.transaction {
            let n = try db.run("UPDATE \(kind.table) SET deleted_at=?, deleted_revision=? WHERE id=? AND current_revision=? AND deleted_at IS NULL",
                               [.text(t), .int(Int64(tombstoneRevision)), .text(id), .int(Int64(row.currentRevision))])
            guard n == 1 else { throw conflict(row.currentRevision) }
            if kind == .connection, let cred = row.credentialId { try revokeInTransaction(cred, at: t) }
        }
        if kind == .connection { applyOutbox() }
        return .obj([("resourceType", .string(kind.rawValue)), ("resourceId", .string(id)),
                     ("revision", .int(tombstoneRevision)), ("deletedAt", .string(t))])
    }

    private func isReferenced(_ kind: ConfigResourceKind, _ id: String) throws -> Bool {
        switch kind {
        case .connection:
            return try liveReferences(from: .modelProfile, column: "ref_id", id) > 0
        case .modelProfile:
            return try liveReferences(from: .guiProfile, column: "ref_id", id) > 0
        case .guiProfile:
            let isDefault = try db.row("SELECT 1 FROM ai_defaults WHERE gui_profile_id=?", [.text(id)]) != nil
            return try isDefault || liveReferences(from: .guiProfile, column: "fallback_id", id) > 0
        }
    }

    private func liveReferences(from kind: ConfigResourceKind, column: String, _ id: String) throws -> Int64 {
        try db.row("""
            SELECT COUNT(*) FROM \(kind.table) c JOIN \(kind.revisionTable) r ON r.id=c.id AND r.revision=c.current_revision
            WHERE c.deleted_at IS NULL AND r.\(column) = ?
            """, [.text(id)])?[0].int ?? 0
    }

    // MARK: Model profiles

    private func pinnedTarget(_ kind: ConfigResourceKind, _ id: String, revision: Int) throws -> Row {
        guard let row = try load(kind, id) else {
            throw ContractError(.notFound, "referenced \(kind.rawValue) not found")
        }
        guard row.currentRevision == revision else {
            throw ContractError(.configConflict, "the referenced \(kind.rawValue) has a newer revision",
                                details: .obj([("currentRevision", .int(row.currentRevision))]))
        }
        guard row.state == "enabled" else {
            throw ContractError(.resourceDisabled, "the referenced \(kind.rawValue) is disabled")
        }
        return row
    }

    public func createModelProfile(_ p: JSONValue) throws -> JSONValue {
        let connectionId = p["connectionId"]!.stringValue!
        let connectionRevision = p["connectionRevision"]!.intValue!
        let conn = try pinnedTarget(.connection, connectionId, revision: connectionRevision)
        try checkProtocol(conn.body["protocol"]?.stringValue ?? "")
        let id = newId(ConfigResourceKind.modelProfile.idPrefix)
        let t = now
        let body = JSONValue.obj([
            ("modelProfileId", .string(id)), ("revision", .int(1)), ("name", p["name"]!), ("state", .string("enabled")),
            ("connectionId", .string(connectionId)), ("connectionRevision", .int(connectionRevision)),
            ("modelId", p["modelId"]!), ("requestOptions", p["requestOptions"]!),
            ("maxOutputTokens", p["maxOutputTokens"]!), ("createdAt", .string(t)), ("updatedAt", .string(t)),
        ])
        try db.transaction {
            try insertNew(.modelProfile, id: id, body: body, refId: connectionId, refRevision: connectionRevision)
        }
        return try renderModelProfile(body)
    }

    public func updateModelProfile(_ id: String, expectedRevision: Int, patch: JSONValue) throws -> JSONValue {
        let row = try requireCurrent(.modelProfile, id, expectedRevision: expectedRevision)
        var body = row.body
        var refId = row.refId, refRevision = row.refRevision
        if patch["connectionId"] != nil || patch["connectionRevision"] != nil {
            guard let rev = patch["connectionRevision"]?.intValue else {
                throw ContractError(.validationError, "changing the connection needs connectionRevision")
            }
            let cid = patch["connectionId"]?.stringValue ?? row.refId!
            _ = try pinnedTarget(.connection, cid, revision: rev)
            refId = cid; refRevision = rev
            body = body.setting("connectionId", .string(cid)).setting("connectionRevision", .int(rev))
        }
        for k in ["name", "modelId", "requestOptions", "maxOutputTokens", "state"] {
            if let v = patch[k] { body = body.setting(k, v) }
        }
        return try db.transaction {
            let next = try advance(.modelProfile, row, body: stamp(body, row.currentRevision + 1), refId: refId,
                                   refRevision: refRevision, fallbackId: nil, fallbackRevision: nil, credentialId: nil)
            return try revisionBody(.modelProfile, id, next)!
        }
    }

    func renderModelProfile(_ body: JSONValue) throws -> JSONValue {
        let id = body["modelProfileId"]!.stringValue!
        let rev = body["revision"]!.intValue!
        let connectionRevision = body["connectionRevision"]!.intValue!
        var caps: [(String, JSONValue)] = []
        for layer in CapabilityLayer.allCases {
            if let r = try db.row("SELECT body FROM capability_evidence WHERE model_profile_id=? AND model_profile_revision=? AND layer=?",
                                  [.text(id), .int(Int64(rev)), .text(layer.rawValue)]) {
                caps.append((layer.rawValue, try StrictJSON.parse(r[0].text!)))
            } else {
                caps.append((layer.rawValue, .obj([
                    ("status", .string("unknown")), ("checkedAt", .null), ("testOperationId", .null),
                    ("scope", .obj([("connectionRevision", .int(connectionRevision))])), ("reasonCode", .null),
                ])))
            }
        }
        var members = body.objectMembers!.filter { $0.key != "capabilities" }
        let at = members.firstIndex { $0.key == "createdAt" } ?? members.count
        members.insert((key: "capabilities", value: .obj(caps)), at: at)
        return .object(members)
    }

    /// Record one layer's evidence for an exact model profile revision.
    /// Evidence belongs to that revision only: a later revision starts at
    /// `unknown` again, and one layer never sets another (CFG-008).
    public func recordCapabilityEvidence(modelProfileId: String, revision: Int, layer: CapabilityLayer,
                                         status: String, operationId: String?, reasonCode: String?,
                                         adapter: (version: String, prompt: String, parser: String)? = nil,
                                         gui: (adapterId: String, coordinateProtocol: String)? = nil) throws {
        guard let body = try revisionBody(.modelProfile, modelProfileId, revision) else {
            throw ContractError(.notFound, "model profile revision not found")
        }
        var scope: [(String, JSONValue)] = [("connectionRevision", body["connectionRevision"]!), ("modelProfileRevision", .int(revision))]
        if let adapter {
            scope += [("adapterVersion", .string(adapter.version)), ("promptVersion", .string(adapter.prompt)),
                      ("parserVersion", .string(adapter.parser))]
        }
        // What the GUI contract test proved is tied to how coordinates were
        // asked for and read (codex on 817221a).
        if let gui { scope += [("adapterId", .string(gui.adapterId)), ("coordinateProtocol", .string(gui.coordinateProtocol))] }
        let evidence = JSONValue.obj([
            ("status", .string(status)), ("checkedAt", .string(now)),
            ("testOperationId", operationId.map(JSONValue.string) ?? .null), ("scope", .obj(scope)),
            ("reasonCode", reasonCode.map(JSONValue.string) ?? .null),
        ])
        guard try ContractBundle.shared.validate(evidence, "CapabilityEvidence").isEmpty else {
            throw ContractError(.validationError, "invalid capability evidence")
        }
        try db.run("INSERT OR REPLACE INTO capability_evidence VALUES(?,?,?,?)",
                   [.text(modelProfileId), .int(Int64(revision)), .text(layer.rawValue), .text(evidence.encoded())])
        // The GUI contract also per tested scope, so one test never voids another's.
        if layer == .guiContract, let adapter, let gui, let connectionRevision = body["connectionRevision"]?.intValue {
            try db.run("INSERT OR REPLACE INTO gui_contract_evidence VALUES(?,?,?,?,?,?,?,?,?)",
                       [.text(modelProfileId), .int(Int64(revision)), .int(Int64(connectionRevision)), .text(gui.adapterId),
                        .text(adapter.version), .text(adapter.prompt), .text(adapter.parser), .text(gui.coordinateProtocol),
                        .text(evidence.encoded())])
        }
    }

    /// F40-06 row 12: verified guiContract evidence for exactly this
    /// candidate's model profile and connection revisions and the codec
    /// provenance the run will use (adapter id and version, prompt, parser,
    /// coordinate protocol). Anything else is not passed.
    public func guiContractPassed(_ c: GuiCandidate, provenance p: AdapterProvenance) throws -> Bool {
        let model = c.resolvedModel.model
        guard let row = try db.row("""
            SELECT body FROM gui_contract_evidence WHERE model_profile_id=? AND model_profile_revision=? AND connection_revision=?
              AND adapter_id=? AND adapter_version=? AND prompt_version=? AND parser_version=? AND coordinate_protocol=?
            """, [.text(model.modelProfileId), .int(Int64(model.revision)), .int(Int64(c.resolvedModel.connection.revision)),
                  .text(p.adapterId.rawValue), .text(p.adapterVersion), .text(p.promptVersion), .text(p.parserVersion),
                  .text(p.coordinateProtocol.rawValue)]),
              let text = row[0].text else { return false }
        return try StrictJSON.parse(text)["status"]?.stringValue == "verified"
    }

    // MARK: GUI profiles

    private func checkAdapter(_ adapterId: String?) throws {
        if adapterId == "fixture_json_v1" && !options.allowFixtureAdapter {
            throw ContractError(.capabilityMismatch, "fixture_json_v1 is available only in test builds")
        }
    }

    private func checkFallback(_ refs: JSONValue?, selfId: String?) throws -> (String, Int)? {
        guard let list = refs?.arrayValue, let first = list.first else { return nil }
        guard list.count <= 1 else { throw ContractError(.validationError, "at most one fallback profile") }
        let fid = first["guiProfileId"]!.stringValue!
        let frev = first["revision"]!.intValue!
        guard fid != selfId else { throw ContractError(.validationError, "a profile cannot fall back to itself") }
        let target = try pinnedTarget(.guiProfile, fid, revision: frev)
        var next = target.fallbackId
        var hops = 0
        while let n = next, hops < 16 {
            if n == selfId || n == fid { throw ContractError(.validationError, "fallback profiles form a cycle") }
            next = try load(.guiProfile, n)?.fallbackId
            hops += 1
        }
        return (fid, frev)
    }

    public func createGuiProfile(_ p: JSONValue) throws -> JSONValue {
        try checkAdapter(p["adapterId"]?.stringValue)
        let mpId = p["modelProfileId"]!.stringValue!
        let mpRev = p["modelProfileRevision"]!.intValue!
        _ = try pinnedTarget(.modelProfile, mpId, revision: mpRev)
        let fallback = try checkFallback(p["allowedFallbackProfileRefs"], selfId: nil)
        let id = newId(ConfigResourceKind.guiProfile.idPrefix)
        let t = now
        var members: [(String, JSONValue)] = [
            ("guiProfileId", .string(id)), ("revision", .int(1)), ("name", p["name"]!), ("state", .string("enabled")),
        ]
        for k in ["modelProfileId", "modelProfileRevision", "adapterId", "adapterVersion", "promptVersion",
                  "parserVersion", "coordinateProtocol", "limits", "allowedFallbackProfileRefs"] {
            members.append((k, p[k]!))
        }
        members += [("createdAt", .string(t)), ("updatedAt", .string(t))]
        let body = JSONValue.obj(members)
        try db.transaction {
            try insertNew(.guiProfile, id: id, body: body, refId: mpId, refRevision: mpRev,
                          fallbackId: fallback?.0, fallbackRevision: fallback?.1)
        }
        return body
    }

    public func updateGuiProfile(_ id: String, expectedRevision: Int, patch: JSONValue) throws -> JSONValue {
        let row = try requireCurrent(.guiProfile, id, expectedRevision: expectedRevision)
        var body = row.body
        var refId = row.refId, refRevision = row.refRevision
        var fallbackId = row.fallbackId, fallbackRevision = row.fallbackRevision
        if let a = patch["adapterId"]?.stringValue { try checkAdapter(a) }
        if patch["modelProfileId"] != nil || patch["modelProfileRevision"] != nil {
            guard let rev = patch["modelProfileRevision"]?.intValue else {
                throw ContractError(.validationError, "changing the model profile needs modelProfileRevision")
            }
            let mid = patch["modelProfileId"]?.stringValue ?? row.refId!
            _ = try pinnedTarget(.modelProfile, mid, revision: rev)
            refId = mid; refRevision = rev
            body = body.setting("modelProfileId", .string(mid)).setting("modelProfileRevision", .int(rev))
        }
        if let refs = patch["allowedFallbackProfileRefs"] {
            let f = try checkFallback(refs, selfId: id)
            fallbackId = f?.0; fallbackRevision = f?.1
            body = body.setting("allowedFallbackProfileRefs", refs)
        }
        for k in ["name", "adapterId", "adapterVersion", "promptVersion", "parserVersion", "coordinateProtocol", "limits", "state"] {
            if let v = patch[k] { body = body.setting(k, v) }
        }
        return try db.transaction {
            let b = stamp(body, row.currentRevision + 1)
            _ = try advance(.guiProfile, row, body: b, refId: refId, refRevision: refRevision,
                            fallbackId: fallbackId, fallbackRevision: fallbackRevision, credentialId: nil)
            return b
        }
    }

    // MARK: Default pointer

    public func defaultProfile() throws -> JSONValue {
        let r = try db.row("SELECT revision, gui_profile_id FROM ai_defaults WHERE scope=? AND purpose='gui'",
                           [.text(options.defaultScope)])!
        let id = r[1].text
        let resolved = try id.flatMap { try load(.guiProfile, $0)?.body } ?? .null
        return .obj([
            ("default", .obj([("revision", .int(Int(r[0].int!))), ("guiProfileId", id.map(JSONValue.string) ?? .null)])),
            ("resolvedProfile", resolved),
        ])
    }

    public func setDefault(guiProfileId: String?, expectedDefaultRevision: Int,
                           expectedProfileRevision: Int?) throws -> JSONValue {
        try db.transaction {
            let r = try db.row("SELECT revision FROM ai_defaults WHERE scope=? AND purpose='gui'", [.text(options.defaultScope)])!
            let current = Int(r[0].int!)
            guard current == expectedDefaultRevision else { throw conflict(current) }
            if let guiProfileId {
                guard let rev = expectedProfileRevision else {
                    throw ContractError(.validationError, "expectedProfileRevision is required")
                }
                _ = try pinnedTarget(.guiProfile, guiProfileId, revision: rev)
            }
            try db.run("UPDATE ai_defaults SET revision=?, gui_profile_id=?, updated_at=? WHERE scope=? AND purpose='gui' AND revision=?",
                       [.int(Int64(current + 1)), guiProfileId.map(SQLValue.text) ?? .null, .text(now),
                        .text(options.defaultScope), .int(Int64(current))])
        }
        return try defaultProfile()
    }

    // MARK: Resolution for run binding

    /// The credential identity a connection revision is bound to.
    public func credentialId(connectionId: String, revision: Int) throws -> String? {
        try db.row("SELECT credential_id FROM ai_connection_revisions WHERE id=? AND revision=?",
                   [.text(connectionId), .int(Int64(revision))])?[0].text
    }
}
