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

    /// Hard limits (Kevin, #144 review): a Run that never ends, or many
    /// Runs together, cannot grow the store without bound. Measured on
    /// 2026-10-09 (window screenshots, Retina): Calculator 43 KB, Dictionary
    /// near full screen 130 KB, Chess 3.0 MB, a whole 2560×1600 screen with
    /// a photo 8 MB. A GUI explorer Run takes at most about 60; a resident
    /// agent observing every 5 s for 2¾ hours takes 2,000.
    public struct Limits: Equatable, Sendable {
        /// Screenshots of one Run, or of one session outside any Run (a GUI
        /// explorer Run has its own session).
        public var perRunArtifacts = 2_000
        public var perRunBytes: Int64 = 2 << 30
        /// Everything in the store.
        public var totalBytes: Int64 = 10 << 30
        /// Free space the store always leaves on its volume.
        public var minFreeBytes: Int64 = 2 << 30
        public init() {}
    }
    var limits = Limits()
    /// Free bytes on the store's volume; nil when the volume cannot say
    /// (tests replace it). Asked at most every `freeSpaceInterval`, off the
    /// caller; a refusal follows from an unknown answer too.
    var freeBytes: @Sendable () -> Int64? = { nil }
    static let freeSpaceInterval: TimeInterval = 10
    private var free: (bytes: Int64?, at: Date)?
    private var refreshingFree = false
    /// Usage by quota bucket ("run:<id>", "session:<id>", "desktop:<id>"):
    /// each artifact counts from the moment it is admitted (a reservation),
    /// its bytes once it is registered.
    private var usage: [String: (count: Int, bytes: Int64)] = [:]
    private var usageTotal: Int64 = 0

    public init(directory: String, now: @escaping () -> Date = Date.init) throws {
        self.directory = directory
        self.clock = now
        self.lastSweep = now()
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let dir = directory
        freeBytes = {
            let values = try? URL(fileURLWithPath: dir).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values?.volumeAvailableCapacityForImportantUsage
        }
        sweep(at: lastSweep)
        recount()
        refreshFreeSpace()
    }

    /// Admit one new artifact to `bucket` and reserve its place, before the
    /// screenshot is taken, so a refused one is never written and parallel
    /// requests cannot all slip under a limit. Each admit is followed by
    /// `register(…, bucket:)` or `release(bucket:)`. A refusal is
    /// `limit_exceeded`; observing without a screenshot still works, and a
    /// Run's history (events, receipts) is never affected.
    public func admit(bucket: String) throws {
        let stale = lock.withLock { () -> Bool in
            guard let f = free else { return true }
            return clock().timeIntervalSince(f.at) >= Self.freeSpaceInterval && !refreshingFree
        }
        if stale { scheduleFreeSpace() }
        try lock.withLock {
            func refuse(_ reason: String, _ message: String) -> RuntimeError {
                RuntimeError("limit_exceeded", message + "; observe without a screenshot still works", phase: .handler,
                             details: .obj([("reason", .string(reason))]))
            }
            let u = usage[bucket] ?? (0, 0)
            if u.count >= limits.perRunArtifacts || u.bytes >= limits.perRunBytes {
                throw refuse("run_artifact_quota",
                             "\(bucket) already holds \(u.count) screenshots (\(u.bytes) bytes); at most \(limits.perRunArtifacts) or \(limits.perRunBytes) bytes")
            }
            if usageTotal >= limits.totalBytes {
                throw refuse("artifact_store_full", "the artifact store holds \(usageTotal) bytes, its limit is \(limits.totalBytes)")
            }
            guard let freeBytes = free?.bytes else {
                throw refuse("disk_unknown", "the free space on the artifact volume is unknown")
            }
            if freeBytes < limits.minFreeBytes {
                throw refuse("disk_low", "only \(freeBytes) bytes are free on the artifact volume; the store leaves at least \(limits.minFreeBytes)")
            }
            usage[bucket] = (u.count + 1, u.bytes)
        }
    }

    /// Give back a reservation whose screenshot was not made.
    public func release(bucket: String) {
        lock.withLock {
            guard let u = usage[bucket], u.count > 0 else { return }
            usage[bucket] = (u.count - 1, u.bytes)
        }
    }

    /// Ask the volume now (tests, and at start).
    func refreshFreeSpace() {
        let bytes = freeBytes()
        lock.withLock { free = (bytes, clock()); refreshingFree = false }
    }

    private func scheduleFreeSpace() {
        let go = lock.withLock { () -> Bool in defer { refreshingFree = true }; return !refreshingFree }
        guard go else { return }
        sweeper.async { [self] in refreshFreeSpace() }
    }

    /// Usage from the records on disk, once, at start (nothing else runs yet).
    private func recount() {
        var byBucket: [String: (count: Int, bytes: Int64)] = [:]
        var total: Int64 = 0
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] where name.hasSuffix(".meta.json") {
            guard let m = FileManager.default.contents(atPath: directory + "/" + name).flatMap({ try? StrictJSON.parse($0) }),
                  let size = m["byteSize"]?.intValue else { continue }
            total += Int64(size)
            if let bucket = m["bucket"]?.stringValue ?? m["runId"]?.stringValue.map({ "run:" + $0 }) {
                let u = byBucket[bucket] ?? (0, 0)
                byBucket[bucket] = (u.count + 1, u.bytes + Int64(size))
            }
        }
        lock.withLock { usage = byBucket; usageTotal = total }
    }

    /// One artifact left the store: take it off its bucket and the total.
    private func forget(bucket: String?, bytes: Int64) {
        lock.withLock {
            usageTotal = max(0, usageTotal - bytes)
            if let bucket, let u = usage[bucket] {
                usage[bucket] = (max(0, u.count - 1), max(0, u.bytes - bytes))
            }
        }
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
            let meta = FileManager.default.contents(atPath: metaPath(id)).flatMap { try? StrictJSON.parse($0) }
            let runId = meta?["runId"]?.stringValue
            if keep(id, runId) { continue }
            for name in names { unlink(directory + "/" + name) }
            // Incremental, under the lock: a full recount here could lose a
            // write registered meanwhile.
            if let size = meta?["byteSize"]?.intValue {
                forget(bucket: meta?["bucket"]?.stringValue ?? runId.map { "run:" + $0 }, bytes: Int64(size))
            }
        }
    }

    /// The artifact a file in the store belongs to, if the store named it.
    static func artifactId(ofFile name: String) -> String? {
        let id: Substring
        if name.hasSuffix(".screen.png") {
            // The whole-screen capture a cropped screenshot is cut from
            // (EnginePlatform), left behind if the Runtime died mid-crop.
            let image = name.dropLast(".screen.png".count)
            guard let dot = image.lastIndex(of: "."), extensions.values.contains(String(image[image.index(after: dot)...])) else { return nil }
            id = image[..<dot]
        } else if name.hasSuffix(".meta.json") {
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
                         createdAt: String, bucket: String? = nil) throws -> Info {
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
        if let bucket { meta = meta.setting("bucket", .string(bucket)) }
        let sidecar = metaPath(artifactId)
        guard FileManager.default.createFile(atPath: sidecar, contents: Data(meta.encoded().utf8),
                                             attributes: [.posixPermissions: 0o600])
        else { throw RuntimeError("internal_error", "cannot record artifact \(artifactId)", phase: .handler) }
        lock.withLock {
            usageTotal += Int64(data.count)
            // Its count was reserved by admit(bucket:); its bytes count now.
            if let bucket {
                let u = usage[bucket] ?? (0, 0)
                usage[bucket] = (u.count, u.bytes + Int64(data.count))
            }
        }
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
