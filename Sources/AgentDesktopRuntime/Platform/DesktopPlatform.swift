import AgentDesktopProtocol
import Foundation

/// The display surface behind one Desktop: a backend resource, not an
/// identity anyone is authorized by.
public struct ScreenHandle: Equatable, Sendable {
    /// The backend's own name for the surface.
    public var name: String
    public var displayId: UInt32
    /// Global points, top-left origin.
    public var frame: Rect
    public var hiDPI: Bool

    public init(name: String, displayId: UInt32, frame: Rect, hiDPI: Bool) {
        self.name = name
        self.displayId = displayId
        self.frame = frame
        self.hiDPI = hiDPI
    }
}

/// One of the user's active displays as the platform proved it, for the
/// owner to decide which to open to a paired client
/// (docs/security/owner-display-attach.md). `origin` is the Runtime's
/// finding (DisplayOrigin), never the display's own claim: only a physical
/// one can be attached.
public struct PlatformDisplay: Equatable, Sendable {
    public enum Origin: String, Sendable { case physical, virtual, unconfirmed }
    public var displayId: UInt32
    /// The product name the system reports, or a neutral one.
    public var name: String
    /// Global points, top-left origin.
    public var frame: Rect
    public var hiDPI: Bool
    public var builtin: Bool
    public var origin: Origin
    /// Why it is virtual or unconfirmed.
    public var originDetail: String?

    public init(displayId: UInt32, name: String, frame: Rect, hiDPI: Bool, builtin: Bool, origin: Origin, originDetail: String? = nil) {
        self.displayId = displayId
        self.name = name
        self.frame = frame
        self.hiDPI = hiDPI
        self.builtin = builtin
        self.origin = origin
        self.originDetail = originDetail
    }
}

public struct PlatformWindow: Equatable, Sendable {
    public var windowId: UInt32
    public var pid: Int32
    public var appName: String
    public var title: String
    /// Global points, top-left origin.
    public var frame: Rect

    public init(windowId: UInt32, pid: Int32, appName: String, title: String, frame: Rect) {
        self.windowId = windowId
        self.pid = pid
        self.appName = appName
        self.title = title
        self.frame = frame
    }
}

/// One accessibility element of a window, as the backend numbered it in its
/// latest read of that window.
public struct PlatformElement: Equatable, Sendable {
    public var index: Int
    public var role: String
    public var label: String?
    public var value: String?
    public var actions: [String]
    public var frame: Rect?

    public init(index: Int, role: String, label: String?, value: String?, actions: [String], frame: Rect?) {
        self.index = index
        self.role = role
        self.label = label
        self.value = value
        self.actions = actions
        self.frame = frame
    }
}

/// One input action, with its target already resolved by the Runtime:
/// an element by the backend's index from the snapshot that is still the
/// latest read of the window, or a global point that lies in the window.
public struct PlatformAction: Equatable, Sendable {
    /// hover rests the pointer on the target (the engine does it with a
    /// middle-button event, so act refuses it for now); press is
    /// an accessibility press of one element and nothing else (no event
    /// fallback). A drag has no kind here: no platform does one in the
    /// background yet, and the Runtime refuses it before (unsupported_backend).
    public enum Kind: String, Sendable { case click, type, key, scroll, hover, press }
    public var kind: Kind
    public var elementIndex: Int?
    /// Global points, top-left origin.
    public var point: (x: Double, y: Double)?
    public var text: String?
    public var key: String?
    public var modifiers: [String] = []
    public var button: String?
    public var count: Int?
    public var direction: String?
    public var amount: Int?

    public init(kind: Kind) { self.kind = kind }

    public static func == (a: PlatformAction, b: PlatformAction) -> Bool {
        a.kind == b.kind && a.elementIndex == b.elementIndex && a.point?.x == b.point?.x && a.point?.y == b.point?.y
            && a.text == b.text && a.key == b.key && a.modifiers == b.modifiers && a.button == b.button
            && a.count == b.count && a.direction == b.direction && a.amount == b.amount
    }
}

/// One read of a window's accessibility elements.
public struct ElementRead: Sendable {
    public var window: PlatformWindow
    public var elements: [PlatformElement]
    /// Why the read stopped before the whole tree ("deadline", "limits");
    /// nil when it is complete.
    public var truncated: String?

    public init(window: PlatformWindow, elements: [PlatformElement], truncated: String? = nil) {
        self.window = window
        self.elements = elements
        self.truncated = truncated
    }
}

