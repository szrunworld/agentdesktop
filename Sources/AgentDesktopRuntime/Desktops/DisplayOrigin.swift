import Foundation

/// Where a display comes from, for deciding whether a physical Desktop may
/// attach it. Only displays the hardware vouches for are trusted; anything
/// the platform cannot place is refused rather than assumed physical.
public enum DisplayOrigin: Equatable, Sendable {
    /// The built-in panel, or an external display a hardware framebuffer
    /// reports with the same vendor.
    case physical
    /// A display some process created (the engine's own, or another's).
    case virtual(String)
    /// Not provably either: refused.
    case unconfirmed(String)

    /// The vendor and model every engine virtual display reports.
    public static let engineVirtualVendor: UInt32 = 0x3256
    public static let engineVirtualModel: UInt32 = 0x0002

    /// - Parameters:
    ///   - builtin: CoreGraphics says the display is built in.
    ///   - vendor, model: CoreGraphics' vendor and model numbers.
    ///   - hardwareVendors: vendors of the display framebuffers the I/O
    ///     registry lists (a virtual display has none).
    public static func classify(builtin: Bool, vendor: UInt32, model: UInt32, hardwareVendors: Set<UInt32>) -> DisplayOrigin {
        if vendor == engineVirtualVendor && model == engineVirtualModel {
            return .virtual("an engine virtual display (vendor 0x3256, model 2)")
        }
        if builtin { return .physical }
        guard vendor != 0 else { return .unconfirmed("the display reports no vendor") }
        guard hardwareVendors.contains(vendor) else {
            return .unconfirmed("no hardware framebuffer reports vendor \(vendor); it may be a virtual display")
        }
        return .physical
    }
}
