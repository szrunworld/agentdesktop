import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopGUI

// COO-001..008 (docs/ai-gui/tests/cases.csv): pure-math goldens. The
// transforms below are the cases' preconditions verbatim.

let tolerance = 1e-6

func near(_ p: Point, _ x: Double, _ y: Double, _ tol: Double = tolerance) -> Bool {
    abs(p.x - x) <= tol && abs(p.y - y) <= tol
}

func code(_ body: () throws -> Void) -> ErrorCode? {
    do { try body(); return nil } catch let e as ContractError { return e.code } catch { return .internalError }
}

func affine(_ v: [Double]) -> GuiAffineTransform {
    GuiAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
}

@Suite("Coordinates")
struct CoordinateTests {
    @Test func coo001NormalizedOnAnIdentityCanvas() throws {
        let t = try ScreenshotTransform.pipeline(sourceSize: Size(width: 1600, height: 1000))
        #expect(t.modelToSource.isClose(to: .identity))
        let s = try CoordinateMapper.sourcePixel(fromModel: Point(x: 625, y: 400), protocol: .normalized1000, transform: t)
        #expect(near(s, 1000, 400), "\(s)")
    }

    @Test func coo002RetinaSourceToNegativeDesktopOrigin() throws {
        let toDesktop = affine([0.5, 0, 0, 0.5, -1440, 120])
        let d = try CoordinateMapper.desktopPoint(fromSource: Point(x: 1440, y: 900),
                                                  sourceSize: Size(width: 2880, height: 1800), sourceToDesktop: toDesktop)
        #expect(near(d, -720, 570), "\(d)")
    }

    @Test func coo003CropAndResize() throws {
        let t = try ScreenshotTransform.pipeline(sourceSize: Size(width: 1600, height: 1000),
                                                 crop: GuiRect(x: 200, y: 100, width: 1000, height: 600),
                                                 resizedSize: Size(width: 500, height: 300))
        #expect(t.modelToSource.isClose(to: affine([2, 0, 0, 2, 200, 100])), "\(t.modelToSource)")
        let s = try CoordinateMapper.sourcePixel(fromModel: Point(x: 250, y: 150), protocol: .imagePixels, transform: t)
        #expect(near(s, 700, 400), "\(s)")
        // Model pixels are not source pixels.
        #expect(!near(s, 250, 150))
    }

    @Test func coo004LetterboxPaddingAndEdge() throws {
        let t = try ScreenshotTransform.pipeline(sourceSize: Size(width: 1600, height: 900),
                                                 resizedSize: Size(width: 800, height: 450),
                                                 letterbox: Insets(left: 0, top: 175, right: 0, bottom: 175))
        #expect(t.modelInputSize == Size(width: 800, height: 800))
        #expect(t.modelToSource.isClose(to: affine([2, 0, 0, 2, 0, -350])), "\(t.modelToSource)")
        let center = try CoordinateMapper.sourcePixel(fromModel: Point(x: 400, y: 400), protocol: .imagePixels, transform: t)
        #expect(near(center, 800, 450))
        // The padding point maps to y=-150 and the bottom edge to y=900: both refused, never clamped.
        #expect(near(t.modelToSource.apply(Point(x: 400, y: 100)), 800, -150))
        #expect(code { _ = try CoordinateMapper.sourcePixel(fromModel: Point(x: 400, y: 100), protocol: .imagePixels, transform: t) } == .coordinateOutOfBounds)
        #expect(near(t.modelToSource.apply(Point(x: 400, y: 625)), 800, 900))
        #expect(code { _ = try CoordinateMapper.sourcePixel(fromModel: Point(x: 400, y: 625), protocol: .imagePixels, transform: t) } == .coordinateOutOfBounds)
    }

    @Test func coo005FullChainEqualsExplicitAffine() throws {
        let t = try ScreenshotTransform.pipeline(sourceSize: Size(width: 2400, height: 1600),
                                                 crop: GuiRect(x: 200, y: 300, width: 1200, height: 800),
                                                 resizedSize: Size(width: 600, height: 400),
                                                 letterbox: Insets(left: 20, top: 40, right: 20, bottom: 40))
        #expect(t.modelInputSize == Size(width: 640, height: 480))
        let explicit = affine([2, 0, 0, 2, 160, 220])
        #expect(t.modelToSource.isClose(to: explicit), "\(t.modelToSource)")
        let canvas = try CoordinateMapper.modelCanvasPoint(Point(x: 500, y: 500), protocol: .normalized1000, canvas: t.modelInputSize)
        #expect(near(canvas, 320, 240))
        let s = try CoordinateMapper.sourcePixel(fromModel: Point(x: 500, y: 500), protocol: .normalized1000, transform: t)
        #expect(near(s, 800, 700), "\(s)")
        #expect(near(explicit.apply(canvas), s.x, s.y))
    }

