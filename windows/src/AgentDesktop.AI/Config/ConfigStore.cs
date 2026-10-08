using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using AgentDesktop.Contracts;
using Microsoft.Data.Sqlite;

namespace AgentDesktop.AI.Config;

public interface IConfigClock
{
    DateTimeOffset Now();
}

public sealed class SystemConfigClock : IConfigClock
{
    public DateTimeOffset Now() => DateTimeOffset.UtcNow;
}

public sealed record ConfigOptions(
    bool AllowLoopbackHttp = false,
    bool AllowFixtureAdapter = false,
    double IdempotencyRetentionSeconds = 24 * 3600,
    string DefaultScope = "local-user");

public enum ConfigResourceKind { Connection, ModelProfile, GuiProfile }

internal static class ResourceKinds
{
    public static string Wire(this ConfigResourceKind k) => k switch
    {
        ConfigResourceKind.Connection => "aiConnection",
        ConfigResourceKind.ModelProfile => "aiModelProfile",
        _ => "guiAiProfile",
    };
    public static string Table(this ConfigResourceKind k) => k switch
    {
        ConfigResourceKind.Connection => "ai_connections",
        ConfigResourceKind.ModelProfile => "ai_model_profiles",
        _ => "gui_profiles",
    };
    public static string RevisionTable(this ConfigResourceKind k) => k switch
    {
        ConfigResourceKind.Connection => "ai_connection_revisions",
        ConfigResourceKind.ModelProfile => "ai_model_profile_revisions",
        _ => "gui_profile_revisions",
    };
    public static string IdPrefix(this ConfigResourceKind k) => k switch
    {
        ConfigResourceKind.Connection => "conn",
        ConfigResourceKind.ModelProfile => "mp",
        _ => "gp",
    };
}

/// <summary>Points where a test can simulate the process dying mid-mutation.</summary>
public enum ConfigFaultPoint { AfterPendingIdentity, AfterSecretWrite, AfterActivate }

/// <summary>Thrown by a fault hook to stop a mutation exactly like a crash: nothing that follows runs.</summary>
public sealed class SimulatedCrashException : Exception
{
    public SimulatedCrashException() : base("simulated crash") { }
}

public enum CapabilityLayer { Network, AuthModel, ImageInput, GuiContract }

/// <summary>
/// Configuration of AI connections, model profiles, GUI profiles and the
/// default GUI profile, with immutable revisions, CAS updates, tombstones,
/// idempotent mutations and the credential create/rotate outbox (spec §04,
/// §05.4, §10). The C# counterpart of the Swift ConfigStore; one connection,
/// every call serialized by one lock. Secrets live only in the credential store.
/// </summary>
public sealed class ConfigStore : IDisposable
{
    public const int SchemaVersion = 1;

    private readonly SqliteConnection _db;
    private readonly ICredentialStore _credentials;
    private readonly IConfigClock _clock;
    private readonly ConfigOptions _options;
    private readonly byte[] _digestKey;
    private readonly Func<string, string> _newId;
    private readonly Lock _lock = new();
    private SqliteTransaction? _tx;
    private Action<ConfigFaultPoint>? _fault;
    private readonly List<Action<string>> _revocationListeners = [];
    private Func<ConfigResourceKind, string, bool> _activeRunCheck = (_, _) => false;

    public string Path { get; }

