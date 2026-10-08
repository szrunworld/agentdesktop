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
    let other = handshaken(sc.s)
    other.clientId = "app:someone-else"
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
    let c = handshaken(s)
    let d = try created(s, c)
    _ = call(s, c, "window.bind", params: #"{"desktopId":"\#(d)","pid":101}"#)
    let sid = try #require(data(call(s, c, "session.open", params: #"{"desktopId":"\#(d)"}"#))?["sessionId"]?.stringValue)
    clock.now = clock.now.addingTimeInterval(ArtifactStore.sweepInterval)
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
    #expect(!store.retained("art_unknown", nil))
    s = nil
    #expect(store.retained("art_unknown", nil), "with the Runtime gone, keep everything")
}
