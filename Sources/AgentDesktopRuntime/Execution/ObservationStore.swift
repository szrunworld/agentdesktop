
import AgentDesktopProtocol
import Foundation

/// What one observation saw, kept so later requests can be checked against
/// it: element references and image points are valid only together with
/// the snapshot they came from.
public struct StoredObservation: Sendable {
    public var snapshotId: String
    public var desktopId: String
    public var capturedAt: String
    public var screen: ScreenHandle
    /// The binding at capture time, if a window was bound.
    public var binding: TargetBinding?
    public var windowFrame: Rect?
    /// Pixel → global point: origin + pixel / scale.
    public var transform: (originX: Double, originY: Double, scale: Double)?
    public var imageSize: (width: Int, height: Int)?
    /// Element ID → the backend's element as read for this snapshot.
    public var elements: [String: PlatformElement]
    /// True when this snapshot read the elements, which replaces the
    /// backend's numbering for the window.
    public var readElements: Bool
}

public final class ObservationStore: @unchecked Sendable {
    public static let capacity = 256
    private let lock = NSLock()
    private var order: [String] = []
    private var byId: [String: StoredObservation] = [:]
    /// Per Desktop, the latest snapshot that read the bound window's elements.
    private var latestElementRead: [String: String] = [:]

    public init() {}

    func store(_ o: StoredObservation) {
        lock.withLock {
            byId[o.snapshotId] = o
            order.append(o.snapshotId)
            if o.readElements { latestElementRead[o.desktopId] = o.snapshotId }
            while order.count > Self.capacity {
                byId.removeValue(forKey: order.removeFirst())
            }
        }
    }

    public func find(_ id: String) -> StoredObservation? { lock.withLock { byId[id] } }

    /// Whether `id` is still the snapshot whose element numbering the
    /// backend holds for its Desktop.
    public func isLatestElementRead(_ id: String, desktopId: String) -> Bool {
        lock.withLock { latestElementRead[desktopId] == id }
    }

    func forget(desktopId: String) {
        lock.withLock {
            latestElementRead.removeValue(forKey: desktopId)
            for (id, o) in byId where o.desktopId == desktopId { byId.removeValue(forKey: id) }
            order.removeAll { byId[$0] == nil }
        }
    }
}

/// Screenshots and other large results, written owner-only and handed out
/// by path; never inlined in responses or events.
public final class ArtifactStore: @unchecked Sendable {
    public static let retentionHours = 24
    public let directory: String

    public init(directory: String, now: Date = Date()) throws {
        self.directory = directory
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let cutoff = now.addingTimeInterval(-Double(Self.retentionHours) * 3600)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] {
            let p = directory + "/" + name
            if let d = (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date, d < cutoff {
                try? FileManager.default.removeItem(atPath: p)
            }
        }
    }

    public func path(for artifactId: String, ext: String) -> String { "\(directory)/\(artifactId).\(ext)" }
}
