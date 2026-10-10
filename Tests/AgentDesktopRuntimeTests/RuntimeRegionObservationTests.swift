import AgentDesktopProtocol
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AgentDesktopRuntime

@Test func regionObservationHasCorrectTransformAndOnlyOneArtifact() throws {
    let sc = try scene()
    sc.platform.realImages = true
    let r = call(sc.s, sc.c, "observe.region", params: #"{"region":{"x":2100,"y":150,"width":100,"height":50},"maxWidth":100,"elements":false}"#,
                 context: #"{"sessionId":"\#(sc.session)"}"#)
    let o = try #require(data(r))
    #expect(o["image"]?["width"]?.intValue == 100)
    #expect(o["image"]?["height"]?.intValue == 50)
    #expect(o["image"]?["transform"]?["originX"]?.doubleValue == 2100)
    #expect(o["image"]?["transform"]?["originY"]?.doubleValue == 150)
    #expect(o["image"]?["transform"]?["scale"]?.doubleValue == 1)
    let id = try #require(o["snapshotId"]?.stringValue)
    let stored = try #require(sc.s.observations.find(id))
    #expect(stored.transform?.originX == 2100 && stored.transform?.scale == 1)
    #expect(stored.imageSize?.width == 100)
    let click = call(sc.s, sc.c, "act", params: "{\"snapshotId\":\"\(id)\",\"action\":{\"kind\":\"click\",\"target\":{\"imagePoint\":{\"x\":20,\"y\":10}}}}",
                     context: #"{"sessionId":"\#(sc.session)"}"#)
    #expect(data(click) != nil)
    #expect(sc.platform.performed.last?.point?.x == 2120)
    #expect(sc.platform.performed.last?.point?.y == 160)
    let imageId = try #require(o["image"]?["artifactId"]?.stringValue)
    let file = try #require(sc.s.artifacts.file(of: imageId))
    let source = try #require(CGImageSourceCreateWithURL(URL(fileURLWithPath: file) as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(image.width == 100 && image.height == 50)
}

@Test func outsideRegionIsRefusedAndImageIsRemoved() throws {
    let sc = try scene()
    sc.platform.realImages = true
    let r = call(sc.s, sc.c, "observe.region", params: #"{"region":{"x":0,"y":0,"width":100,"height":100},"elements":false}"#,
                 context: #"{"sessionId":"\#(sc.session)"}"#)
    #expect(code(r) == "invalid_argument")
    if let path = sc.platform.lastScreenshot { #expect(!FileManager.default.fileExists(atPath: path)) }
    #expect(sc.platform.performed.isEmpty)
}

@Test func croppingPreservesTopLeftPixelOrientation() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("region-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("source.png")
    var pixels = [UInt8]()
    for y in 0..<4 { for x in 0..<4 { pixels += [UInt8(x*50), UInt8(y*50), 0, 255] } }
    let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
    let image = try #require(CGImage(width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16,
                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let dest = try #require(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(dest, image, nil)
    try #require(CGImageDestinationFinalize(dest))
    let result = try RegionObservationImage.convert(path: file.path, size: (4,4), origin: (0,0), scale: 1,
        params: .obj([("region", .obj([("x",.int(1)),("y",.int(1)),("width",.int(2)),("height",.int(2))]))]))
    #expect(result.size.width == 2 && result.size.height == 2)
    let source = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
    let cropped = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let raw = try #require(cropped.dataProvider?.data) as Data
    #expect(raw[0] == 50 && raw[1] == 50)
    #expect(raw[cropped.bytesPerRow] == 50 && raw[cropped.bytesPerRow+1] == 100)
}

@Test func regionExtensionIsVersionedAndLegacyObserveRejectsItsParams() throws {
    let sc = try scene()
    let caps = try #require(data(call(sc.s, sc.c, "runtime.capabilities")))
    #expect(caps["regionObservation"]?["version"]?.intValue == 1)
    #expect(caps["regionObservation"]?["method"]?.stringValue == "observe.region")
    let r = call(sc.s, sc.c, "observe", params: #"{"maxWidth":100}"#,
                 context: #"{"sessionId":"\#(sc.session)"}"#)
    #expect(code(r) == "schema_invalid")
}

@Test func regionObservationRespectsTargetExposure() throws {
    let sc = try scene()
    sc.platform.realImages = true
    sc.platform.inFront[sc.s.desktops.find(sc.desktop)!.screen.name] = [coveringWindow]
    let r = call(sc.s, sc.c, "observe.region", params: #"{"maxWidth":100,"elements":false}"#,
                 context: #"{"sessionId":"\#(sc.session)"}"#)
    #expect(code(r) == "stale_observation")
    #expect(sc.platform.performed.isEmpty)
}

@Test func widthOnlyRegionObservationKeepsTheWindowOrigin() throws {
    let sc = try scene()
    sc.platform.realImages = true
    let r = call(sc.s, sc.c, "observe.region", params: #"{"maxWidth":200,"elements":false}"#,
                 context: #"{"sessionId":"\#(sc.session)"}"#)
    let o = try #require(data(r))
    #expect(o["image"]?["width"]?.intValue == 200)
    #expect(o["image"]?["transform"]?["originX"] == o["target"]?["windowFrame"]?["x"])
    #expect(o["image"]?["transform"]?["originY"] == o["target"]?["windowFrame"]?["y"])
}
