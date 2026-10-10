import Foundation

/// Where a display comes from, for deciding whether a physical Desktop may
/// attach it. Only displays the hardware vouches for are trusted; anything
/// the platform cannot place is refused rather than assumed physical.
public enum DisplayOrigin: Equatable, Sendable {
    /// The built-in panel, or an external display that a hardware
    /// framebuffer of the same vendor, model and serial vouches for.
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
        public var serial: UInt32
        public init(id: UInt32, builtin: Bool, vendor: UInt32, model: UInt32, serial: UInt32 = 0) {
            self.id = id; self.builtin = builtin; self.vendor = vendor; self.model = model; self.serial = serial
        }
    }

    /// One hardware display framebuffer in the I/O registry, with the EDID
    /// identity it reports (a virtual display has no framebuffer). A
    /// framebuffer that reports no serial matches any serial.
    public struct Framebuffer: Equatable, Sendable {
        public var vendor: UInt32
        public var model: UInt64?
        public var serial: UInt64?
        public init(vendor: UInt32, model: UInt64?, serial: UInt64?) {
            self.vendor = vendor; self.model = model; self.serial = serial
        }
        func vouches(for d: Display) -> Bool {
            vendor == d.vendor && model == UInt64(d.model) && (serial == nil || serial == UInt64(d.serial))
        }
    }

    /// Classify every active display at once, independent of display order.
    ///
    /// An external display is physical only when hardware framebuffers
    /// reporting its vendor, model and serial are at least as many as the
    /// displays claiming that identity (and likewise for vendor and model
    /// alone). A virtual display that copies a real monitor's identity
    /// makes one claimant too many: then every display claiming it is
    /// unconfirmed, the real one included (fail closed), rather than the
    /// first in display order winning (Codex on e0be427). Built-in panels
    /// are physical; any engine virtual display, even one claiming to be
    /// built in, is virtual.
    public static func classify(_ displays: [Display], framebuffers: [Framebuffer]) -> [UInt32: DisplayOrigin] {
        func isEngineVirtual(_ d: Display) -> Bool { d.vendor == engineVirtualVendor && d.model == engineVirtualModel }
        let external = displays.filter { !$0.builtin && !isEngineVirtual($0) && $0.vendor != 0 }
        var result: [UInt32: DisplayOrigin] = [:]
        for d in displays {
            if isEngineVirtual(d) {
                result[d.id] = .virtual("an engine virtual display (vendor 0x3256, model 2)")
            } else if d.builtin {
                result[d.id] = .physical
            } else if d.vendor == 0 {
                result[d.id] = .unconfirmed("the display reports no vendor")
            } else {
                let sameIdentity = external.filter { $0.vendor == d.vendor && $0.model == d.model && $0.serial == d.serial }.count
                let sameModel = external.filter { $0.vendor == d.vendor && $0.model == d.model }.count
                let vouching = framebuffers.filter { $0.vouches(for: d) }.count
                let ofModel = framebuffers.filter { $0.vendor == d.vendor && $0.model == UInt64(d.model) }.count
                if vouching > 0 && sameIdentity <= vouching && sameModel <= ofModel {
                    result[d.id] = .physical
                } else {
                    result[d.id] = .unconfirmed("no hardware framebuffer of its own vouches for this display; it may be a virtual display")
                }
            }
        }
        return result
    }
}
