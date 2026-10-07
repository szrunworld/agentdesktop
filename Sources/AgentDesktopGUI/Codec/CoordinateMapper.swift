import AgentDesktopContracts
import Foundation

/// Spec §08: model coordinates → model canvas pixels → source screenshot
/// pixels → Desktop logical points. Every step checks its domain
/// `[0,width) × [0,height)`; nothing is ever clamped.
public enum CoordinateMapper {
    static func outOfBounds(_ what: String, _ p: Point) -> ContractError {
        ContractError(.coordinateOutOfBounds, "\(what) \(p) is outside its domain")
    }

    /// A model-written coordinate on the model input canvas, by the profile's
    /// explicit protocol. `normalized_1000` covers 0..<1000; 1000 itself
    /// would land on the canvas edge and is refused.
    public static func modelCanvasPoint(_ raw: Point, protocol proto: CoordinateProtocol,
                                        canvas: Size) throws -> Point {
        guard raw.isFinite else { throw ContractError(.coordinateOutOfBounds, "coordinate is not finite") }
        switch proto {
        case .normalized1000:
            guard (0..<1000).contains(raw.x), (0..<1000).contains(raw.y) else {
                throw outOfBounds("normalized coordinate", raw)
            }
            let p = Point(x: raw.x / 1000 * canvas.width, y: raw.y / 1000 * canvas.height)
            try checkDomain(p, Size(width: canvas.width, height: canvas.height), "model canvas point")
            return p
        case .imagePixels:
            try checkDomain(raw, canvas, "model canvas point")
            return raw
        }
    }

    /// Parse a protocol name strictly: missing or unknown is VALIDATION_ERROR.
    public static func coordinateProtocol(_ name: String?) throws -> CoordinateProtocol {
        guard let name, let p = CoordinateProtocol(rawValue: name) else {
            throw ContractError(.validationError, "coordinateProtocol must be normalized_1000 or image_pixels")
        }
        return p
    }

    public static func checkDomain(_ p: Point, _ size: Size, _ what: String) throws {
        guard p.isFinite, p.x >= 0, p.y >= 0, p.x < size.width, p.y < size.height else {
            throw outOfBounds(what, p)
        }
    }

    /// A model canvas point to source screenshot pixels. Points in the
    /// letterbox padding, and points that map outside the source, are refused.
    public static func sourcePixel(fromModelCanvas p: Point, transform t: ScreenshotTransform) throws -> Point {
        try checkDomain(p, t.modelInputSize, "model canvas point")
        let content = t.contentRegion
        guard p.x >= content.origin.x, p.y >= content.origin.y,
              p.x < content.origin.x + content.size.width, p.y < content.origin.y + content.size.height else {
            throw outOfBounds("letterbox point", p)
        }
        let s = t.modelToSource.apply(p)
        try checkDomain(s, t.sourceSize, "source pixel")
        return s
    }

    /// The whole model-side chain for one coordinate the model wrote.
    public static func sourcePixel(fromModel raw: Point, protocol proto: CoordinateProtocol,
                                   transform t: ScreenshotTransform) throws -> Point {
        let canvas = try modelCanvasPoint(raw, protocol: proto, canvas: t.modelInputSize)
        return try sourcePixel(fromModelCanvas: canvas, transform: t)
    }

    /// Source screenshot pixels to Desktop logical points. The source point
    /// must lie in the source; the result may be negative (a display left of
    /// or above the main one) and is not rescaled again.
    public static func desktopPoint(fromSource p: Point, sourceSize: Size,
                                    sourceToDesktop: GuiAffineTransform) throws -> Point {
        try checkDomain(p, sourceSize, "source pixel")
        _ = try sourceToDesktop.inverted()
        let d = sourceToDesktop.apply(p)
        guard d.isFinite else { throw outOfBounds("desktop point", d) }
        return d
    }

    public static func desktopPoint(fromSource p: Point, screenshot: ScreenshotDescriptor) throws -> Point {
        try desktopPoint(fromSource: p, sourceSize: screenshot.transform.sourceSize,
                         sourceToDesktop: screenshot.sourceToDesktop)
    }
}
