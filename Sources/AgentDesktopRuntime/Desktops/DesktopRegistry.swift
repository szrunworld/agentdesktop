import AgentDesktopProtocol
import Foundation

/// The window a Desktop acts on, fixed by process launch and window ID.
/// `generation` grows with every bind and unbind of the Desktop, so a
/// snapshot taken under an older binding is recognisably stale.
public struct TargetBinding: Equatable, Sendable {
    public var generation: Int
    public var process: ProcessIdentity
    public var windowId: UInt32
    public var appName: String
    public var boundAt: String

    public var json: JSONValue {
        .obj([("generation", .int(generation)), ("process", process.json), ("windowId", .int(Int(windowId))),
              ("appName", .string(appName)), ("boundAt", .string(boundAt))])
    }
}

/// What a Desktop's surface is. A virtual Desktop owns a display the
/// Runtime created and destroys; a physical Desktop only refers to one of
/// the user's displays and binds windows already there, never moving them,
/// never launching or quitting apps, never touching the display.
public enum DesktopKind: String, Sendable {
    case virtual
    case physical
}

/// One logical working environment. Its lock orders every write and
/// observation of this Desktop; other Desktops proceed in parallel.
public final class DesktopRecord: @unchecked Sendable {
    public let desktopId: String
    public let name: String
    public let createdAt: String
    public let screen: ScreenHandle
    public let kind: DesktopKind
    /// Held while the Desktop's state or its surface is read or changed.
    public let lock = NSLock()
    public internal(set) var binding: TargetBinding? {
        didSet { pidLock.withLock { _boundPID = binding?.process.pid } }
    }
    /// The bound process, readable without the Desktop's lock (which an
    /// action holds for its whole duration): G2 reads the app's menu bar
    /// before taking it. A hint only; the action re-checks under the lock.
    var boundPID: Int32? { pidLock.withLock { _boundPID } }
    private let pidLock = NSLock()
    private var _boundPID: Int32?
    public internal(set) var generation = 0
    public internal(set) var state = "ready"
    /// Apps app.launch started here: the agent's, closed with the Desktop.
    public internal(set) var launched: [ProcessIdentity] = []

    /// The principal that created it; a paired app's grant can cover
    /// "the Desktops I created".
    public internal(set) var createdBy: String?

    init(desktopId: String, name: String, createdAt: String, screen: ScreenHandle, kind: DesktopKind = .virtual) {
        self.desktopId = desktopId
        self.name = name
        self.createdAt = createdAt
        self.screen = screen
        self.kind = kind
    }

    public static func screenJSON(_ s: ScreenHandle) -> JSONValue {
        .obj([("displayId", .int(Int(s.displayId))), ("frame", s.frame.json), ("hiDPI", .bool(s.hiDPI))])
    }

    func json(openSessions: Int) -> JSONValue {
        .obj([
            ("desktopId", .string(desktopId)), ("name", .string(name)), ("kind", .string(kind.rawValue)), ("state", .string(state)),
            ("createdAt", .string(createdAt)), ("screen", Self.screenJSON(screen)),
            ("binding", binding?.json ?? .null), ("openSessions", .int(openSessions)),
        ])
    }
}

/// Desktops this Runtime created. They live as long as the host process:
/// the surfaces behind them do not survive it.
public final class DesktopRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var desktops: [DesktopRecord] = []

    public init() {}

    public var count: Int { lock.withLock { desktops.count } }

    public func list() -> [DesktopRecord] { lock.withLock { desktops } }

    public func find(_ id: String) -> DesktopRecord? { lock.withLock { desktops.first { $0.desktopId == id } } }

    public func names() -> [String] { lock.withLock { desktops.map(\.name) } }

    /// Names of the Desktops one principal created (names are unique per creator).
    func names(createdBy clientId: String) -> [String] {
        lock.withLock { desktops.filter { ($0.createdBy ?? "") == clientId }.map(\.name) }
    }

    @discardableResult
    func add(desktopId: String, name: String, screen: ScreenHandle, createdAt: String, kind: DesktopKind = .virtual) -> DesktopRecord {
        let r = DesktopRecord(desktopId: desktopId, name: name, createdAt: createdAt, screen: screen, kind: kind)
        lock.withLock { desktops.append(r) }
        return r
    }

    /// The physical Desktop already attached to a display, if any: one
    /// display backs at most one Desktop, so two agents never share its
    /// windows without the Runtime's lock between them.
    func physical(displayId: UInt32) -> DesktopRecord? {
        lock.withLock { desktops.first { $0.kind == .physical && $0.screen.displayId == displayId } }
    }

    func remove(_ id: String) {
        lock.withLock { desktops.removeAll { $0.desktopId == id } }
    }

    /// A new ID nobody used in this or an earlier run.
    static func newId(prefix: String) -> String {
        "\(prefix)_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12)
    }
}
