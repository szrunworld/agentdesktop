import AgentDesktopRuntime
import AppKit
import CoreGraphics
import IOKit
import SecondScreenCore

/// The user's own displays, registered with the engine as host screens so a
/// physical Desktop can address one by name (screenshot, element reads,
/// input) without any display being created. A display is registered only
/// when its origin is proved physical (DisplayOrigin): built in, or an
/// external display matched one-to-one with a hardware framebuffer in the I/O registry.
/// Virtual displays, whoever made them, and displays of unknown origin are
/// left out, so a physical Desktop can never attach them.
enum PhysicalDisplays {
    static func name(_ id: CGDirectDisplayID) -> String { "physical-\(id)" }

    static func screens() -> [ScreenInfo] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        let displays = ids.prefix(Int(count)).map {
            DisplayOrigin.Display(id: $0, builtin: CGDisplayIsBuiltin($0) != 0,
                                  vendor: CGDisplayVendorNumber($0), model: CGDisplayModelNumber($0),
                                  serial: CGDisplaySerialNumber($0))
        }
        let origins = DisplayOrigin.classify(displays, framebuffers: framebuffers())
        return displays.filter { origins[$0.id] == .physical }.map { d in
            let bounds = CGDisplayBounds(d.id)
            let pixels = CGDisplayCopyDisplayMode(d.id)?.pixelWidth ?? Int(bounds.width)
            return ScreenInfo(name: name(d.id), kind: .primary, displayID: d.id,
                              width: Int(bounds.width), height: Int(bounds.height),
                              hiDPI: pixels > Int(bounds.width), frame: Frame(bounds))
        }
    }

    /// One entry per display framebuffer the I/O registry lists, with the
    /// EDID identity it reports: Apple silicon's IOMobileFramebuffer
    /// ("DisplayAttributes" → "ProductAttributes": "LegacyManufacturerID",
    /// "ProductID", "SerialNumber") and Intel's IODisplayConnect
    /// ("DisplayVendorID", "DisplayProductID", "DisplaySerialNumber").
    /// A CGVirtualDisplay has no framebuffer here.
    static func framebuffers() -> [DisplayOrigin.Framebuffer] {
        func number(_ v: Any?) -> UInt64? { (v as? NSNumber).map { $0.uint64Value } }
        var found: [DisplayOrigin.Framebuffer] = []
        for cls in ["IOMobileFramebuffer", "IODisplayConnect"] {
            var it: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &it) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(it) }
            while case let service = IOIteratorNext(it), service != 0 {
                defer { IOObjectRelease(service) }
                if let attrs = IORegistryEntryCreateCFProperty(service, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any],
                   let product = attrs["ProductAttributes"] as? [String: Any],
                   let v = (product["LegacyManufacturerID"] as? NSNumber)?.uint32Value {
                    found.append(.init(vendor: v, model: number(product["ProductID"]), serial: number(product["SerialNumber"])))
                } else if let info = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayOnlyPreferredName))?
                    .takeRetainedValue() as? [String: Any],
                   let v = (info[kDisplayVendorID] as? NSNumber)?.uint32Value {
                    found.append(.init(vendor: v, model: number(info[kDisplayProductID]), serial: number(info[kDisplaySerialNumber])))
                }
            }
        }
        return found
    }
}