extension DesktopPlatform {
    /// A platform that cannot look says nothing, and G2 refuses.
    public func clipboardHit(at point: (x: Double, y: Double), pid: Int32) -> PlatformHit? { nil }
    public func menuItems(pid: Int32) -> [PlatformMenuItem]? { nil }
    public func keyCharacter(_ key: String, modifiers: [String]) -> PlatformKeyCharacter { .unknown }
    public func focusedControl(pid: Int32) -> PlatformHit? { nil }
    public func menuOpen(pid: Int32) -> Bool? { nil }

    /// Platforms without the user's displays (test doubles, other backends)
    /// refuse physical Desktops.
    public func attachDisplay(_ displayId: UInt32?) throws -> ScreenHandle {
        throw PlatformError(.refused, "this platform cannot attach the user's displays")
    }

    /// Without the user's displays there is nothing to list.
    public func displays() -> [PlatformDisplay] { [] }

    public func overlays(on screen: ScreenHandle, boundPid: Int32) -> [PlatformWindow] { [] }

    /// Platforms that cannot resize a screen say so; nothing changes.
    public func resizeScreen(name: String, width: Int, height: Int) throws -> ScreenHandle {
        throw PlatformError(.refused, "this platform cannot resize a screen")
    }
}

/// A refusal by the platform, already classified for the Runtime API.
public struct PlatformError: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Kind: String, Sendable {
        /// An OS permission is missing (Screen Recording, Accessibility).
        case permission
        /// The target is gone or not where it must be.
        case notFound
        /// The platform declined: limits, sizes, an app already running.
        case refused
    }

    public var kind: Kind
    public var message: String
    /// For an action: true when the platform refused before any input was
    /// sent; false when input may have reached the app.
    public var beforeDispatch: Bool

    public init(_ kind: Kind, _ message: String, beforeDispatch: Bool = true) {
        self.kind = kind
        self.message = message
        self.beforeDispatch = beforeDispatch
    }

    public var description: String { message }

    public var runtimeError: RuntimeError {
        switch kind {
        case .permission: return RuntimeError("permission_denied", message, phase: .handler)
        case .notFound: return RuntimeError.notFound(message)
        case .refused: return RuntimeError("execution_failed", message, phase: .handler)
        }
    }
}

/// What the Runtime needs from the desktop platform. Only the Runtime calls
/// it; every call happens with the Desktop's lock held. The macOS
/// implementation drives the 2ndscreen engine in this process
/// (`EnginePlatform`); tests use a scripted one.
public protocol DesktopPlatform: Sendable {
    func createScreen(name: String, width: Int?, height: Int?) throws -> ScreenHandle
    func destroyScreen(name: String) throws
    /// Change an agent screen's size in place; returns it as it is now.
    func resizeScreen(name: String, width: Int, height: Int) throws -> ScreenHandle
    /// One of the user's own displays, by ID (nil: the main display), for a
    /// physical Desktop. Nothing is created: the handle only names the
    /// display, and destroyScreen must never be called with it.
    func attachDisplay(_ displayId: UInt32?) throws -> ScreenHandle
    /// Every active display with its origin as the platform proved it
    /// (hub.displays.list, owner only). Only a `physical` one is ever
    /// attached; the others are listed so the owner sees why not.
    func displays() -> [PlatformDisplay]
    /// Launch an app onto the screen; its process and windows there. The
    /// process is one this launch provably started (the engine's one-time
    /// launch token, LaunchOwnership); a launch that cannot prove it throws
    /// instead of returning a pid. The Runtime relies on this to quit what
    /// it launched (#139).
    func launch(on screen: ScreenHandle, bundleId: String?, path: String?, newInstance: Bool) throws
        -> (pid: Int32, windows: [PlatformWindow])
    /// Move a process's window (or all of them) onto the screen.
    func moveWindows(to screen: ScreenHandle, pid: Int32, windowId: UInt32?) throws -> [PlatformWindow]
    /// The window as it is now, if it still exists and is on the screen.
    func window(on screen: ScreenHandle, pid: Int32, windowId: UInt32) -> PlatformWindow?
    /// Write a PNG of the whole screen; its size in pixels.
    func screenshot(_ screen: ScreenHandle, to path: String) throws -> (width: Int, height: Int)
    /// On-screen normal windows that overlap the screen, front to back, as
    /// the window server orders them now.
    func stack(on screen: ScreenHandle) -> [PlatformWindow]
    /// Write a PNG of the window alone, rendered by the window server
    /// without anything in front of it, at the display's scale; its size in
    /// pixels. Nothing else of the screen is captured or written.
    func windowScreenshot(_ screen: ScreenHandle, pid: Int32, windowId: UInt32, to path: String) throws -> (width: Int, height: Int)
    /// On-screen windows above the normal layer that overlap the screen
    /// (notification banners, other apps' menus and popovers, system
    /// dialogs), except the system Dock's display-wide layer and other
    /// processes' items in the menu bar. Windows of `boundPid` always count:
    /// input to that process may land on any of them. On a physical Desktop
    /// any of them over the bound window counts as covering it.
    func overlays(on screen: ScreenHandle, boundPid: Int32) -> [PlatformWindow]
    /// Read the window's accessibility elements. The read replaces the
    /// backend's numbering for that window. Past `deadline` the backend
    /// reads no further node and returns what it has, marked truncated.
    /// Called on the Runtime's AX threads (AXReader), never with a
    /// Desktop's lock held.
    func elements(on screen: ScreenHandle, pid: Int32, windowId: UInt32, query: String?, deadline: Date) throws
        -> ElementRead
    /// Ask an app to quit (normal quit, never forced); false if it is gone
    /// or declined.
    func quit(pid: Int32) -> Bool
    /// Deliver one action to the window; the route the input took.
    /// Throws a PlatformError whose `beforeDispatch` says whether input
    /// may have been sent.
    func perform(_ action: PlatformAction, on screen: ScreenHandle, pid: Int32, windowId: UInt32) throws -> String

