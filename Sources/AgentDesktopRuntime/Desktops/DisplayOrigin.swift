import Foundation

/// Where a display comes from, for deciding whether a physical Desktop may
/// attach it. Only displays the hardware vouches for are trusted; anything
/// the platform cannot place is refused rather than assumed physical.
public enum DisplayOrigin: Equatable, Sendable {
    /// The built-in panel, or an external display matched one-to-one with a
    /// hardware framebuffer of the same vendor.
    case physical
    /// A display some process created (the engine's own, or another's).
    case virtual(String)
    /// Not provably either: refused.
    case unconfirmed(String)

    /// The vendor and model every engine virtual display reports.
    public static let engineVirtualVendor: UInt32 = 0x3256
    public static let engineVirtualModel: UInt32 = 0x0002

    /// One display as CoreGraphics reports it.
    public struct Display: Equatable, Sendable {
        public var id: UInt32
        public var builtin: Bool
        public var vendor: UInt32
        public var model: UInt32
        public init(id: UInt32, builtin: Bool, vendor: UInt32, model: UInt32) {
            self.id = id; self.builtin = builtin; self.vendor = vendor; self.model = model
        }
    }

    /// Classify every active display at once.
    ///
    /// `framebufferVendors` lists one vendor per hardware display framebuffer
    /// in the I/O registry (a virtual display has none). Each framebuffer
    /// vouches for one display only: built-in panels take theirs first, then
    /// external displays take one each, in display order. An external display
    /// left without a framebuffer of its vendor is unconfirmed, so a virtual
    /// display that copies a real vendor number is not trusted on the strength
    /// of another display's hardware.
    public static func classify(_ displays: [Display], framebufferVendors: [UInt32]) -> [UInt32: DisplayOrigin] {
        var unused: [UInt32: Int] = [:]
        for v in framebufferVendors { unused[v, default: 0] += 1 }
        var result: [UInt32: DisplayOrigin] = [:]
        func isEngineVirtual(_ d: Display) -> Bool { d.vendor == engineVirtualVendor && d.model == engineVirtualModel }
        for d in displays where d.builtin && !isEngineVirtual(d) {
            result[d.id] = .physical
            if let n = unused[d.vendor], n > 0 { unused[d.vendor] = n - 1 }
        }
        for d in displays where result[d.id] == nil {
            if isEngineVirtual(d) {
                result[d.id] = .virtual("an engine virtual display (vendor 0x3256, model 2)")
            } else if d.vendor == 0 {
                result[d.id] = .unconfirmed("the display reports no vendor")
            } else if let n = unused[d.vendor], n > 0 {
                unused[d.vendor] = n - 1
                result[d.id] = .physical
            } else {
                result[d.id] = .unconfirmed("no unclaimed hardware framebuffer of vendor \(d.vendor); it may be a virtual display")
            }
        }
        return result
    }
}
