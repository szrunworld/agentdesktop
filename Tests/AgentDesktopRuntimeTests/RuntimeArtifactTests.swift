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
    #expect(store.info("art_old") == nil, "an expired artifact is removed on a later write")
    #expect(!FileManager.default.fileExists(atPath: store.path(for: "art_old", ext: "png")))
    #expect(!FileManager.default.fileExists(atPath: store.metaPath("art_old")))
    #expect(store.info("art_mid") != nil)
    #expect(store.info("art_new") != nil)
}
