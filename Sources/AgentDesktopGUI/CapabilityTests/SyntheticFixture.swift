import AgentDesktopContracts
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Fixed, versioned test material for `ai.tests.start` (fixtureId
/// `synthetic_gui_v1`, spec §11). Images are drawn here, never captured
/// from a desktop.
public enum SyntheticGuiFixture {
    public static let fixtureId = "synthetic_gui_v1"

    /// image_input: left half red, right half blue.
    public static let colorSize = (width: 256, height: 128)
    public static let colorQuestion = "What color is the left half of this image? Answer with one lowercase English word."
    public static let colorAnswer = "red"

    /// gui_contract: one blue button on a light grey canvas.
    public static let screenSize = (width: 800, height: 500)
    public static let buttonRect = Rect(x: 520, y: 360, width: 160, height: 60)
    public static let guiTask = "Click the blue button."

    public static let authPrompt = "Reply with the single word OK."

    public static func colorImage() throws -> Data {
        try png(width: colorSize.width, height: colorSize.height) { ctx in
            ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: colorSize.width / 2, height: colorSize.height))
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: colorSize.width / 2, y: 0, width: colorSize.width / 2, height: colorSize.height))
        }
    }

    public static func screenImage() throws -> Data {
        try png(width: screenSize.width, height: screenSize.height) { ctx in
            ctx.setFillColor(CGColor(red: 0.93, green: 0.93, blue: 0.93, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: screenSize.width, height: screenSize.height))
            ctx.setFillColor(CGColor(red: 0.1, green: 0.35, blue: 0.95, alpha: 1))
            // Core Graphics puts the origin at the bottom left; the rect is
            // given in top-left image pixels.
            let r = buttonRect
            ctx.fill(CGRect(x: r.origin.x, y: Double(screenSize.height) - r.origin.y - r.size.height,
                            width: r.size.width, height: r.size.height))
        }
    }

    /// The transform for the screen image: shown to the model unchanged.
    public static func screenTransform() throws -> ScreenshotTransform {
        try ScreenshotTransform.pipeline(sourceSize: Size(width: Double(screenSize.width), height: Double(screenSize.height)))
    }

    static func png(width: Int, height: Int, draw: (CGContext) -> Void) throws -> Data {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ContractError(.internalError, "cannot draw the test image")
        }
        draw(ctx)
        guard let image = ctx.makeImage() else { throw ContractError(.internalError, "cannot draw the test image") }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            throw ContractError(.internalError, "cannot encode the test image")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ContractError(.internalError, "cannot encode the test image") }
        return out as Data
    }
}
