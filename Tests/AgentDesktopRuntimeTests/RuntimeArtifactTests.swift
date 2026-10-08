import AgentDesktopContracts
import CryptoKit
import Foundation
import Testing
@testable import AgentDesktopProtocol
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