    public ConfigStore(string path, ICredentialStore credentials, byte[] digestKey, IConfigClock? clock = null,
                       ConfigOptions? options = null, Func<string, string>? newId = null)
    {
        if (digestKey.Length < 32) throw new ArgumentException("the idempotency digest key needs 32 bytes", nameof(digestKey));
        Path = path;
        _credentials = credentials;
        _digestKey = digestKey;
        _clock = clock ?? new SystemConfigClock();
        _options = options ?? new ConfigOptions();
        if (_options.IdempotencyRetentionSeconds < 24 * 3600) throw new ArgumentException("idempotency records are kept at least 24 h");
        _newId = newId ?? RandomId;
        _db = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = path, Pooling = false }.ToString());
        _db.Open();
        Exec("PRAGMA journal_mode=WAL");
        Exec("PRAGMA foreign_keys=ON");
        Exec("PRAGMA busy_timeout=5000");
        Migrate(Timestamp(_clock.Now()));
    }

    public void Dispose() => _db.Dispose();

    public static string RandomId(string prefix) => prefix + "_" + Guid.NewGuid().ToString("N")[..20];

    /// <summary>The 32-byte key for idempotency digests, kept in the credential store.</summary>
    public static byte[] LoadOrCreateDigestKey(ICredentialStore store, string account = "idempotency-digest-key")
    {
        if (store.Read(account) is { } existing)
        {
            try
            {
                var d = Convert.FromBase64String(existing);
                if (d.Length >= 32) return d;
            }
            catch (FormatException) { }
        }
        var key = RandomNumberGenerator.GetBytes(32);
        store.Write(account, Convert.ToBase64String(key));
        return key;
    }

    // ---- Hooks ----

    public void SetFaultHook(Action<ConfigFaultPoint>? hook) { lock (_lock) _fault = hook; }

    /// <summary>Called with a credential id once it is revoked (rotation or delete). May repeat.</summary>
    public void OnCredentialRevoked(Action<string> listener) { lock (_lock) _revocationListeners.Add(listener); }

    /// <summary>Whether an active GUI run references a resource (protects delete).</summary>
    public void SetActiveRunCheck(Func<ConfigResourceKind, string, bool> check) { lock (_lock) _activeRunCheck = check; }

    // ---- SQLite helpers ----

    private SqliteCommand Command(string sql, object?[] args)
    {
        var cmd = _db.CreateCommand();
        cmd.CommandText = sql;
        cmd.Transaction = _tx;
        for (var i = 0; i < args.Length; i++) cmd.Parameters.AddWithValue("$" + (i + 1), args[i] ?? DBNull.Value);
        return cmd;
    }

    private static string Positional(string sql)
    {
        var sb = new StringBuilder();
        var n = 0;
        foreach (var ch in sql)
        {
            if (ch == '?') sb.Append('$').Append(++n);
            else sb.Append(ch);
        }
        return sb.ToString();
    }

    private void Exec(string sql)
    {
        using var cmd = Command(sql, []);
        cmd.ExecuteNonQuery();
    }

    private int Run(string sql, params object?[] args)
    {
        using var cmd = Command(Positional(sql), args);
        return cmd.ExecuteNonQuery();
    }

    private List<object?[]> Rows(string sql, params object?[] args)
    {
        using var cmd = Command(Positional(sql), args);
        using var r = cmd.ExecuteReader();
        var rows = new List<object?[]>();
        while (r.Read())
        {
            var row = new object?[r.FieldCount];
            for (var i = 0; i < r.FieldCount; i++) row[i] = r.IsDBNull(i) ? null : r.GetValue(i);
            rows.Add(row);
        }
        return rows;
    }

    private object?[]? Row(string sql, params object?[] args) => Rows(sql, args).FirstOrDefault();

    private static long? L(object? v) => v is null ? null : Convert.ToInt64(v, CultureInfo.InvariantCulture);
    private static string? S(object? v) => v as string;

    /// <summary>Run inside one transaction; reentrant.</summary>
    private T Transaction<T>(Func<T> body)
    {
        if (_tx is not null) return body();
        _tx = _db.BeginTransaction(deferred: false);
        try
        {
            var result = body();
            _tx.Commit();
            return result;
        }
        catch
        {
            _tx.Rollback();
            throw;
        }
        finally
        {
            _tx.Dispose();
            _tx = null;
        }
    }

    private void Transaction(Action body) => Transaction(() => { body(); return 0; });

    // ---- Schema ----

    private void Migrate(string now)
    {
        Exec("CREATE TABLE IF NOT EXISTS schema_migrations(version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL)");
        var current = L(Row("SELECT COALESCE(MAX(version),0) FROM schema_migrations")?[0]) ?? 0;
        if (current > SchemaVersion) throw new ContractError(ErrorCode.InternalError, "configuration database is newer than this build");
        if (current < 1) MigrateV1(now);
    }

    private void MigrateV1(string now) => Transaction(() =>
    {
        foreach (var kind in Enum.GetValues<ConfigResourceKind>())
        {
            Exec($"""
                CREATE TABLE {kind.Table()}(
                  id TEXT PRIMARY KEY, seq INTEGER NOT NULL UNIQUE,
                  current_revision INTEGER NOT NULL CHECK(current_revision >= 1),
                  state TEXT NOT NULL CHECK(state IN ('enabled','disabled')),
                  created_at TEXT NOT NULL, deleted_at TEXT, deleted_revision INTEGER)
                """);
            Exec($"""
                CREATE TABLE {kind.RevisionTable()}(
                  id TEXT NOT NULL REFERENCES {kind.Table()}(id), revision INTEGER NOT NULL,
                  body TEXT NOT NULL, ref_id TEXT, ref_revision INTEGER,
                  fallback_id TEXT, fallback_revision INTEGER, credential_id TEXT,
                  created_at TEXT NOT NULL, PRIMARY KEY(id, revision))
                """);
        }
        Exec("""
            CREATE TABLE ai_defaults(scope TEXT NOT NULL, purpose TEXT NOT NULL,
              revision INTEGER NOT NULL CHECK(revision >= 1), gui_profile_id TEXT,
              updated_at TEXT NOT NULL, PRIMARY KEY(scope, purpose))
            """);
        Exec("""
            CREATE TABLE credential_identities(credential_id TEXT PRIMARY KEY, connection_id TEXT,
              state TEXT NOT NULL CHECK(state IN ('pending','active','revoked')),
              created_at TEXT NOT NULL, activated_at TEXT, revoked_at TEXT)
            """);
        Exec("""
            CREATE TABLE capability_evidence(model_profile_id TEXT NOT NULL, model_profile_revision INTEGER NOT NULL,
              layer TEXT NOT NULL, body TEXT NOT NULL,
              PRIMARY KEY(model_profile_id, model_profile_revision, layer))
            """);
        Exec("CREATE TABLE capability_tests(operation_id TEXT PRIMARY KEY, body TEXT NOT NULL, created_at TEXT NOT NULL)");
        Exec("""
            CREATE TABLE mutation_keys(scope TEXT NOT NULL, command TEXT NOT NULL, key TEXT NOT NULL,
              digest TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('pending','done','failed')),
              result TEXT, created_at TEXT NOT NULL, expires_at INTEGER NOT NULL,
              PRIMARY KEY(scope, command, key))
            """);
        Exec("""
            CREATE TABLE outbox(seq INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, payload TEXT NOT NULL,
              state TEXT NOT NULL CHECK(state IN ('pending','done')), created_at TEXT NOT NULL, done_at TEXT)
            """);
        Run("INSERT INTO ai_defaults VALUES(?, 'gui', 1, NULL, ?)", _options.DefaultScope, now);
        Run("INSERT INTO schema_migrations VALUES(1, ?)", now);
    });

    // ---- Time ----

    public static string Timestamp(DateTimeOffset d) =>
        d.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);

    private string NowText => Timestamp(_clock.Now());

    // ---- Idempotency (§05.4) ----

    /// <summary>
    /// Run a mutation once per (scope, command, key). Same semantic content
    /// returns the stored result; different content is IDEMPOTENCY_CONFLICT.
    /// The digest is an HMAC with a local key, so a secret in the semantic
    /// content is never stored or comparable outside this process.
    /// </summary>
    public JsonValue Idempotent(string scope, string command, string? key, JsonValue semantic, Func<ConfigStore, JsonValue> body)
    {
        lock (_lock)
        {
            if (key is null) return body(this);
            var now = _clock.Now();
            Run("DELETE FROM mutation_keys WHERE expires_at <= ? AND state <> 'pending'", now.ToUnixTimeSeconds());
            var digest = Digest(command, semantic);
            if (Row("SELECT digest, state, result FROM mutation_keys WHERE scope=? AND command=? AND key=?", scope, command, key) is { } row)
            {
                if (S(row[0]) != digest)
                    throw new ContractError(ErrorCode.IdempotencyConflict, "this idempotency key was used for a different request");
                return S(row[1]) switch
                {
                    "done" => StrictJson.Parse(S(row[2]) ?? "null"),
                    "failed" => throw StoredError(S(row[2])),
                    _ => throw new ContractError(ErrorCode.InternalError, "an earlier request with this key is still being recovered", retryable: true),
                };
            }
            Run("INSERT INTO mutation_keys VALUES(?,?,?,?,'pending',NULL,?,?)", scope, command, key, digest, Timestamp(now),
                (long)(now.ToUnixTimeSeconds() + _options.IdempotencyRetentionSeconds));
            try
            {
                var result = body(this);
                Run("UPDATE mutation_keys SET state='done', result=? WHERE scope=? AND command=? AND key=?", result.Encoded(), scope, command, key);
                return result;
            }
            catch (SimulatedCrashException)
            {
                throw;
            }
            catch
            {
                // Every mutation is transactional or cleans up after itself on a
                // non-crash failure, so nothing happened: forget the key.
                Run("DELETE FROM mutation_keys WHERE scope=? AND command=? AND key=?", scope, command, key);
                throw;
            }
        }
    }

    private string Digest(string command, JsonValue semantic)
    {
        var canonical = JsonValue.Obj(("command", JsonValue.String(command)), ("params", Canonical(semantic))).Encoded();
        return Convert.ToBase64String(HMACSHA256.HashData(_digestKey, Encoding.UTF8.GetBytes(canonical)));
    }

    internal static JsonValue Canonical(JsonValue v) => v.Kind switch
    {
        JsonKind.Object => JsonValue.Object(v.ObjectMembers!.OrderBy(m => m.Key, StringComparer.Ordinal)
            .Select(m => new KeyValuePair<string, JsonValue>(m.Key, Canonical(m.Value)))),
        JsonKind.Array => JsonValue.Array(v.ArrayValue!.Select(Canonical)),
        _ => v,
    };

    private static ContractError StoredError(string? text)
    {
        try
        {
            if (text is not null && StrictJson.Parse(text) is var v && v["code"]?.StringValue is { } c && ErrorCodes.FromWire(c) is { } code)
                return new ContractError(code, v["message"]?.StringValue ?? "", v["retryable"]?.BoolValue);
        }
        catch (StrictJsonException) { }
        return new ContractError(ErrorCode.InternalError, "an earlier request with this key failed");
    }

    // ---- Generic resource rows ----

    internal sealed record ResourceRow(string Id, int CurrentRevision, string State, bool Deleted, JsonValue Body,
                                       string? RefId, int? RefRevision, string? FallbackId, int? FallbackRevision, string? CredentialId);

    private ResourceRow? Load(ConfigResourceKind kind, string id, bool includeDeleted = false)
    {
        var r = Row($"""
            SELECT c.id, c.current_revision, c.state, c.deleted_at, r.body, r.ref_id, r.ref_revision,
                   r.fallback_id, r.fallback_revision, r.credential_id
            FROM {kind.Table()} c JOIN {kind.RevisionTable()} r ON r.id = c.id AND r.revision = c.current_revision
            WHERE c.id = ?
            """, id);
        if (r is null) return null;
        var deleted = r[3] is not null;
        if (deleted && !includeDeleted) return null;
        return new ResourceRow(S(r[0])!, (int)L(r[1])!, S(r[2])!, deleted, StrictJson.Parse(S(r[4])!), S(r[5]),
            (int?)L(r[6]), S(r[7]), (int?)L(r[8]), S(r[9]));
    }

    /// <summary>The body of one exact revision (immutable snapshot).</summary>
    public JsonValue? RevisionBody(ConfigResourceKind kind, string id, int revision)
    {
        lock (_lock) return RevisionBodyLocked(kind, id, revision);
    }

    private JsonValue? RevisionBodyLocked(ConfigResourceKind kind, string id, int revision)
    {
        if (Row($"SELECT body FROM {kind.RevisionTable()} WHERE id=? AND revision=?", id, revision) is not { } r) return null;
        var body = StrictJson.Parse(S(r[0])!);
        return kind == ConfigResourceKind.ModelProfile ? RenderModelProfile(body) : body;
    }

    private ResourceRow RequireCurrent(ConfigResourceKind kind, string id, int expectedRevision)
    {
        var row = Load(kind, id) ?? throw NotFound(kind);
        if (row.CurrentRevision != expectedRevision) throw Conflict(row.CurrentRevision);
        return row;
    }

    private static ContractError NotFound(ConfigResourceKind kind) => new(ErrorCode.NotFound, $"{kind.Wire()} not found");

    private static ContractError Conflict(int current) => new(ErrorCode.ConfigConflict, "the resource changed; reload and retry",
        details: JsonValue.Obj(("currentRevision", JsonValue.Int(current))));

    private void InsertRevision(ConfigResourceKind kind, string id, int revision, JsonValue body, string? refId = null,
                                int? refRevision = null, string? fallbackId = null, int? fallbackRevision = null, string? credentialId = null) =>
        Run($"INSERT INTO {kind.RevisionTable()} VALUES(?,?,?,?,?,?,?,?,?)",
            id, revision, body.Encoded(), refId, refRevision, fallbackId, fallbackRevision, credentialId, NowText);

    private void InsertNew(ConfigResourceKind kind, string id, JsonValue body, string? refId = null, int? refRevision = null,
                           string? fallbackId = null, int? fallbackRevision = null, string? credentialId = null)
    {
        var seq = L(Row($"SELECT COALESCE(MAX(seq),0)+1 FROM {kind.Table()}")?[0]) ?? 1;
        Run($"INSERT INTO {kind.Table()} VALUES(?,?,1,'enabled',?,NULL,NULL)", id, seq, NowText);
        InsertRevision(kind, id, 1, body, refId, refRevision, fallbackId, fallbackRevision, credentialId);
    }

    private int Advance(ConfigResourceKind kind, ResourceRow row, JsonValue body, string? refId, int? refRevision,
                        string? fallbackId, int? fallbackRevision, string? credentialId)
    {
        var next = row.CurrentRevision + 1;
        var state = body["state"]?.StringValue ?? row.State;
        var changed = Run($"UPDATE {kind.Table()} SET current_revision=?, state=? WHERE id=? AND current_revision=? AND deleted_at IS NULL",
            next, state, row.Id, row.CurrentRevision);
        if (changed != 1) throw Conflict(row.CurrentRevision);
        InsertRevision(kind, row.Id, next, body, refId, refRevision, fallbackId, fallbackRevision, credentialId);
        return next;
    }

    private JsonValue Stamp(JsonValue body, int revision) =>
        body.Setting("revision", JsonValue.Int(revision)).Setting("updatedAt", JsonValue.String(NowText));

    // ---- Listing ----

    public JsonValue List(ConfigResourceKind kind, long? limit, string? cursor, bool includeDisabled, string? connectionId = null)
    {
        lock (_lock)
        {
            var n = limit ?? 20;
            if (n is < 1 or > 100) throw new ContractError(ErrorCode.ValidationError, "limit must be 1...100");
            var filter = $"{kind.Wire()}|{(includeDisabled ? "true" : "false")}|{connectionId ?? ""}";
            var filterTag = Convert.ToBase64String(SHA256.HashData(Encoding.UTF8.GetBytes(filter)))[..12];
            long after = 0;
            if (cursor is not null)
            {
                string text;
                try { text = Encoding.UTF8.GetString(Convert.FromBase64String(cursor)); }
                catch (FormatException) { throw new ContractError(ErrorCode.ValidationError, "invalid cursor"); }
                var parts = text.Split('|');
                if (parts.Length != 3 || parts[0] != "v1" || !long.TryParse(parts[2], NumberStyles.None, CultureInfo.InvariantCulture, out var seq))
                    throw new ContractError(ErrorCode.ValidationError, "invalid cursor");
                if (parts[1] != filterTag) throw new ContractError(ErrorCode.ValidationError, "the cursor belongs to a different filter");
                after = seq;
            }
            var sql = $"""
                SELECT c.id, c.seq FROM {kind.Table()} c JOIN {kind.RevisionTable()} r ON r.id=c.id AND r.revision=c.current_revision
                WHERE c.deleted_at IS NULL AND c.seq > ?
                """;
            var args = new List<object?> { after };
            if (!includeDisabled) sql += " AND c.state = 'enabled'";
            if (connectionId is not null) { sql += " AND r.ref_id = ?"; args.Add(connectionId); }
            sql += " ORDER BY c.seq LIMIT ?";
            args.Add(n + 1);
            var rows = Rows(sql, [.. args]);
            var items = new List<JsonValue>();
            foreach (var r in rows.Take((int)n))
            {
                if (Load(kind, S(r[0])!)?.Body is { } body)
                    items.Add(kind == ConfigResourceKind.ModelProfile ? RenderModelProfile(body) : body);
            }
            var next = JsonValue.Null;
            if (rows.Count > n && L(rows.Take((int)n).Last()[1]) is { } last)
                next = JsonValue.String(Convert.ToBase64String(Encoding.UTF8.GetBytes($"v1|{filterTag}|{last}")));
            return JsonValue.Obj(("items", JsonValue.Array(items)), ("nextCursor", next));
        }
    }

    public JsonValue Get(ConfigResourceKind kind, string id)
    {
        lock (_lock)
        {
            var row = Load(kind, id) ?? throw NotFound(kind);
            return kind == ConfigResourceKind.ModelProfile ? RenderModelProfile(row.Body) : row.Body;
        }
    }

    // ---- Connections ----

    public JsonValue CreateConnection(string name, string protocol, string baseUrl, long timeoutMs, string apiKey)
    {
        lock (_lock)
        {
            CheckProtocol(protocol);
            var url = EndpointPolicy.Normalize(baseUrl, _options.AllowLoopbackHttp);
            var connectionId = _newId(ConfigResourceKind.Connection.IdPrefix());
            var credentialId = StoreNewCredential(apiKey, connectionId);
            var t = NowText;
            var body = JsonValue.Obj(
                ("connectionId", JsonValue.String(connectionId)), ("revision", JsonValue.Int(1)), ("name", JsonValue.String(name)),
                ("protocol", JsonValue.String(protocol)), ("baseUrl", JsonValue.String(url.AbsoluteUri)),
                ("credentialRef", JsonValue.String(credentialId)), ("state", JsonValue.String("enabled")),
                ("timeoutMs", JsonValue.Int(timeoutMs)), ("createdAt", JsonValue.String(t)), ("updatedAt", JsonValue.String(t)));
            Transaction(() =>
            {
                InsertNew(ConfigResourceKind.Connection, connectionId, body, credentialId: credentialId);
                Run("UPDATE credential_identities SET state='active', activated_at=? WHERE credential_id=? AND state='pending'", t, credentialId);
            });
            return body;
        }
    }

    public JsonValue UpdateConnection(string id, int expectedRevision, JsonValue patch)
    {
        lock (_lock)
        {
            var row = RequireCurrent(ConfigResourceKind.Connection, id, expectedRevision);
            var body = row.Body;
            if (patch["protocol"]?.StringValue is { } p) { CheckProtocol(p); body = body.Setting("protocol", JsonValue.String(p)); }
            if (patch["name"] is { } n) body = body.Setting("name", n);
            if (patch["baseUrl"]?.StringValue is { } u)
                body = body.Setting("baseUrl", JsonValue.String(EndpointPolicy.Normalize(u, _options.AllowLoopbackHttp).AbsoluteUri));
            if (patch["timeoutMs"] is { } to) body = body.Setting("timeoutMs", to);
            if (patch["state"] is { } s) body = body.Setting("state", s);
            return WriteConnectionRevision(row, body, row.CredentialId);
        }
    }

    public JsonValue Disable(ConfigResourceKind kind, string id, int expectedRevision)
    {
        lock (_lock)
        {
            var row = RequireCurrent(kind, id, expectedRevision);
            if (row.State == "disabled") return kind == ConfigResourceKind.ModelProfile ? RenderModelProfile(row.Body) : row.Body;
            var body = row.Body.Setting("state", JsonValue.String("disabled"));
            if (kind == ConfigResourceKind.Connection) return WriteConnectionRevision(row, body, row.CredentialId);
            return Transaction(() =>
            {
                var next = Advance(kind, row, Stamp(body, row.CurrentRevision + 1), row.RefId, row.RefRevision,
                    row.FallbackId, row.FallbackRevision, null);
                return RevisionBodyLocked(kind, id, next)!;
            });
        }
    }

    private JsonValue WriteConnectionRevision(ResourceRow row, JsonValue body, string? credentialId) => Transaction(() =>
    {
        var b = Stamp(body, row.CurrentRevision + 1);
        Advance(ConfigResourceKind.Connection, row, b, null, null, null, null, credentialId);
        return b;
    });

    private static void CheckProtocol(string p)
    {
        if (p != "openai_chat") throw new ContractError(ErrorCode.UnsupportedProtocol, "only openai_chat is implemented in this version");
    }

    // ---- Credentials (§10.2) ----

    private string StoreNewCredential(string secret, string connectionId)
    {
        var credentialId = _newId("cred");
        Run("INSERT INTO credential_identities VALUES(?,?, 'pending', ?, NULL, NULL)", credentialId, connectionId, NowText);
        _fault?.Invoke(ConfigFaultPoint.AfterPendingIdentity);
        try
        {
            _credentials.Write(credentialId, secret);
        }
        catch (CredentialStoreException)
        {
            Run("DELETE FROM credential_identities WHERE credential_id=? AND state='pending'", credentialId);
            throw new ContractError(ErrorCode.InternalError, "the system credential store refused the key", retryable: true);
        }
        _fault?.Invoke(ConfigFaultPoint.AfterSecretWrite);
        return credentialId;
    }

    public JsonValue RotateCredential(string connectionId, int expectedRevision, string apiKey)
    {
        lock (_lock)
        {
            var row = RequireCurrent(ConfigResourceKind.Connection, connectionId, expectedRevision);
            var newCredential = StoreNewCredential(apiKey, connectionId);
            var old = row.CredentialId;
            var t = NowText;
            JsonValue body;
            try
            {
                body = Transaction(() =>
                {
                    var b = Stamp(row.Body.Setting("credentialRef", JsonValue.String(newCredential)), row.CurrentRevision + 1);
                    Advance(ConfigResourceKind.Connection, row, b, null, null, null, null, newCredential);
                    Run("UPDATE credential_identities SET state='active', activated_at=? WHERE credential_id=?", t, newCredential);
                    if (old is not null) RevokeInTransaction(old, t);
                    return b;
                });
            }
            catch (ContractError)
            {
                try { _credentials.Delete(newCredential); } catch (CredentialStoreException) { }
                Run("DELETE FROM credential_identities WHERE credential_id=? AND state='pending'", newCredential);
                throw;
            }
            _fault?.Invoke(ConfigFaultPoint.AfterActivate);
            ApplyOutboxLocked();
            return body;
        }
    }

    private void RevokeInTransaction(string credentialId, string t)
    {
        Run("UPDATE credential_identities SET state='revoked', revoked_at=? WHERE credential_id=? AND state<>'revoked'", t, credentialId);
        Run("INSERT INTO outbox(kind, payload, state, created_at) VALUES('credential_revoked', ?, 'pending', ?)",
            JsonValue.Obj(("credentialId", JsonValue.String(credentialId))).Encoded(), t);
    }

    /// <summary>
    /// Deliver committed revocations: notify listeners, then remove the old
    /// secret. A failed removal stays pending and is retried; the identity is
    /// already revoked, so it can never be resolved again either way.
    /// </summary>
    public int ApplyOutbox()
    {
        lock (_lock) return ApplyOutboxLocked();
    }

    private int ApplyOutboxLocked()
    {
        var done = 0;
        foreach (var r in Rows("SELECT seq, payload FROM outbox WHERE state='pending' ORDER BY seq"))
        {
            string? id;
            try { id = StrictJson.Parse(S(r[1]) ?? "")["credentialId"]?.StringValue; }
            catch (StrictJsonException) { continue; }
            if (id is null) continue;
            foreach (var l in _revocationListeners) l(id);
            try { _credentials.Delete(id); }
            catch (CredentialStoreException) { continue; }
            if (Run("UPDATE outbox SET state='done', done_at=? WHERE seq=?", NowText, r[0]) == 1) done++;
        }
        return done;
    }

    /// <summary>Crash recovery: drop pending identities and their secrets, fail interrupted mutations, replay the outbox.</summary>
    public void Recover()
    {
        lock (_lock)
        {
            foreach (var r in Rows("SELECT credential_id FROM credential_identities WHERE state='pending'"))
            {
                var id = S(r[0])!;
                try { _credentials.Delete(id); } catch (CredentialStoreException) { }
                Run("DELETE FROM credential_identities WHERE credential_id=? AND state='pending'", id);
            }
            var interrupted = new ContractError(ErrorCode.InternalError, "the request was interrupted; check the resource and retry with a new key");
            Run("UPDATE mutation_keys SET state='failed', result=? WHERE state='pending'", interrupted.Json.Encoded());
            ApplyOutboxLocked();
        }
    }

    /// <summary>
    /// The API key for a credential identity. Revoked or unknown identities
    /// never resolve, and there is no fallback to environment variables or
    /// any other account (SEC-002).
    /// </summary>
    public string ResolveSecret(string credentialId)
    {
        lock (_lock)
        {
            var r = Row("SELECT state FROM credential_identities WHERE credential_id=?", credentialId)
                ?? throw new ContractError(ErrorCode.CredentialRequired, "no credential is configured");
            switch (S(r[0]))
            {
                case "active":
                    string? secret;
                    try { secret = _credentials.Read(credentialId); }
                    catch (CredentialStoreException) { secret = null; }
                    if (string.IsNullOrEmpty(secret)) throw new ContractError(ErrorCode.CredentialRequired, "the stored credential is missing or locked");
                    return secret;
                case "revoked":
                    throw new ContractError(ErrorCode.CredentialRevoked, "the credential was revoked");
                default:
                    throw new ContractError(ErrorCode.CredentialRequired, "the credential is not active");
            }
        }
    }

    public string? CredentialState(string credentialId)
    {
        lock (_lock) return S(Row("SELECT state FROM credential_identities WHERE credential_id=?", credentialId)?[0]);
    }

    /// <summary>The credential identity a connection revision is bound to.</summary>
    public string? CredentialId(string connectionId, int revision)
    {
        lock (_lock) return S(Row("SELECT credential_id FROM ai_connection_revisions WHERE id=? AND revision=?", connectionId, revision)?[0]);
    }

    // ---- Delete (tombstones) ----

    public JsonValue Delete(ConfigResourceKind kind, string id, int expectedRevision)
    {
        lock (_lock)
        {
            var row = RequireCurrent(kind, id, expectedRevision);
            if (IsReferenced(kind, id) || _activeRunCheck(kind, id))
                throw new ContractError(ErrorCode.ResourceInUse, $"{kind.Wire()} is still referenced; change those references first");
            var t = NowText;
            var tombstoneRevision = row.CurrentRevision + 1;
            Transaction(() =>
            {
                var n = Run($"UPDATE {kind.Table()} SET deleted_at=?, deleted_revision=? WHERE id=? AND current_revision=? AND deleted_at IS NULL",
                    t, tombstoneRevision, id, row.CurrentRevision);
                if (n != 1) throw Conflict(row.CurrentRevision);
                if (kind == ConfigResourceKind.Connection && row.CredentialId is { } cred) RevokeInTransaction(cred, t);
            });
            if (kind == ConfigResourceKind.Connection) ApplyOutboxLocked();
            return JsonValue.Obj(("resourceType", JsonValue.String(kind.Wire())), ("resourceId", JsonValue.String(id)),
                ("revision", JsonValue.Int(tombstoneRevision)), ("deletedAt", JsonValue.String(t)));
        }
    }

    private bool IsReferenced(ConfigResourceKind kind, string id) => kind switch
    {
        ConfigResourceKind.Connection => LiveReferences(ConfigResourceKind.ModelProfile, "ref_id", id) > 0,
        ConfigResourceKind.ModelProfile => LiveReferences(ConfigResourceKind.GuiProfile, "ref_id", id) > 0,
        _ => Row("SELECT 1 FROM ai_defaults WHERE gui_profile_id=?", id) is not null
             || LiveReferences(ConfigResourceKind.GuiProfile, "fallback_id", id) > 0,
    };

    private long LiveReferences(ConfigResourceKind kind, string column, string id) =>
        L(Row($"""
            SELECT COUNT(*) FROM {kind.Table()} c JOIN {kind.RevisionTable()} r ON r.id=c.id AND r.revision=c.current_revision
            WHERE c.deleted_at IS NULL AND r.{column} = ?
            """, id)?[0]) ?? 0;

    // ---- Model profiles ----

    private ResourceRow PinnedTarget(ConfigResourceKind kind, string id, int revision)
    {
        var row = Load(kind, id) ?? throw new ContractError(ErrorCode.NotFound, $"referenced {kind.Wire()} not found");
        if (row.CurrentRevision != revision)
            throw new ContractError(ErrorCode.ConfigConflict, $"the referenced {kind.Wire()} has a newer revision",
                details: JsonValue.Obj(("currentRevision", JsonValue.Int(row.CurrentRevision))));
        if (row.State != "enabled") throw new ContractError(ErrorCode.ResourceDisabled, $"the referenced {kind.Wire()} is disabled");
        return row;
    }

    public JsonValue CreateModelProfile(JsonValue p)
    {
        lock (_lock)
        {
            var connectionId = p["connectionId"]!.StringValue!;
            var connectionRevision = (int)p["connectionRevision"]!.IntValue!;
            var conn = PinnedTarget(ConfigResourceKind.Connection, connectionId, connectionRevision);
            CheckProtocol(conn.Body["protocol"]?.StringValue ?? "");
            var id = _newId(ConfigResourceKind.ModelProfile.IdPrefix());
            var t = NowText;
            var body = JsonValue.Obj(
                ("modelProfileId", JsonValue.String(id)), ("revision", JsonValue.Int(1)), ("name", p["name"]!), ("state", JsonValue.String("enabled")),
                ("connectionId", JsonValue.String(connectionId)), ("connectionRevision", JsonValue.Int(connectionRevision)),
                ("modelId", p["modelId"]!), ("requestOptions", p["requestOptions"]!),
                ("maxOutputTokens", p["maxOutputTokens"]!), ("createdAt", JsonValue.String(t)), ("updatedAt", JsonValue.String(t)));
            Transaction(() => InsertNew(ConfigResourceKind.ModelProfile, id, body, connectionId, connectionRevision));
            return RenderModelProfile(body);
        }
    }

    public JsonValue UpdateModelProfile(string id, int expectedRevision, JsonValue patch)
    {
        lock (_lock)
        {
            var row = RequireCurrent(ConfigResourceKind.ModelProfile, id, expectedRevision);
            var body = row.Body;
            var refId = row.RefId;
            var refRevision = row.RefRevision;
            if (patch["connectionId"] is not null || patch["connectionRevision"] is not null)
            {
                var rev = (int?)patch["connectionRevision"]?.IntValue
                    ?? throw new ContractError(ErrorCode.ValidationError, "changing the connection needs connectionRevision");
                var cid = patch["connectionId"]?.StringValue ?? row.RefId!;
                PinnedTarget(ConfigResourceKind.Connection, cid, rev);
                refId = cid;
                refRevision = rev;
                body = body.Setting("connectionId", JsonValue.String(cid)).Setting("connectionRevision", JsonValue.Int(rev));
            }
            foreach (var k in new[] { "name", "modelId", "requestOptions", "maxOutputTokens", "state" })
                if (patch[k] is { } v) body = body.Setting(k, v);
            return Transaction(() =>
            {
                var next = Advance(ConfigResourceKind.ModelProfile, row, Stamp(body, row.CurrentRevision + 1), refId, refRevision, null, null, null);
                return RevisionBodyLocked(ConfigResourceKind.ModelProfile, id, next)!;
            });
        }
    }

    private static string LayerWire(CapabilityLayer l) => l switch
    {
        CapabilityLayer.Network => "network",
        CapabilityLayer.AuthModel => "authModel",
        CapabilityLayer.ImageInput => "imageInput",
        _ => "guiContract",
    };

    private JsonValue RenderModelProfile(JsonValue body)
    {
        var id = body["modelProfileId"]!.StringValue!;
        var rev = body["revision"]!.IntValue!.Value;
        var connectionRevision = body["connectionRevision"]!.IntValue!.Value;
        var caps = new List<(string, JsonValue)>();
        foreach (var layer in Enum.GetValues<CapabilityLayer>())
        {
            var wire = LayerWire(layer);
            if (Row("SELECT body FROM capability_evidence WHERE model_profile_id=? AND model_profile_revision=? AND layer=?", id, rev, wire) is { } r)
                caps.Add((wire, StrictJson.Parse(S(r[0])!)));
            else
                caps.Add((wire, JsonValue.Obj(
                    ("status", JsonValue.String("unknown")), ("checkedAt", JsonValue.Null), ("testOperationId", JsonValue.Null),
                    ("scope", JsonValue.Obj(("connectionRevision", JsonValue.Int(connectionRevision)))), ("reasonCode", JsonValue.Null))));
        }
        var members = body.ObjectMembers!.Where(m => m.Key != "capabilities").ToList();
        var at = members.FindIndex(m => m.Key == "createdAt");
        members.Insert(at < 0 ? members.Count : at, new("capabilities", JsonValue.Obj([.. caps])));
        return JsonValue.Object(members);
    }

    /// <summary>
    /// Record one layer's evidence for an exact model profile revision. Evidence
    /// belongs to that revision only; one layer never sets another (CFG-008).
    /// </summary>
    public void RecordCapabilityEvidence(string modelProfileId, int revision, CapabilityLayer layer, string status,
                                         string? operationId, string? reasonCode)
    {
        lock (_lock)
        {
            var body = RevisionBodyLocked(ConfigResourceKind.ModelProfile, modelProfileId, revision)
                ?? throw new ContractError(ErrorCode.NotFound, "model profile revision not found");
            var evidence = JsonValue.Obj(
                ("status", JsonValue.String(status)), ("checkedAt", JsonValue.String(NowText)),
                ("testOperationId", operationId is null ? JsonValue.Null : JsonValue.String(operationId)),
                ("scope", JsonValue.Obj(("connectionRevision", body["connectionRevision"]!), ("modelProfileRevision", JsonValue.Int(revision)))),
                ("reasonCode", reasonCode is null ? JsonValue.Null : JsonValue.String(reasonCode)));
            if (ContractBundle.Shared.ValidateDomain(evidence, "CapabilityEvidence").Count > 0)
                throw new ContractError(ErrorCode.ValidationError, "invalid capability evidence");
            Run("INSERT OR REPLACE INTO capability_evidence VALUES(?,?,?,?)", modelProfileId, revision, LayerWire(layer), evidence.Encoded());
        }
    }

    // ---- GUI profiles ----

    private void CheckAdapter(string? adapterId)
    {
        if (adapterId == "fixture_json_v1" && !_options.AllowFixtureAdapter)
            throw new ContractError(ErrorCode.CapabilityMismatch, "fixture_json_v1 is available only in test builds");
    }

    private (string Id, int Revision)? CheckFallback(JsonValue? refs, string? selfId)
    {
        if (refs?.ArrayValue is not { Count: > 0 } list) return null;
        if (list.Count > 1) throw new ContractError(ErrorCode.ValidationError, "at most one fallback profile");
        var fid = list[0]["guiProfileId"]!.StringValue!;
        var frev = (int)list[0]["revision"]!.IntValue!;
        if (fid == selfId) throw new ContractError(ErrorCode.ValidationError, "a profile cannot fall back to itself");
        var target = PinnedTarget(ConfigResourceKind.GuiProfile, fid, frev);
        var next = target.FallbackId;
        for (var hops = 0; next is not null && hops < 16; hops++)
        {
            if (next == selfId || next == fid) throw new ContractError(ErrorCode.ValidationError, "fallback profiles form a cycle");
            next = Load(ConfigResourceKind.GuiProfile, next)?.FallbackId;
        }
        return (fid, frev);
    }

    private static readonly string[] GuiFields =
        ["modelProfileId", "modelProfileRevision", "adapterId", "adapterVersion", "promptVersion",
         "parserVersion", "coordinateProtocol", "limits", "allowedFallbackProfileRefs"];

    public JsonValue CreateGuiProfile(JsonValue p)
    {
        lock (_lock)
        {
            CheckAdapter(p["adapterId"]?.StringValue);
            var mpId = p["modelProfileId"]!.StringValue!;
            var mpRev = (int)p["modelProfileRevision"]!.IntValue!;
            PinnedTarget(ConfigResourceKind.ModelProfile, mpId, mpRev);
            var fallback = CheckFallback(p["allowedFallbackProfileRefs"], null);
            var id = _newId(ConfigResourceKind.GuiProfile.IdPrefix());
            var t = NowText;
            var members = new List<(string, JsonValue)>
            {
                ("guiProfileId", JsonValue.String(id)), ("revision", JsonValue.Int(1)), ("name", p["name"]!), ("state", JsonValue.String("enabled")),
            };
            members.AddRange(GuiFields.Select(k => (k, p[k]!)));
            members.Add(("createdAt", JsonValue.String(t)));
            members.Add(("updatedAt", JsonValue.String(t)));
            var body = JsonValue.Obj([.. members]);
            Transaction(() => InsertNew(ConfigResourceKind.GuiProfile, id, body, mpId, mpRev, fallback?.Id, fallback?.Revision));
            return body;
        }
    }

    public JsonValue UpdateGuiProfile(string id, int expectedRevision, JsonValue patch)
    {
        lock (_lock)
        {
            var row = RequireCurrent(ConfigResourceKind.GuiProfile, id, expectedRevision);
            var body = row.Body;
            var refId = row.RefId;
            var refRevision = row.RefRevision;
            var fallbackId = row.FallbackId;
            var fallbackRevision = row.FallbackRevision;
            if (patch["adapterId"]?.StringValue is { } a) CheckAdapter(a);
            if (patch["modelProfileId"] is not null || patch["modelProfileRevision"] is not null)
            {
                var rev = (int?)patch["modelProfileRevision"]?.IntValue
                    ?? throw new ContractError(ErrorCode.ValidationError, "changing the model profile needs modelProfileRevision");
                var mid = patch["modelProfileId"]?.StringValue ?? row.RefId!;
                PinnedTarget(ConfigResourceKind.ModelProfile, mid, rev);
                refId = mid;
                refRevision = rev;
                body = body.Setting("modelProfileId", JsonValue.String(mid)).Setting("modelProfileRevision", JsonValue.Int(rev));
            }
            if (patch["allowedFallbackProfileRefs"] is { } refs)
            {
                var f = CheckFallback(refs, id);
                fallbackId = f?.Id;
                fallbackRevision = f?.Revision;
                body = body.Setting("allowedFallbackProfileRefs", refs);
            }
            foreach (var k in new[] { "name", "adapterId", "adapterVersion", "promptVersion", "parserVersion", "coordinateProtocol", "limits", "state" })
                if (patch[k] is { } v) body = body.Setting(k, v);
            return Transaction(() =>
            {
                var b = Stamp(body, row.CurrentRevision + 1);
                Advance(ConfigResourceKind.GuiProfile, row, b, refId, refRevision, fallbackId, fallbackRevision, null);
                return b;
            });
        }
    }

    // ---- Default pointer ----

    public JsonValue DefaultProfile()
    {
        lock (_lock) return DefaultProfileLocked();
    }

    private JsonValue DefaultProfileLocked()
    {
        var r = Row("SELECT revision, gui_profile_id FROM ai_defaults WHERE scope=? AND purpose='gui'", _options.DefaultScope)!;
        var id = S(r[1]);
        var resolved = id is null ? JsonValue.Null : Load(ConfigResourceKind.GuiProfile, id)?.Body ?? JsonValue.Null;
        return JsonValue.Obj(
            ("default", JsonValue.Obj(("revision", JsonValue.Int(L(r[0])!.Value)), ("guiProfileId", id is null ? JsonValue.Null : JsonValue.String(id)))),
            ("resolvedProfile", resolved));
    }

    public JsonValue SetDefault(string? guiProfileId, int expectedDefaultRevision, int? expectedProfileRevision)
    {
        lock (_lock)
        {
            Transaction(() =>
            {
                var current = (int)L(Row("SELECT revision FROM ai_defaults WHERE scope=? AND purpose='gui'", _options.DefaultScope)![0])!;
                if (current != expectedDefaultRevision) throw Conflict(current);
                if (guiProfileId is not null)
                {
                    var rev = expectedProfileRevision ?? throw new ContractError(ErrorCode.ValidationError, "expectedProfileRevision is required");
                    PinnedTarget(ConfigResourceKind.GuiProfile, guiProfileId, rev);
                }
                Run("UPDATE ai_defaults SET revision=?, gui_profile_id=?, updated_at=? WHERE scope=? AND purpose='gui' AND revision=?",
                    current + 1, guiProfileId, NowText, _options.DefaultScope, current);
            });
            return DefaultProfileLocked();
        }
    }
}
