@testable import AgentDesktopProtocol
import CryptoKit
import Foundation
import Testing
@testable import AgentDesktopRuntime

// runtime-api-v1-freeze §5: an observation names its screenshot by id; the
// bytes come back through artifact.read, and only to whoever produced them
// (or the owner). No path ever crosses the wire.

@Test func anObservationNamesItsScreenshotByIdAndTheBytesComeBackInChunks() throws {
    let sc = try scene()
    let o = try #require(data(call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#)))
    #expect(contract.validate(o, "Observation").isEmpty, "\(o.encoded())")
    let image = try #require(o["image"])
    #expect(image["path"] == nil)
    #expect(o.encoded().contains(sc.s.artifacts.directory) == false)
    let id = try #require(image["artifactId"]?.stringValue)

    let shown = try #require(data(call(sc.s, sc.c, "artifact.show", params: #"{"artifactId":"\#(id)"}"#)))
    #expect(contract.validate(shown, "Artifact").isEmpty, "\(shown.encoded())")
    #expect(shown["sha256"] == image["sha256"])
    #expect(shown["byteSize"] == image["byteSize"])

    var bytes = Data()
    var reads = 0
    while true {
        let chunk = try #require(data(call(sc.s, sc.c, "artifact.read",
                                           params: #"{"artifactId":"\#(id)","offset":\#(bytes.count),"length":2}"#)))
        #expect(contract.validate(chunk, "ArtifactChunk").isEmpty)
        bytes.append(try #require(Data(base64Encoded: chunk["dataBase64"]?.stringValue ?? "")))
        reads += 1
        if chunk["eof"]?.boolValue == true { break }
    }
    #expect(reads > 1)
    #expect(bytes.count == shown["byteSize"]?.intValue)
    #expect(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == shown["sha256"]?.stringValue)
    let past = call(sc.s, sc.c, "artifact.read", params: #"{"artifactId":"\#(id)","offset":\#(bytes.count + 1)}"#)
    #expect(code(past) == "invalid_argument")
}

@Test func anotherClientCannotSeeAnArtifactAndIdsCannotEscapeTheStore() throws {
    let sc = try scene()
    let o = try #require(data(call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#)))
    let id = try #require(o["image"]?["artifactId"]?.stringValue)
    let (other, _) = try pairedConnection(sc.s, capabilities: ["observe"])
    #expect(code(call(sc.s, other, "artifact.show", params: #"{"artifactId":"\#(id)"}"#)) == "not_found")
    #expect(code(call(sc.s, other, "artifact.read", params: #"{"artifactId":"\#(id)"}"#)) == "not_found")
    // The owner sees every artifact.
    #expect(data(call(sc.s, sc.c, "artifact.show", params: #"{"artifactId":"\#(id)"}"#)) != nil)
    for bad in ["art_..", "x_1", "art_1.meta", "../art_1"] {
        #expect(sc.s.artifacts.info(bad) == nil, "\(bad)")
    }
    #expect(code(call(sc.s, sc.c, "artifact.show", params: #"{"artifactId":"art_missing"}"#)) == "not_found")
}

@Test func artifactsAndTheirRecordsAreOwnerOnlyFiles() throws {
    let sc = try scene()
    let o = try #require(data(call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#)))
    let id = try #require(o["image"]?["artifactId"]?.stringValue)
    for file in [sc.s.artifacts.path(for: id, ext: "png"), sc.s.artifacts.metaPath(id)] {
        let mode = try #require(try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int)
        #expect(mode == 0o600, "\(file)")
    }
}

// methods.json transport.artifacts.retentionHours holds while the Runtime
// keeps running, not only at start: a client that observes every few
// seconds must not fill the disk between restarts.
@Test func expiredArtifactsGoAwayWhileTheRuntimeRuns() throws {
    let dir = NSTemporaryDirectory() + "adt-art-\(UUID().uuidString.prefix(8))"
    defer { try? FileManager.default.removeItem(atPath: dir) }
    final class Clock: @unchecked Sendable { var now = Date() }
    let clock = Clock()
    let store = try ArtifactStore(directory: dir, now: { clock.now })
    func put(_ id: String) throws {
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: URL(fileURLWithPath: store.path(for: id, ext: "png")))
        try store.register(id, mediaType: "image/png", clientId: "owner", runId: nil, createdAt: Timestamp.string(clock.now))
    }
    try put("art_old")
    let past = clock.now.addingTimeInterval(-Double(ArtifactStore.retentionHours + 1) * 3600)
    for p in [store.path(for: "art_old", ext: "png"), store.metaPath("art_old")] {
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: p)
    }
    // Not yet due: the next sweep waits for the interval.
    clock.now = clock.now.addingTimeInterval(ArtifactStore.sweepInterval / 2)
    try put("art_mid")
    #expect(store.info("art_old") != nil)
    clock.now = clock.now.addingTimeInterval(ArtifactStore.sweepInterval)
    try put("art_new")
    store.waitForSweeps()
    #expect(store.info("art_old") == nil, "an expired artifact is removed on a later write")
    #expect(!FileManager.default.fileExists(atPath: store.path(for: "art_old", ext: "png")))
    #expect(!FileManager.default.fileExists(atPath: store.metaPath("art_old")))
    #expect(store.info("art_mid") != nil)
    #expect(store.info("art_new") != nil)
}

