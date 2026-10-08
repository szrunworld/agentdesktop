import AppKit
import SwiftUI

/// Renders a view off screen to PNG at the 1440 × 1000 design base, for
/// acceptance images beside docs/design/v2/Pxx.webp (09 brief). The view
/// is hosted in a borderless window that is never ordered on screen, so
/// nothing appears on the user's display and no focus changes.
@MainActor
public enum SnapshotRenderer {
    public static func png<V: View>(_ view: V, size: CGSize = ADLayout.designSize, scale: CGFloat = 1) -> Data? {
        let rect = NSRect(origin: .zero, size: size)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .light))
        host.frame = rect
        let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        // Render in sRGB so token colours land in the PNG unchanged.
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Let SwiftUI settle state-driven layout once more.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        // Draw into an sRGB context of exactly size × scale pixels, so
        // token colours land in the PNG unchanged whatever the display.
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        host.displayIgnoringOpacity(rect, in: ns)
        window.contentView = nil
        guard let image = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = size
        return rep.representation(using: .png, properties: [:])
    }
}
