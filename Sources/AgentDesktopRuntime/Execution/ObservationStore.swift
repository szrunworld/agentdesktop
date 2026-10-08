import enum AgentDesktopContracts.StrictJSON
import enum AgentDesktopContracts.JSONValue
import AgentDesktopProtocol
import CryptoKit
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

    /// What a client may learn about an artifact. Clients get the id and
    /// these facts, never a path (runtime-api-v1-freeze §5).
    public struct Info: Equatable, Sendable {
        public let artifactId: String
        public let mediaType: String
        public let byteSize: Int
        public let sha256: String
        public let createdAt: String
        /// The principal whose request produced it; only it and the owner
        /// may read it.
        public let clientId: String
        public let runId: String?

        public var json: JSONValue {
            var m: [(String, JSONValue)] = [("artifactId", .string(artifactId)), ("mediaType", .string(mediaType)),
                                            ("byteSize", .int(byteSize)), ("sha256", .string(sha256)),
                                            ("createdAt", .string(createdAt))]
            if let runId { m.append(("runId", .string(runId))) }
            return .obj(m)
        }
    }

    static let extensions = ["image/png": "png"]

    /// Records who owns a file already written at `path(for:ext:)`. The
    /// facts live in a 0600 sidecar so they outlive a restart as long as
    /// the file does.
    @discardableResult
    public func register(_ artifactId: String, mediaType: String, clientId: String, runId: String?,
                         createdAt: String) throws -> Info {
        guard Self.validId(artifactId), let ext = Self.extensions[mediaType] else {
            throw RuntimeError("internal_error", "artifact \(artifactId) of \(mediaType) cannot be stored", phase: .handler)
        }
        let file = path(for: artifactId, ext: ext)
        let data = try Data(contentsOf: URL(fileURLWithPath: file))
        _ = chmod(file, 0o600)
        let info = Info(artifactId: artifactId, mediaType: mediaType, byteSize: data.count,
                        sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                        createdAt: createdAt, clientId: clientId, runId: runId)
        var meta = info.json.setting("clientId", .string(clientId))
        meta = meta.setting("ext", .string(ext))
        let sidecar = metaPath(artifactId)
        guard FileManager.default.createFile(atPath: sidecar, contents: Data(meta.encoded().utf8),
                                             attributes: [.posixPermissions: 0o600])
        else { throw RuntimeError("internal_error", "cannot record artifact \(artifactId)", phase: .handler) }
        return info
    }

    public func info(_ artifactId: String) -> Info? {
        guard Self.validId(artifactId),
              let data = FileManager.default.contents(atPath: metaPath(artifactId)),
              let m = try? StrictJSON.parse(data),
              let mediaType = m["mediaType"]?.stringValue, let size = m["byteSize"]?.intValue,
              let sha = m["sha256"]?.stringValue, let at = m["createdAt"]?.stringValue,
              let clientId = m["clientId"]?.stringValue,
              let ext = m["ext"]?.stringValue,
              FileManager.default.fileExists(atPath: path(for: artifactId, ext: ext))
        else { return nil }
        return Info(artifactId: artifactId, mediaType: mediaType, byteSize: size, sha256: sha, createdAt: at,
                    clientId: clientId, runId: m["runId"]?.stringValue)
    }

    /// The file behind an artifact, for in-process consumers only.
    public func file(of artifactId: String) -> String? {
        info(artifactId).flatMap { i in Self.extensions[i.mediaType].map { path(for: artifactId, ext: $0) } }
    }

    /// Up to `length` bytes from `offset`; `eof` when nothing follows.
    public func read(_ artifactId: String, offset: Int, length: Int) throws -> (data: Data, eof: Bool) {
        guard let file = file(of: artifactId), let h = FileHandle(forReadingAtPath: file) else {
            throw RuntimeError("not_found", "no artifact \(artifactId)", phase: .handler)
        }
        defer { try? h.close() }
        let size = Int(try h.seekToEnd())
        guard offset <= size else {
            throw RuntimeError.invalidArgument("offset \(offset) is past the end (\(size) bytes)")
        }
        try h.seek(toOffset: UInt64(offset))
        let data = try h.read(upToCount: length) ?? Data()
        return (data, offset + data.count >= size)
    }

    func metaPath(_ artifactId: String) -> String { "\(directory)/\(artifactId).meta.json" }

    /// Ids name files, so nothing but the Runtime's own alphabet.
    static func validId(_ id: String) -> Bool {
        id.hasPrefix("art_") && id.count <= 128 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }
}
