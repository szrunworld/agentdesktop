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
    /// framebuffer that reports no serial matches any serial. `external`
    /// is what the registry says about the port (Apple silicon marks
    /// external ones); a built-in panel's framebuffer never vouches for an
    /// external display, even one copying the panel's identity.
    public struct Framebuffer: Equatable, Sendable {
        public var vendor: UInt32
        public var model: UInt64?
        public var serial: UInt64?
        public var external: Bool?
        public init(vendor: UInt32, model: UInt64?, serial: UInt64?, external: Bool? = nil) {
            self.vendor = vendor; self.model = model; self.serial = serial; self.external = external
        }
        func vouches(for d: Display) -> Bool {
            external != false && vendor == d.vendor && model == UInt64(d.model) && (serial == nil || serial == UInt64(d.serial))
        }
    }

    /// Classify every active display at once, independent of display order.
    ///
    /// Each hardware framebuffer backs one display at most. For every vendor
    /// and model, the displays claiming it (external ones, and built-in
    /// panels some framebuffer vouches for) must be matchable one-to-one to
    /// distinct framebuffers that vouch for them (same vendor, model and
    /// serial; a framebuffer without a serial matches any serial). If no
    /// such assignment exists, every external display of that vendor and
    /// model is unconfirmed, the real one included (fail closed), rather
    /// than counts or display order deciding (Codex on e0be427, 3d85886). A
    /// framebuffer the registry marks as built in vouches for no external
    /// display (Codex on cb64fce). Built-in panels are physical; any engine
    /// virtual display, even one claiming to be built in, is virtual.
    public static func classify(_ displays: [Display], framebuffers: [Framebuffer]) -> [UInt32: DisplayOrigin] {
        func isEngineVirtual(_ d: Display) -> Bool { d.vendor == engineVirtualVendor && d.model == engineVirtualModel }
        func vouches(_ f: Framebuffer, _ d: Display) -> Bool {
            d.builtin ? (f.external != true && f.vendor == d.vendor && f.model == UInt64(d.model)
                         && (f.serial == nil || f.serial == UInt64(d.serial)))
                      : f.vouches(for: d)
        }
        var result: [UInt32: DisplayOrigin] = [:]
        var external: [Display] = []
        for d in displays {
            if isEngineVirtual(d) {
                result[d.id] = .virtual("an engine virtual display (vendor 0x3256, model 2)")
            } else if d.builtin {
                result[d.id] = .physical
            } else if d.vendor == 0 {
                result[d.id] = .unconfirmed("the display reports no vendor")
            } else {
                external.append(d)
            }
        }
        let builtins = displays.filter { $0.builtin && !isEngineVirtual($0) }
        for key in Set(external.map { "\($0.vendor)/\($0.model)" }) {
            let group = external.filter { "\($0.vendor)/\($0.model)" == key }
            // Built-in panels of the same identity take a framebuffer too, when one vouches for them.
            let panels = builtins.filter { b in "\(b.vendor)/\(b.model)" == key && framebuffers.contains { vouches($0, b) } }
            let claimants = group + panels
            let matched = perfectMatching(claimants, framebuffers, vouches)
            for d in group {
                result[d.id] = matched ? .physical
                    : .unconfirmed("no hardware framebuffer of its own vouches for this display; it may be a virtual display")
            }
        }
        return result
    }

    /// Whether every claimant can be given a distinct framebuffer that
    /// vouches for it (bipartite matching by augmenting paths).
    static func perfectMatching(_ claimants: [Display], _ framebuffers: [Framebuffer],
                                _ vouches: (Framebuffer, Display) -> Bool) -> Bool {
        var owner = [Int?](repeating: nil, count: framebuffers.count)
        func assign(_ c: Int, _ seen: inout [Bool]) -> Bool {
            for f in framebuffers.indices where !seen[f] && vouches(framebuffers[f], claimants[c]) {
                seen[f] = true
                if owner[f] == nil || assign(owner[f]!, &seen) { owner[f] = c; return true }
            }
            return false
        }
        for c in claimants.indices {
            var seen = [Bool](repeating: false, count: framebuffers.count)
            if !assign(c, &seen) { return false }
        }
        return true
    }
}
