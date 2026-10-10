import AgentDesktopProtocol
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Transform a captured authorized image before it is registered or returned.
/// The original bytes are never exposed as a separate artifact.
enum RegionObservationImage {
    static func convert(path: String, size: (width: Int, height: Int), origin: (Double, Double), scale: Double,
                        params: JSONValue) throws -> (size: (width: Int, height: Int), origin: (Double, Double), scale: Double) {
        let full = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        var pixels = full
        if let region = params["region"] {
            guard let x = region["x"]?.doubleValue, let y = region["y"]?.doubleValue,
                  let w = region["width"]?.doubleValue, let h = region["height"]?.doubleValue,
                  [x,y,w,h,scale].allSatisfy({ $0.isFinite }), w > 0, h > 0, scale > 0
            else { throw RuntimeError.invalidArgument("region must be a finite positive rectangle") }
            let raw = CGRect(x: (x-origin.0)*scale, y: (y-origin.1)*scale, width: w*scale, height: h*scale)
            guard full.contains(raw) else { throw RuntimeError.invalidArgument("region lies outside the authorized image") }
            // Round inward: no pixel outside the requested region is included.
            pixels = CGRect(x: ceil(raw.minX), y: ceil(raw.minY),
                            width: floor(raw.maxX)-ceil(raw.minX), height: floor(raw.maxY)-ceil(raw.minY))
            guard pixels.width >= 1, pixels.height >= 1 else { throw RuntimeError.invalidArgument("region contains no complete pixel") }
        }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == size.width, image.height == size.height,
              let cropped = image.cropping(to: pixels)
        else { throw RuntimeError("internal_error", "cannot decode the authorized screenshot", phase: .handler) }
        let width = min(cropped.width, params["maxWidth"]?.intValue ?? cropped.width)
        guard width > 0 else { throw RuntimeError.invalidArgument("maxWidth must be positive") }
        let ratio = Double(width)/Double(cropped.width)
        let height = max(1, Int(ceil(Double(cropped.height)*ratio)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw RuntimeError("internal_error", "cannot resize the screenshot", phase: .handler) }
        context.interpolationQuality = .high
        // Top-aligned proportional drawing; any fractional bottom row is transparent.
        context.draw(cropped, in: CGRect(x: 0, y: Double(height)-Double(cropped.height)*ratio,
                                         width: Double(cropped.width)*ratio, height: Double(cropped.height)*ratio))
        guard let output = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw RuntimeError("internal_error", "cannot encode the region screenshot", phase: .handler) }
        CGImageDestinationAddImage(destination, output, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw RuntimeError("internal_error", "cannot save the region screenshot", phase: .handler)
        }
        return ((width,height), (origin.0+pixels.minX/scale, origin.1+pixels.minY/scale), scale*ratio)
    }
}
