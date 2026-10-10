import AgentDesktopProtocol
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

    /// Every active display with its proved origin, for the owner's attach
    /// entry (hub.displays.list). The same classification decides which
    /// ones `screens()` registers, so a display shown as physical here is
    /// one attachDisplay accepts.
    static func report() -> [PlatformDisplay] {
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
        return displays.map { d in
            let bounds = CGDisplayBounds(d.id)
            let pixels = CGDisplayCopyDisplayMode(d.id)?.pixelWidth ?? Int(bounds.width)
            let (origin, detail): (PlatformDisplay.Origin, String?) = {
                switch origins[d.id] {
                case .physical?: return (.physical, nil)
                case let .virtual(why)?: return (.virtual, why)
                case let .unconfirmed(why)?: return (.unconfirmed, why)
                case nil: return (.unconfirmed, "the display could not be classified")
                }
            }()
            return PlatformDisplay(displayId: d.id, name: displayName(d.id, builtin: d.builtin),
                                   frame: AgentDesktopProtocol.Rect(x: bounds.origin.x, y: bounds.origin.y, width: bounds.width, height: bounds.height),
                                   hiDPI: pixels > Int(bounds.width), builtin: d.builtin, origin: origin, originDetail: detail)
        }
    }

    /// The product name the system shows for the display, or a neutral one.
    static func displayName(_ id: CGDirectDisplayID, builtin: Bool) -> String {
        if let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }) {
            let name = screen.localizedName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        return builtin ? "内建显示器" : "显示器 \(id)"
    }

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
                    let external = IORegistryEntryCreateCFProperty(service, "external" as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? Bool
                    // Apple silicon marks external ports; an unmarked one is the built-in panel's.
                    found.append(.init(vendor: v, model: number(product["ProductID"]), serial: number(product["SerialNumber"]),
                                       external: external ?? false))
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
