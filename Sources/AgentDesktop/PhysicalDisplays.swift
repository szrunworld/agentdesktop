import AppKit
import CoreGraphics
import SecondScreenCore

/// The user's own displays, registered with the engine as host screens so a
/// physical Desktop can address one by name (screenshot, element reads,
/// input) without any display being created. Virtual displays are left out,
/// whoever made them: this host's agent screens, a test copy's, another
/// 2ndscreen's. Names are stable for a display ID.
enum PhysicalDisplays {
    /// The vendor and product every engine virtual display reports
    /// (VirtualDisplay's descriptor).
    static let virtualVendor: UInt32 = 0x3256
    static let virtualProduct: UInt32 = 0x0002

    static func name(_ id: CGDirectDisplayID) -> String { "physical-\(id)" }

    static func isVirtual(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(id) == virtualVendor && CGDisplayModelNumber(id) == virtualProduct
    }

    static func screens() -> [ScreenInfo] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).filter { !isVirtual($0) }.map { id in
            let bounds = CGDisplayBounds(id)
            let pixels = CGDisplayCopyDisplayMode(id)?.pixelWidth ?? Int(bounds.width)
            return ScreenInfo(name: name(id), kind: .primary, displayID: id,
                              width: Int(bounds.width), height: Int(bounds.height),
                              hiDPI: pixels > Int(bounds.width),
                              frame: Frame(bounds))
        }
    }
}
