import AgentDesktopContracts
import AgentDesktopProtocol
import Foundation

/// Procedures: replayable steps that reached a verified state, per app.
/// A new save under an existing name is a new version; old versions stay.
public final class ProcedureStore: @unchecked Sendable {
    private let db: SQLiteDatabase
    private let now: @Sendable () -> Date

    public init(path: String?, now: @escaping @Sendable () -> Date = { Date() }) throws {
        db = try SQLiteDatabase(path: path)
        self.now = now
        try db.execute("""
            CREATE TABLE IF NOT EXISTS procedures (procedure_id TEXT PRIMARY KEY, name TEXT NOT NULL, version INTEGER NOT NULL,
              app TEXT NOT NULL, source TEXT NOT NULL, steps TEXT NOT NULL, verification TEXT NOT NULL, created_at TEXT NOT NULL,
              UNIQUE (name, app, version))
            """)
    }

    @discardableResult
    func save(name: String, app: String, source: String, steps: [JSONValue], verification: JSONValue) throws -> JSONValue {
        let version = (((try db.query("SELECT COALESCE(MAX(version), 0) FROM procedures WHERE name = ? AND app = ?",
                                      [.text(name), .text(app)]).first?[0]) as? Int64) ?? 0) + 1
        let id = DesktopRegistry.newId(prefix: "proc")
        try db.execute("""
            INSERT INTO procedures (procedure_id, name, version, app, source, steps, verification, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, [.text(id), .text(name), .int(version), .text(app), .text(source), .text(JSONValue.array(steps).encoded()),
                  .text(verification.encoded()), .text(Timestamp.string(now()))])
        return try find(id)!
    }

    public func find(_ id: String) throws -> JSONValue? {
        try db.query("SELECT procedure_id, name, version, app, source, steps, verification, created_at FROM procedures WHERE procedure_id = ?",
                     [.text(id)]).first.map(Self.json)
    }

    public func list(app: String?) throws -> [JSONValue] {
        let rows = try app.map {
            try db.query("SELECT procedure_id, name, version, app, source, steps, verification, created_at FROM procedures WHERE app = ? ORDER BY name, version", [.text($0)])
        } ?? db.query("SELECT procedure_id, name, version, app, source, steps, verification, created_at FROM procedures ORDER BY app, name, version")
        return rows.map(Self.json)
    }

    static func json(_ r: [Any?]) -> JSONValue {
        .obj([
            ("procedureId", .string(r[0] as! String)), ("name", .string(r[1] as! String)), ("version", .int(Int(r[2] as! Int64))),
            ("app", .string(r[3] as! String)), ("source", .string(r[4] as! String)),
            ("steps", (try? StrictJSON.parse(r[5] as! String)) ?? .array([])),
            ("verification", (try? StrictJSON.parse(r[6] as! String)) ?? .obj([])),
            ("createdAt", .string(r[7] as! String)),
        ])
    }
}

/// Model-driven exploration toward a goal, run by the GUI service through
/// the Runtime's ports. The host provides it only when real GUI input is
/// switched on.
public protocol UnitExplorer: Sendable {
    /// Explore until the GUI service's own verifier holds or it gives up.
    /// `target` is the elementTextEquals condition the explorer verifies.
    func explore(desktopId: String, sessionId: String, goal: String, target: JSONValue, maxSteps: Int?,
                 deadline: Date) -> ExploreOutcome
}

public struct ExploreOutcome: Sendable {
    public var state: String
    public var modelCalls: Int
    /// The GUI run, so its executed steps can be learned.
    public var guiRunId: String?
    public var message: String?

    public init(state: String, modelCalls: Int, guiRunId: String?, message: String? = nil) {
        self.state = state
        self.modelCalls = modelCalls
        self.guiRunId = guiRunId
        self.message = message
    }
}