    // G2 (input never through the clipboard): read-only probes the Runtime
    // asks right before sending. A platform that cannot answer returns nil
    // or `.unknown`, and the Runtime then refuses the input.

    /// The accessibility element at a global point, read now.
    func clipboardHit(at point: (x: Double, y: Double), pid: Int32) -> PlatformHit?
    /// The app's menu bar items that have a keyboard equivalent; nil when
    /// the menu bar cannot be read whole within its time limit. The Runtime
    /// asks before taking a Desktop's lock.
    func menuItems(pid: Int32) -> [PlatformMenuItem]?
    /// What `perform` would type for this key and modifiers under the
    /// current keyboard layout.
    func keyCharacter(_ key: String, modifiers: [String]) -> PlatformKeyCharacter
    /// The element with keyboard focus in the app, read now: what Return or
    /// Space would press. Role "AXNone" when nothing has focus.
    func focusedControl(pid: Int32) -> PlatformHit?
    /// Whether the app shows a menu now; nil when that cannot be told.
    func menuOpen(pid: Int32) -> Bool?
}

/// The element at a point, as G2 judges it.
public struct PlatformHit: Equatable, Sendable {
    /// Without a subrole: "AXButton", never "AXButton/AXToggle".
    public var role: String
    public var texts: [String]
    /// A menu item's keyboard equivalent, such as "cmd+V".
    public var shortcut: String?
    public var windowId: UInt32?
    public var inMenu: Bool
    /// Names of the controls around it (up to three levels up).
    public var ancestorTexts: [String]
    /// It has keyboard focus: typing there needs no click.
    public var focused: Bool
    /// It is editable text (a field, or rich text a page marks editable).
    public var editable: Bool
    /// For a focused element: the names of its window's default button,
    /// which Return in a text field presses.
    public var defaultButtonTexts: [String] = []

    public init(role: String, texts: [String], shortcut: String? = nil, windowId: UInt32?, inMenu: Bool = false,
                ancestorTexts: [String] = [], focused: Bool = false, editable: Bool = false, defaultButtonTexts: [String] = []) {
        self.defaultButtonTexts = defaultButtonTexts
        self.role = role
        self.texts = texts
        self.shortcut = shortcut
        self.windowId = windowId
        self.inMenu = inMenu
        self.ancestorTexts = ancestorTexts
        self.focused = focused
        self.editable = editable
    }
}

public struct PlatformMenuItem: Equatable, Sendable {
    public var texts: [String]
    public var shortcut: String

    public init(texts: [String], shortcut: String) {
        self.texts = texts
        self.shortcut = shortcut
    }
}

public enum PlatformKeyCharacter: Equatable, Sendable {
    case named
    case character(String)
    case unknown
}
