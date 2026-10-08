import enum AgentDesktopProtocol.StrictJSON
import enum AgentDesktopProtocol.JSONValue
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

    /// No element reference of the Desktop is valid until the next stored
    /// read: the backend's numbering is about to be replaced.
    func invalidateElementRefs(desktopId: String) {
        lock.withLock { _ = latestElementRead.removeValue(forKey: desktopId) }
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
    /// How often a long-running Runtime looks for expired files again; a
    /// client that observes every few seconds would otherwise fill the
    /// disk between restarts.
    public static let sweepInterval: TimeInterval = 600
    public let directory: String
    private let clock: () -> Date
    private let lock = NSLock()
    private var lastSweep: Date
    /// At most one periodic sweep queued or running: a sweep slower than
    /// the interval does not let another pile up behind it.
    private var sweeping = false
    /// Sweeps after the first run here, off the caller: `register` is
    /// called under a Desktop's lock (observe step 1), and a day of
    /// preview screenshots takes seconds to scan.
    private let sweeper = DispatchQueue(label: "agentdesktop.artifacts.sweep", qos: .utility)
    /// Artifacts kept whatever their age, asked per artifact with its Run:
    /// the Runtime keeps the screenshot of an observation it still holds
    /// and everything of a Run that has not ended (RuntimeService sets
    /// this). The start-up sweep runs before it is set; by then every Run
    /// left from before has ended (RunStore, runtime_restarted) and no
    /// observation is held.
    var retained: @Sendable (_ artifactId: String, _ runId: String?) -> Bool {
        get { lock.withLock { _retained } }
        set { lock.withLock { _retained = newValue } }
    }
    private var _retained: @Sendable (String, String?) -> Bool = { _, _ in false }
    /// Tests: runs on the sweeper before each background sweep.
    var beforeSweep: (@Sendable () -> Void)?

    public init(directory: String, now: @escaping () -> Date = Date.init) throws {
        self.directory = directory
        self.clock = now
        self.lastSweep = now()
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        sweep(at: lastSweep)
    }

    /// Removes artifacts older than the retention period (methods.json
    /// `transport.artifacts.retentionHours`), each with its record, unless
    /// the Runtime still needs them. Only the store's own files are
    /// touched: names this store gives ("<id>.<ext>", "<id>.meta.json"),
    /// as regular files directly in its directory; anything else there,
    /// a directory, or a link is left alone.
    func sweep(at now: Date) {
        let cutoff = now.addingTimeInterval(-Double(Self.retentionHours) * 3600)
        var files: [String: [String]] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] {
            if let id = Self.artifactId(ofFile: name) { files[id, default: []].append(name) }
        }
        let keep = retained
        for (id, names) in files {
            var newest: Date?
            var regular = true
            for name in names {
                var st = stat()
                guard lstat(directory + "/" + name, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { regular = false; break }
                let m = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
                newest = max(newest ?? m, m)
            }
            // An artifact goes when all of its files are old, never half.
            guard regular, let newest, newest < cutoff else { continue }
            let runId = FileManager.default.contents(atPath: metaPath(id))
                .flatMap { try? StrictJSON.parse($0) }?["runId"]?.stringValue
            if keep(id, runId) { continue }
            for name in names { unlink(directory + "/" + name) }
        }
    }

    /// The artifact a file in the store belongs to, if the store named it.
    static func artifactId(ofFile name: String) -> String? {
        let id: Substring
        if name.hasSuffix(".meta.json") {
            id = name.dropLast(".meta.json".count)
        } else if let dot = name.lastIndex(of: "."), extensions.values.contains(String(name[name.index(after: dot)...])) {
            id = name[..<dot]
        } else {
            return nil
        }
        return validId(String(id)) ? String(id) : nil
    }

    private func sweepIfDue() {
        let now = clock()
        let due: Bool = lock.withLock {
            guard !sweeping, now.timeIntervalSince(lastSweep) >= Self.sweepInterval else { return false }
            lastSweep = now
            sweeping = true
            return true
        }
        guard due else { return }
        let hook = beforeSweep
        // The closure holds the store, so a Runtime that stops meanwhile
        // leaves the sweep a valid directory and record to finish with.
        sweeper.async { [self] in
            hook?()
            sweep(at: now)
            lock.withLock { sweeping = false }
        }
    }

    /// Tests: returns once any background sweep already started has finished.
    func waitForSweeps() { sweeper.sync {} }

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
        sweepIfDue()
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