// register runs under a Desktop's lock (observe step 1); a sweep that
// takes seconds must not hold the write that started it.
@Test func aSlowSweepDoesNotHoldUpTheWriteThatStartedIt() throws {
    let dir = NSTemporaryDirectory() + "adt-art-\(UUID().uuidString.prefix(8))"
    defer { try? FileManager.default.removeItem(atPath: dir) }
    final class Clock: @unchecked Sendable { var now = Date() }
    let clock = Clock()
    let store = try ArtifactStore(directory: dir, now: { clock.now })
    let gate = DispatchSemaphore(value: 0)
    store.beforeSweep = { _ = gate.wait(timeout: .now() + 5) }
    defer { gate.signal() }
    clock.now = clock.now.addingTimeInterval(ArtifactStore.sweepInterval)
    try Data([0x89, 0x50, 0x4e, 0x47]).write(to: URL(fileURLWithPath: store.path(for: "art_a", ext: "png")))
    let start = Date()
    try store.register("art_a", mediaType: "image/png", clientId: "owner", runId: nil, createdAt: Timestamp.string(clock.now))
    #expect(Date().timeIntervalSince(start) < 0.5, "the write returned while the sweep was still held")
    #expect(store.info("art_a") != nil)
    gate.signal()
    store.waitForSweeps()
}

private final class SweepClock: @unchecked Sendable { var now = Date() }

private func aged(_ store: ArtifactStore, _ id: String, hours: Int, now: Date) throws {
    let past = now.addingTimeInterval(-Double(hours) * 3600)
    for p in [store.path(for: id, ext: "png"), store.metaPath(id)] {
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: p)
    }
}