    @Test func coo006SourceDomainWithoutClamping() throws {
        let size = Size(width: 1600, height: 1000)
        let valid = [Point(x: 0, y: 0), Point(x: 1599.999999, y: 999.999999)]
        let invalid = [Point(x: 1600, y: 0), Point(x: -0.000001, y: 1), Point(x: .nan, y: 1),
                       Point(x: 1, y: .infinity), Point(x: -.infinity, y: 0)]
        var ok = 0
        for p in valid where code({ try CoordinateMapper.checkDomain(p, size, "source") }) == nil { ok += 1 }
        #expect(ok == 2)
        for p in invalid {
            #expect(code { try CoordinateMapper.checkDomain(p, size, "source") } == .coordinateOutOfBounds, "\(p)")
        }
        // normalized 1000 would map to the width itself: refused, not turned into width-1.
        let t = try ScreenshotTransform.pipeline(sourceSize: size)
        #expect(code { _ = try CoordinateMapper.sourcePixel(fromModel: Point(x: 1000, y: 10), protocol: .normalized1000, transform: t) } == .coordinateOutOfBounds)
        #expect(code { _ = try CoordinateMapper.sourcePixel(fromModel: Point(x: .nan, y: 10), protocol: .imagePixels, transform: t) } == .coordinateOutOfBounds)
    }

    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    @Test func coo007CompositionInverseAndSingular() throws {
        var rng = SplitMix(state: 20261008)
        // Non-diagonal so a b/c swap would show.
        let t1 = affine([1.2, 0.3, -0.4, 0.9, 15, -7])
        let t2 = affine([0.5, -0.2, 0.1, 1.5, -300, 42])
        let composed = t1.then(t2)
        let inv = try composed.inverted()
        var worst = 0.0
        for _ in 0..<100 {
            let p = Point(x: Double.random(in: 0..<2560, using: &rng), y: Double.random(in: 0..<1600, using: &rng))
            let step = t2.apply(t1.apply(p))
            let once = composed.apply(p)
            let back = inv.apply(once)
            worst = max(worst, abs(step.x - once.x), abs(step.y - once.y), abs(back.x - p.x), abs(back.y - p.y))
        }
        #expect(worst <= tolerance, "max error \(worst)")
        // The convention x' = a*x + c*y + tx, y' = b*x + d*y + ty, by hand.
        let q = t1.apply(Point(x: 10, y: 20))
        let ex: Double = 1.2 * 10.0 - 0.4 * 20.0 + 15.0   // a*x + c*y + tx
        let ey: Double = 0.3 * 10.0 + 0.9 * 20.0 - 7.0    // b*x + d*y + ty
        #expect(near(q, ex, ey))
        // Singular and non-finite matrices are refused.
        #expect(code { _ = try affine([1, 2, 2, 4, 0, 0]).inverted() } == .validationError)
        #expect(code { _ = try affine([0, 0, 0, 0, 1, 1]).inverted() } == .validationError)
        #expect(code { _ = try GuiAffineTransform(array: [1, 0, 0, 1, .nan, 0]) } == .validationError)
        #expect(code { _ = try GuiAffineTransform(array: [1, 0, 0, 1, 0]) } == .validationError)
        // A transform pair that are not each other's inverse is refused.
        #expect(code {
            _ = try ScreenshotTransform(sourceSize: Size(width: 100, height: 100), crop: GuiRect(x: 0, y: 0, width: 100, height: 100),
                                        resizedSize: Size(width: 100, height: 100), letterbox: .zero,
                                        modelInputSize: Size(width: 100, height: 100),
                                        sourceToModel: .identity, modelToSource: affine([2, 0, 0, 2, 0, 0]))
        } == .validationError)
    }

    @Test func coo008ProtocolIsExplicit() throws {
        let t = try ScreenshotTransform.pipeline(sourceSize: Size(width: 1600, height: 1000))
        let n = try CoordinateMapper.sourcePixel(fromModel: Point(x: 0.5, y: 0), protocol: .normalized1000, transform: t)
        let px = try CoordinateMapper.sourcePixel(fromModel: Point(x: 0.5, y: 0), protocol: .imagePixels, transform: t)
        #expect(abs(n.x - 0.8) <= tolerance)
        #expect(abs(px.x - 0.5) <= tolerance)
        // Missing or unknown protocol: VALIDATION_ERROR, no magnitude heuristic.
        #expect(code { _ = try CoordinateMapper.coordinateProtocol(nil) } == .validationError)
        #expect(code { _ = try CoordinateMapper.coordinateProtocol("auto") } == .validationError)
        #expect(code { _ = try GuiCodecRegistry().codec(adapterId: "uitars_v1", coordinateProtocol: nil) } == .validationError)
        #expect(code { _ = try GuiCodecRegistry().codec(adapterId: "uitars_v1", coordinateProtocol: "normalized_1") } == .validationError)
        // Under image_pixels a value of 0.5 stays 0.5 even though it "looks" normalized.
        let codec = UITarsCodec(coordinateProtocol: .imagePixels)
        let d = try codec.decode("Action: click(start_box='(0.5,0.5)')", context: CodecContext(transform: t, maxWaitMs: 5000))
        #expect(d.body == .action(.click(sourcePixel: Point(x: 0.5, y: 0.5))))
    }

    @Test func screenshotTransformRoundTripsThroughJSON() throws {
        let t = try ScreenshotTransform.pipeline(sourceSize: Size(width: 2400, height: 1600),
                                                 crop: GuiRect(x: 200, y: 300, width: 1200, height: 800),
                                                 resizedSize: Size(width: 600, height: 400),
                                                 letterbox: Insets(left: 20, top: 40, right: 20, bottom: 40))
        #expect(try ContractBundle.shared.validate(t.json, "ScreenshotTransform").isEmpty)
        #expect(try ScreenshotTransform(json: t.json) == t)
    }
}