// While a sweep is held on its queue, the Desktop it was started from goes
// on: observations and actions do not wait for it (Kevin, #144 review).
@Test func observeAndActKeepWorkingWhileASweepIsHeld() throws {
    let dir = NSTemporaryDirectory() + "adt-art-\(UUID().uuidString.prefix(8))"
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let clock = SweepClock()
    let store = try ArtifactStore(directory: dir, now: { clock.now })
    let gate = DispatchSemaphore(value: 0)
    final class Count: @unchecked Sendable { var n = 0 }
    let started = Count()
    store.beforeSweep = { started.n += 1; _ = gate.wait(timeout: .now() + 10) }
    defer { gate.signal() }
    let platform = FakePlatform()
    let s = RuntimeService(identity: RuntimeIdentity(instanceId: "rt_test", pid: getpid(), startedAt: Timestamp.string(Date()),
                                                     endpoint: "/tmp/t.sock", buildSource: "unknown"),
                           backend: FixedBackend(), platform: platform, artifacts: store)
    s.bindsOnlyLaunchedProcesses = false
    let c = handshaken(s)
    let d = try created(s, c)
    _ = call(s, c, "window.bind", params: #"{"desktopId":"\#(d)","pid":101}"#)
    let sid = try #require(data(call(s, c, "session.open", params: #"{"desktopId":"\#(d)"}"#))?["sessionId"]?.stringValue)
    clock.now = clock.now.addingTimeInterval(ArtifactStore.sweepInterval)
    store.refreshFreeSpace()  // the test clock jumps; a real one lets the 10 s refresh run
    // This observation starts the sweep, which then stays held.
    var t0 = Date()
    let first = try #require(data(call(s, c, "observe", context: #"{"sessionId":"\#(sid)"}"#)))
    #expect(Date().timeIntervalSince(t0) < 1)
    let snap = try #require(first["snapshotId"]?.stringValue)
    t0 = Date()
    let receipt = try #require(data(answer(s, #"{"apiVersion":"agentdesktop.runtime/1","requestId":"act-held","method":"act","context":{"sessionId":"\#(sid)"},"params":{"snapshotId":"\#(snap)","action":{"kind":"click","target":{"elementRef":"el_0"}}}}"#, c)))
    #expect(receipt["delivery"]?.stringValue == "dispatched")
    // More observations while the sweep is still held: none waits, none
    // queues a second sweep.
    for _ in 0..<3 {
        clock.now = clock.now.addingTimeInterval(ArtifactStore.sweepInterval)
        // The test clock jumps ten minutes; a real one lets the 10 s refresh run.
        store.refreshFreeSpace()
        #expect(data(call(s, c, "observe", context: #"{"sessionId":"\#(sid)"}"#)) != nil)
    }
    #expect(Date().timeIntervalSince(t0) < 2)
    gate.signal()
    store.waitForSweeps()
    #expect(started.n == 1, "one sweep at a time, even when it is slower than the interval")
}

// The sweep removes only what the Runtime no longer uses, and only its own
// files (Kevin, #144 review).
@Test func theSweepKeepsWhatIsInUseAndTouchesOnlyItsOwnFiles() throws {
    let root = NSTemporaryDirectory() + "adt-art-\(UUID().uuidString.prefix(8))"
    let dir = root + "/artifacts"
    defer { try? FileManager.default.removeItem(atPath: root) }
    let clock = SweepClock()
    let store = try ArtifactStore(directory: dir, now: { clock.now })
    func put(_ id: String, run: String?) throws {
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: URL(fileURLWithPath: store.path(for: id, ext: "png")))
        try store.register(id, mediaType: "image/png", clientId: "owner", runId: run, createdAt: Timestamp.string(clock.now))
    }
    try put("art_inuse", run: nil)
    try put("art_running", run: "run_live")
    try put("art_done", run: "run_over")
    try put("art_halfold", run: nil)
    for id in ["art_inuse", "art_running", "art_done"] { try aged(store, id, hours: 30, now: clock.now) }
    // Only the image is old: an artifact goes whole or not at all.
    try FileManager.default.setAttributes([.modificationDate: clock.now.addingTimeInterval(-30 * 3600)],
                                          ofItemAtPath: store.path(for: "art_halfold", ext: "png"))
    // Things in the directory the store did not make, all old.
    let old = clock.now.addingTimeInterval(-30 * 3600)
    let outside = root + "/outside.png"
    try Data([1]).write(to: URL(fileURLWithPath: outside))
    try FileManager.default.createSymbolicLink(atPath: dir + "/art_link.png", withDestinationPath: outside)
    try FileManager.default.createDirectory(atPath: dir + "/art_dir.png", withIntermediateDirectories: false)
    try Data([2]).write(to: URL(fileURLWithPath: dir + "/notes.txt"))
    for p in [outside, dir + "/art_dir.png", dir + "/notes.txt"] {
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: p)
    }
    store.retained = { id, run in id == "art_inuse" || run == "run_live" }
    clock.now = clock.now.addingTimeInterval(ArtifactStore.sweepInterval)
    try put("art_trigger", run: nil)
    store.waitForSweeps()
    #expect(store.info("art_inuse") != nil, "the screenshot of an observation still held stays")
    #expect(store.info("art_running") != nil, "artifacts of a Run that has not ended stay")
    #expect(store.info("art_done") == nil, "an expired artifact of an ended Run goes")
    #expect(store.info("art_halfold") != nil)
    #expect(FileManager.default.fileExists(atPath: outside), "a link is never followed out of the store")
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: dir + "/art_link.png")) != nil)
    #expect(FileManager.default.fileExists(atPath: dir + "/art_dir.png"))
    #expect(FileManager.default.fileExists(atPath: dir + "/notes.txt"))
}

// The Runtime keeps an observation's screenshot and a live Run's artifacts;
// once the service is gone, a late sweep removes nothing it cannot check.
@Test func theRuntimeTellsTheSweepWhatItStillUses() throws {
    let dir = NSTemporaryDirectory() + "adt-art-\(UUID().uuidString.prefix(8))"
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let store = try ArtifactStore(directory: dir)
    var s: RuntimeService? = RuntimeService(identity: RuntimeIdentity(instanceId: "rt_test", pid: getpid(), startedAt: Timestamp.string(Date()),
                                                                      endpoint: "/tmp/t.sock", buildSource: "unknown"),
                                            backend: FixedBackend(), platform: FakePlatform(), artifacts: store)
    s!.bindsOnlyLaunchedProcesses = false
    let c = handshaken(s!)
    let d = try created(s!, c)
    _ = call(s!, c, "window.bind", params: #"{"desktopId":"\#(d)","pid":101}"#)
    let sid = try #require(data(call(s!, c, "session.open", params: #"{"desktopId":"\#(d)"}"#))?["sessionId"]?.stringValue)
    let snap = try #require(data(call(s!, c, "observe", context: #"{"sessionId":"\#(sid)"}"#))?["snapshotId"]?.stringValue)
    let art = "art_" + snap.dropFirst(4)
    #expect(store.retained(String(art), nil))
    let owner = handshaken(s!)
    let runId = try #require(data(call(s!, owner, "run.start", context: #"{"sessionId":"\#(sid)"}"#))?["run"]?["runId"]?.stringValue)
    #expect(store.retained("art_unknown", runId))
    _ = call(s!, owner, "run.finish", params: #"{"runId":"\#(runId)"}"#)
    _ = call(s!, owner, "run.wait", params: #"{"runId":"\#(runId)","timeoutMs":2000}"#)
    #expect(!store.retained("art_unknown", runId), "an ended Run's artifacts may expire")
    #expect(!store.retained("art_unknown", "run_never_existed"), "a runId the Runtime does not know keeps nothing")
    #expect(!store.retained("art_unknown", nil))
    s = nil
    #expect(store.retained("art_unknown", nil), "with the Runtime gone, keep everything")
}

// A whole-screen capture left behind by a crash mid-crop goes with its
// artifact's age, like the artifact's own files.
@Test func aCropLeftoverFromACrashIsSweptToo() throws {
    let dir = NSTemporaryDirectory() + "adt-art-\(UUID().uuidString.prefix(8))"
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let clock = SweepClock()
    let store = try ArtifactStore(directory: dir, now: { clock.now })
    let leftover = store.path(for: "art_crash", ext: "png") + ".screen.png"
    try Data([1, 2, 3]).write(to: URL(fileURLWithPath: leftover))
    try FileManager.default.setAttributes([.modificationDate: clock.now.addingTimeInterval(-30 * 3600)], ofItemAtPath: leftover)
    #expect(ArtifactStore.artifactId(ofFile: "art_crash.png.screen.png") == "art_crash")
    #expect(ArtifactStore.artifactId(ofFile: "notes.screen.png") == nil)
    clock.now = clock.now.addingTimeInterval(ArtifactStore.sweepInterval)
    try Data([0x89, 0x50, 0x4e, 0x47]).write(to: URL(fileURLWithPath: store.path(for: "art_t", ext: "png")))
    try store.register("art_t", mediaType: "image/png", clientId: "owner", runId: nil, createdAt: Timestamp.string(clock.now))
    store.waitForSweeps()
    #expect(!FileManager.default.fileExists(atPath: leftover))
}

// Hard limits (Kevin, #144 review): checked before a screenshot is taken,
// refused with limit_exceeded, never by deleting what a live Run uses.

private func quotaScene(_ configure: (ArtifactStore) -> Void) throws -> (RuntimeService, ConnectionState, String, ArtifactStore, String) {
    let dir = NSTemporaryDirectory() + "adt-art-\(UUID().uuidString.prefix(8))"
    let store = try ArtifactStore(directory: dir)
    configure(store)
    let s = RuntimeService(identity: RuntimeIdentity(instanceId: "rt_test", pid: getpid(), startedAt: Timestamp.string(Date()),
                                                     endpoint: "/tmp/t.sock", buildSource: "unknown"),
                           backend: FixedBackend(), platform: FakePlatform(), artifacts: store)
    s.bindsOnlyLaunchedProcesses = false
    let c = handshaken(s)
    let d = try created(s, c)
    _ = call(s, c, "window.bind", params: #"{"desktopId":"\#(d)","pid":101}"#)
    let sid = try #require(data(call(s, c, "session.open", params: #"{"desktopId":"\#(d)"}"#))?["sessionId"]?.stringValue)
    return (s, c, sid, store, dir)
}

@Test func aRunThatKeepsObservingStopsGettingScreenshotsAtItsLimit() throws {
    let (s, c, sid, store, dir) = try quotaScene { $0.limits.perRunArtifacts = 2 }
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let runId = try #require(data(call(s, c, "run.start", context: #"{"sessionId":"\#(sid)"}"#))?["run"]?["runId"]?.stringValue)
    let inRun = #"{"sessionId":"\#(sid)","runId":"\#(runId)"}"#
    #expect(data(call(s, c, "observe", context: inRun)) != nil)
    #expect(data(call(s, c, "observe", context: inRun)) != nil)
    let third = call(s, c, "observe", context: inRun)
    #expect(code(third) == "limit_exceeded")
    #expect(failure(third)?.details?["reason"]?.stringValue == "run_artifact_quota")
    // What the Run still needs is kept; it can go on without screenshots.
    #expect(data(call(s, c, "observe", params: #"{"screenshot":false}"#, context: inRun)) != nil)
    #expect((try FileManager.default.contentsOfDirectory(atPath: dir)).filter { $0.hasSuffix(".png") }.count == 2)
    // Another caller outside that Run is not held to its limit.
    #expect(data(call(s, c, "observe", context: #"{"sessionId":"\#(sid)"}"#)) != nil)
    _ = store
}

@Test func theStoreAsAWholeAndTheDiskHaveLimitsToo() throws {
    let (s, c, sid, store, dir) = try quotaScene { $0.limits.totalBytes = 1 }
    defer { try? FileManager.default.removeItem(atPath: dir) }
    #expect(data(call(s, c, "observe", context: #"{"sessionId":"\#(sid)"}"#)) != nil, "the first fits under an empty store")
    let full = call(s, c, "observe", context: #"{"sessionId":"\#(sid)"}"#)
    #expect(code(full) == "limit_exceeded" && failure(full)?.details?["reason"]?.stringValue == "artifact_store_full")
    store.limits = ArtifactStore.Limits()
    store.freeBytes = { 100 }
    store.refreshFreeSpace()
    let low = call(s, c, "observe", context: #"{"sessionId":"\#(sid)"}"#)
    #expect(code(low) == "limit_exceeded" && failure(low)?.details?["reason"]?.stringValue == "disk_low")
    // A volume that cannot say how much is free is not trusted either.
    store.freeBytes = { nil }
    store.refreshFreeSpace()
    let unknown = call(s, c, "observe", context: #"{"sessionId":"\#(sid)"}"#)
    #expect(code(unknown) == "limit_exceeded" && failure(unknown)?.details?["reason"]?.stringValue == "disk_unknown")
    store.freeBytes = { 100 << 30 }
    store.refreshFreeSpace()
    #expect(data(call(s, c, "observe", context: #"{"sessionId":"\#(sid)"}"#)) != nil)
}

@Test func usageSurvivesARestartAndExpiryFreesIt() throws {
    let dir = NSTemporaryDirectory() + "adt-art-\(UUID().uuidString.prefix(8))"
    defer { try? FileManager.default.removeItem(atPath: dir) }
    final class Clock: @unchecked Sendable { var now = Date() }
    let clock = Clock()
    let first = try ArtifactStore(directory: dir, now: { clock.now })
    for id in ["art_a", "art_b"] {
        try Data(repeating: 1, count: 100).write(to: URL(fileURLWithPath: first.path(for: id, ext: "png")))
        try first.admit(bucket: "run:run_x")
        try first.register(id, mediaType: "image/png", clientId: "owner", runId: "run_x", createdAt: Timestamp.string(clock.now),
                           bucket: "run:run_x")
    }
    // A new Runtime over the same store counts what is there.
    let again = try ArtifactStore(directory: dir, now: { clock.now })
    again.limits.perRunArtifacts = 2
    #expect(throws: RuntimeError.self) { try again.admit(bucket: "run:run_x") }
    // Once they expire (run_x is not live) the sweep frees the quota.
    for id in ["art_a", "art_b"] {
        for p in [again.path(for: id, ext: "png"), again.metaPath(id)] {
            try FileManager.default.setAttributes([.modificationDate: clock.now.addingTimeInterval(-30 * 3600)], ofItemAtPath: p)
        }
    }
    again.sweep(at: clock.now)
    try again.admit(bucket: "run:run_x")
}

// b9's review: a runId must be one's own Run; a made-up one gets no fresh
// quota and another caller's cannot be spent.
@Test func aRunIdThatIsNotTheCallersOwnIsRefused() throws {
    let (s, c, sid, _, dir) = try quotaScene { _ in }
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let madeUp = call(s, c, "observe", context: #"{"sessionId":"\#(sid)","runId":"run_madeup"}"#)
    #expect(code(madeUp) == "permission_denied")
    let other = handshaken(s)
    let theirs = try #require(data(call(s, other, "run.start", context: #"{"sessionId":"\#(sid)"}"#))?["run"]?["runId"]?.stringValue)
    #expect(code(call(s, c, "observe", context: #"{"sessionId":"\#(sid)","runId":"\#(theirs)"}"#)) == "permission_denied")
    #expect((try FileManager.default.contentsOfDirectory(atPath: dir)).filter { $0.hasSuffix(".png") }.isEmpty)
}

// b9's review B1/S1: a GUI Run's window capture and its model copy count
// against the Run's own session, and a refusal reaches the GUI as LIMIT_EXCEEDED.
@Test func aGuiRunIsHeldToItsLimitAndHearsWhy() async throws {
    let (platform, s, ports, d) = try guiScene()
    s.artifacts.limits.perRunArtifacts = 3
    _ = try await ports.authorize(sessionId: nil, desktopId: d, callerScope: "u", trustedOwner: true, runId: "r1")
    _ = try await ports.observe(runId: "r1", expectedGeneration: 1)  // window capture + model copy: 2 of 3
    do {
        // Both of a step's screenshots must fit: refused before the window capture.
        _ = try await ports.observe(runId: "r1", expectedGeneration: 1)
        Issue.record("the GUI run went past its limit")
    } catch let e as ContractError {
        #expect(e.code == .limitExceeded)
        #expect(!e.message.contains("gui:") && !e.message.contains("session:"), "no bucket names in messages")
    }
    let files = try FileManager.default.contentsOfDirectory(atPath: s.artifacts.directory).filter { $0.hasSuffix(".png") }
    #expect(files.filter { $0.hasPrefix("art_gui_") }.count == 1, "\(files)")
    #expect(files.filter { !$0.hasPrefix("art_gui_") }.count == 1, "no extra window capture at the limit: \(files)")
    _ = platform
}

// A GUI Run counts against itself, not the session it was given: a caller
// running several in one session is not refused because of earlier ones.
@Test func eachGuiRunHasItsOwnQuota() async throws {
    let (_, s, ports, d) = try guiScene()
    s.artifacts.limits.perRunArtifacts = 2
    let first = try await ports.authorize(sessionId: nil, desktopId: d, callerScope: "u", trustedOwner: true, runId: "r1")
    _ = try await ports.observe(runId: "r1", expectedGeneration: 1)
    _ = try await ports.authorize(sessionId: first.sessionId, desktopId: d, callerScope: "u", trustedOwner: true, runId: "r2")
    _ = try await ports.observe(runId: "r2", expectedGeneration: 1)
}

// A free-space answer that is too old, or a query that hangs, refuses.
@Test func aStaleOrHungFreeSpaceAnswerRefuses() throws {
    let dir = NSTemporaryDirectory() + "adt-art-\(UUID().uuidString.prefix(8))"
    defer { try? FileManager.default.removeItem(atPath: dir) }
    final class Clock: @unchecked Sendable { var now = Date() }
    let clock = Clock()
    let store = try ArtifactStore(directory: dir, now: { clock.now })
    store.freeBytes = { 100 << 30 }
    store.refreshFreeSpace()
    try store.admit(bucket: "session:s")
    store.release(bucket: "session:s")
    // The volume stops answering: the old answer ages out.
    let gate = DispatchSemaphore(value: 0)
    store.freeBytes = { gate.wait(); return 100 << 30 }
    clock.now = clock.now.addingTimeInterval(61)
    #expect(throws: RuntimeError.self) { try store.admit(bucket: "session:s") }
    gate.signal(); gate.signal()
}

// b9's review of 9a7657a: a volume that hangs every query does not pile up
// queries (one retry each 30 s), and a clock set back does not keep an old
// answer fresh.
@Test func hungQueriesAreCappedAndABackwardsClockIsStale() throws {
    let dir = NSTemporaryDirectory() + "adt-art-\(UUID().uuidString.prefix(8))"
    defer { try? FileManager.default.removeItem(atPath: dir) }
    final class Clock: @unchecked Sendable { var now = Date() }
    final class Calls: @unchecked Sendable { let lock = NSLock(); var n = 0 }
    let clock = Clock(), calls = Calls()
    let store = try ArtifactStore(directory: dir, now: { clock.now })
    store.freeBytes = { 100 << 30 }
    store.refreshFreeSpace()
    // Set back an hour: the answer is not taken as fresh.
    clock.now = clock.now.addingTimeInterval(-3600)
    let gate = DispatchSemaphore(value: 0)
    store.freeBytes = { calls.lock.withLock { calls.n += 1 }; gate.wait(); return 100 << 30 }
    #expect(throws: RuntimeError.self) { try store.admit(bucket: "session:s") }
    for _ in 0..<10 {
        clock.now = clock.now.addingTimeInterval(31)
        _ = try? store.admit(bucket: "session:s")
    }
    let until = Date().addingTimeInterval(10)
    while calls.lock.withLock({ calls.n }) < ArtifactStore.maxFreeQueries && Date() < until { Thread.sleep(forTimeInterval: 0.02) }
    Thread.sleep(forTimeInterval: 0.2)
    #expect(calls.lock.withLock { calls.n } == ArtifactStore.maxFreeQueries)
    for _ in 0..<ArtifactStore.maxFreeQueries { gate.signal() }
}

// b9's review of 3b8cbc4: after the clock is set back, a new answer still
// counts, so screenshots resume at once instead of when the clock catches up.
@Test func screenshotsResumeRightAfterTheClockIsSetBack() throws {
    let dir = NSTemporaryDirectory() + "adt-art-\(UUID().uuidString.prefix(8))"
    defer { try? FileManager.default.removeItem(atPath: dir) }
    final class Clock: @unchecked Sendable { var now = Date() }
    let clock = Clock()
    let store = try ArtifactStore(directory: dir, now: { clock.now })
    store.freeBytes = { 100 << 30 }
    store.refreshFreeSpace()
    clock.now = clock.now.addingTimeInterval(-3600)
    #expect(throws: RuntimeError.self) { try store.admit(bucket: "session:s") }
    store.refreshFreeSpace()
    try store.admit(bucket: "session:s")
}

// A sweep that cannot remove a file does not take it off the usage.
@Test func aFileTheSweepCannotRemoveStillCounts() throws {
    let dir = NSTemporaryDirectory() + "adt-art-\(UUID().uuidString.prefix(8))"
    defer { chmod(dir, 0o700); try? FileManager.default.removeItem(atPath: dir) }
    let store = try ArtifactStore(directory: dir)
    store.freeBytes = { 100 << 30 }
    store.refreshFreeSpace()
    try Data(repeating: 1, count: 100).write(to: URL(fileURLWithPath: store.path(for: "art_a", ext: "png")))
    try store.admit(bucket: "session:s")
    _ = try store.register("art_a", mediaType: "image/png", clientId: "c", runId: nil, createdAt: Timestamp.string(Date()),
                           bucket: "session:s")
    for p in [store.path(for: "art_a", ext: "png"), store.metaPath("art_a")] {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-30 * 3600)], ofItemAtPath: p)
    }
    chmod(dir, 0o500)
    store.sweep(at: Date())
    chmod(dir, 0o700)
    #expect(FileManager.default.fileExists(atPath: store.path(for: "art_a", ext: "png")))
    #expect(store.count(bucket: "session:s") == 1)
}

// A failed capture leaves no half-written image behind.
@Test func aFailedCaptureLeavesNoFile() async throws {
    let (platform, s, ports, d) = try guiScene()
    _ = try await ports.authorize(sessionId: nil, desktopId: d, callerScope: "u", trustedOwner: true, runId: "r1")
    platform.failScreenshot = true
    await #expect(throws: (any Error).self) { _ = try await ports.observe(runId: "r1", expectedGeneration: 1) }
    let files = try FileManager.default.contentsOfDirectory(atPath: s.artifacts.directory).filter { $0.hasSuffix(".png") }
    #expect(files.isEmpty, "\(files)")
    // A GUI step's window capture is recorded under its Run.
    platform.failScreenshot = false
    _ = try await ports.observe(runId: "r1", expectedGeneration: 1)
    let metas = try FileManager.default.contentsOfDirectory(atPath: s.artifacts.directory).filter { $0.hasSuffix(".meta.json") }
    #expect(metas.count == 2)
    for m in metas {
        let v = try StrictJSON.parse(try Data(contentsOf: URL(fileURLWithPath: s.artifacts.directory + "/" + m)))
        #expect(v["runId"]?.stringValue == "r1", "\(m)")
    }
}

// b9 (#144, fourth review): a GUI step's places are admitted together with
// every limit, so no window capture is written when the store, the disk or
// an unknown answer would refuse the model's copy; unused places come back.
@Test(arguments: ["store", "disk", "unknown"])
func aGuiStepIsRefusedWholeByAnyLimit(_ which: String) async throws {
    let (_, s, ports, d) = try guiScene()
    _ = try await ports.authorize(sessionId: nil, desktopId: d, callerScope: "u", trustedOwner: true, runId: "r1")
    switch which {
    case "store": s.artifacts.limits.totalBytes = 0
    case "disk": s.artifacts.freeBytes = { 100 }; s.artifacts.refreshFreeSpace()
    default: s.artifacts.freeBytes = { nil }; s.artifacts.refreshFreeSpace()
    }
    await #expect(throws: ContractError.self) { _ = try await ports.observe(runId: "r1", expectedGeneration: 1) }
    let pngs = try FileManager.default.contentsOfDirectory(atPath: s.artifacts.directory).filter { $0.hasSuffix(".png") }
    #expect(pngs.isEmpty, "\(pngs)")
}

@Test func aFailedGuiStepGivesItsPlacesBack() async throws {
    let (platform, s, ports, d) = try guiScene()
    s.artifacts.limits.perRunArtifacts = 2
    _ = try await ports.authorize(sessionId: nil, desktopId: d, callerScope: "u", trustedOwner: true, runId: "r1")
    platform.failScreenshot = true
    await #expect(throws: (any Error).self) { _ = try await ports.observe(runId: "r1", expectedGeneration: 1) }
    platform.failScreenshot = false
    // Both places came back: the next step fits whole.
    #expect(s.artifacts.count(bucket: "gui:r1") == 0)
    _ = try await ports.observe(runId: "r1", expectedGeneration: 1)
    #expect(s.artifacts.count(bucket: "gui:r1") == 2)
    #expect(s.quotaBuckets.isEmpty && s.quotaBucketsUsed.isEmpty, "no per-request bucket left behind")
}

// b9's review of 9a7657a: the window capture was stored, then the observe
// failed (the window changed during the capture). The stored file keeps its
// place; only the model copy's place goes back.
@Test func aStoredCaptureKeepsItsPlaceWhenTheStepFailsAfterIt() async throws {
    let (platform, s, ports, d) = try guiScene()
    let screen = try #require(s.desktops.find(d)?.screen)
    _ = try await ports.authorize(sessionId: nil, desktopId: d, callerScope: "u", trustedOwner: true, runId: "r1")
    platform.onCapture = {
        platform.inFront[screen.name] = [PlatformWindow(windowId: 77, pid: 555, appName: "Notes", title: "盖住", frame: screen.frame)]
    }
    let before = platform.calls.filter { $0.contains("creenshot") || $0.hasSuffix("window") }.count
    await #expect(throws: (any Error).self) { _ = try await ports.observe(runId: "r1", expectedGeneration: 1) }
    let shots = platform.calls.filter { $0.contains("creenshot") || $0.hasSuffix("window") }.count - before
    let pngs = try FileManager.default.contentsOfDirectory(atPath: s.artifacts.directory).filter { $0.hasSuffix(".png") }
    #expect(shots == 1)
    #expect(pngs.count == 1, "\(pngs)")
    #expect(s.artifacts.count(bucket: "gui:r1") == pngs.count, "the count matches what is stored")
    #expect(s.quotaBuckets.isEmpty && s.quotaBucketsUsed.isEmpty, "no per-request state left behind")
}

@Test func aLateAnswerFromAHungQueryIsNotTakenForANewOne() throws {
    let dir = NSTemporaryDirectory() + "adt-art-\(UUID().uuidString.prefix(8))"
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let store = try ArtifactStore(directory: dir)
    // The first query hangs and will answer 1 byte; a later one answers
    // plenty first. The late answer, to the older question, is dropped.
    let late = DispatchQueue(label: "late")
    let asked = DispatchSemaphore(value: 0), answer = DispatchSemaphore(value: 0)
    store.freeBytes = { asked.signal(); answer.wait(); return 1 }
    late.async { store.refreshFreeSpace() }
    asked.wait()
    store.freeBytes = { 100 << 30 }
    store.refreshFreeSpace()
    answer.signal()
    late.sync {}
    try store.admit(bucket: "session:s")
}

// A Runtime without storage keeps its artifacts in a scratch directory that
// goes with it: test runs left tens of thousands behind in the temp folder.
@Test func aScratchArtifactDirectoryGoesWithItsRuntime() throws {
    var dir = ""
    do {
        let s = makeService()
        dir = s.artifacts.directory
        #expect(FileManager.default.fileExists(atPath: dir))
    }
    #expect(!FileManager.default.fileExists(atPath: dir))
}
