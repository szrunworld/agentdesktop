import Foundation

/// What the iPhone Mirroring backend (`IPhoneAgentScreen`) can do to a phone,
/// and what each action does to the Mac it runs on.
///
/// This is a declaration, not a probe: every entry says what this backend
/// supports, refuses, or has not proven, and why. It is about this backend's
/// automated input, not about iPhone Mirroring itself: Apple documents that a
/// person can tap, long-press, scroll and swipe a mirrored phone with a mouse
/// or trackpad. What this backend could not do on 2026-10-04/07 is make those
/// gestures land from events it posts in the background.
///
/// Host effects are kept apart rather than folded into one "background"
/// flag: not moving the real pointer is not the same as never borrowing key
/// focus, never making Mirroring front, or leaving the clipboard alone.
///
/// Draft for the device-session contract in `docs/ios/`; the Runtime, not
/// this table, decides what a target advertises once that contract lands.
public enum IPhoneCapabilities {
    /// The backend this table describes, as a Target's `backend` would name it.
    public static let backend = "mirroring"
    /// The target kind, as a Target's `kind` would name it.
    public static let targetKind = "ios"

    public enum Support: String, Sendable, CaseIterable {
        /// Implemented and seen to work on a real phone.
        case supported
        /// This backend refuses it or cannot do it; it is never offered.
        case unsupported
        /// Not offered until a real-device run proves it.
        case unverified
    }

    public enum Capability: String, Sendable, CaseIterable {
        case tap, swipe, drag, longPress, scroll
        /// Any text, Chinese and emoji included, into the focused field.
        case unicodeText
        /// Return and Delete.
        case editingKeys
        /// The phone app's accessibility tree.
        case elementTree
        /// Opening an app by name, through Spotlight.
        case appLaunch
        case home, appSwitcher, spotlight
        /// Hearing or controlling the phone's sound from the Mac.
        case audio
    }

    /// How a declaration is known.
    public enum Evidence: String, Sendable {
        /// Tried on a real phone through iPhone Mirroring (2026-10-04/07).
        case deviceTested
        /// Read from this backend's source; no device run for this claim.
        case sourceOnly
        /// Neither: an open question.
        case none
    }

    public struct Declaration: Equatable, Sendable {
        public let capability: Capability
        public let support: Support
        public let evidence: Evidence
        public let basis: String
        /// What must hold for a supported capability to work.
        public let conditions: [String]
    }

    /// One action this backend could be asked for.
    public enum Action: String, Sendable, CaseIterable {
        case tap
        case typeText
        case pressReturn, pressDelete
        case home, appSwitcher, spotlight
        case swipe, drag, longPress, scroll
    }

    /// What an action does to the Mac, each effect on its own.
    public struct HostEffects: Equatable, Sendable {
        /// Moves the user's real pointer.
        public let usesPhysicalPointer: Bool
        /// May make iPhone Mirroring the front app, however briefly.
        public let mayTemporarilyActivateApp: Bool
        /// Makes Mirroring's window key for a moment without raising it,
        /// then gives focus back to the user's window.
        public let borrowsKeyFocus: Bool
        /// Writes the Mac's general pasteboard (and puts it back).
        public let usesHostClipboard: Bool
        public let basis: String

        public static let none = HostEffects(usesPhysicalPointer: false, mayTemporarilyActivateApp: false,
                                             borrowsKeyFocus: false, usesHostClipboard: false,
                                             basis: "not delivered")
    }

    // MARK: Capabilities

    /// Phone needs common to everything this backend does.
    static let session = [
        "iPhone Mirroring is connected and shows the phone, not a status page",
        "the phone is locked and near the Mac (unlocking it ends mirroring)",
        "the Mirroring window is on its agent screen",
    ]

    public static let declarations: [Declaration] = [
        Declaration(
            capability: .tap, support: .supported, evidence: .deviceTested,
            basis: "background clicks posted to the Mirroring window reach the phone as taps",
            conditions: session),
        Declaration(
            capability: .swipe, support: .unsupported, evidence: .deviceTested,
            basis: "posted wheel events, trackpad scroll phases and several kinds of drag had no effect on the "
                + "phone, in the background and in front; this backend has no reliable background swipe "
                + "(a person's mouse or trackpad can swipe, per Apple)",
            conditions: []),
        Declaration(
            capability: .drag, support: .unsupported, evidence: .deviceTested,
            basis: "posted drags had no effect on the phone; a drag is refused, never turned into taps",
            conditions: []),
        Declaration(
            capability: .longPress, support: .unsupported, evidence: .sourceOnly,
            basis: "not implemented: a click with a duration is refused; no device run has tried a held press",
            conditions: []),
        Declaration(
            capability: .scroll, support: .unsupported, evidence: .deviceTested,
            basis: "posted wheel events and trackpad scroll phases had no effect on the phone",
            conditions: []),
        Declaration(
            capability: .unicodeText, support: .supported, evidence: .deviceTested,
            basis: "typed key codes become pinyin on a Chinese keyboard, so text is pasted from the Mac's "
                + "clipboard with ⌘ held as a key of its own (⌘V through the menus types \"v\"); "
                + "the backend presses the phone's Allow Paste; delivery is evidence, not confirmation",
            conditions: session + [
                "a text field on the phone has focus",
                "Universal Clipboard works between the Mac and the phone",
                "the host clipboard is free for the length of the paste",
                "not for sensitive text (passwords, tokens, personal data) or unattended input: the text "
                    + "passes through the Mac's clipboard, which other apps and Universal Clipboard can read, "
                    + "and a paste that times out leaves it there",
            ]),
        Declaration(
            capability: .editingKeys, support: .supported, evidence: .deviceTested,
            basis: "Return and Delete posted to the Mirroring window reach the phone; arrow keys do not",
            conditions: session),
        Declaration(
            capability: .elementTree, support: .unsupported, evidence: .sourceOnly,
            basis: "Mirroring exposes none of the phone's controls through accessibility; elements() is empty",
            conditions: []),
        Declaration(
            capability: .appLaunch, support: .unverified, evidence: .none,
            basis: "Spotlight (⌘3), pasting a name and Return each work, but no run has accepted the whole "
                + "sequence as one app launch, and the result needs a fresh observation",
            conditions: session),
        Declaration(
            capability: .home, support: .supported, evidence: .deviceTested,
            basis: "⌘1, Mirroring's View > Home Screen", conditions: session),
        Declaration(
            capability: .appSwitcher, support: .supported, evidence: .deviceTested,
            basis: "⌘2, Mirroring's View > App Switcher", conditions: session),
        Declaration(
            capability: .spotlight, support: .supported, evidence: .deviceTested,
            basis: "⌘3, Mirroring's View > Spotlight", conditions: session),
        Declaration(
            capability: .audio, support: .unverified, evidence: .sourceOnly,
            basis: "the phone plays through the Mac's output; the backend can only set the Mac's volume "
                + "(SystemVolume), has no per-phone volume and captures no audio",
            conditions: []),
    ]

    public static func declaration(_ capability: Capability) -> Declaration {
        declarations.first { $0.capability == capability }!
    }

    public static func support(_ capability: Capability) -> Support {
        declaration(capability).support
    }

    // MARK: Actions

    /// The capability an action exercises.
    public static func capability(for action: Action) -> Capability {
        switch action {
        case .tap: .tap
        case .typeText: .unicodeText
        case .pressReturn, .pressDelete: .editingKeys
        case .home: .home
        case .appSwitcher: .appSwitcher
        case .spotlight: .spotlight
        case .swipe: .swipe
        case .drag: .drag
        case .longPress: .longPress
        case .scroll: .scroll
        }
    }

    public static func declaration(for action: Action) -> Declaration {
        declaration(capability(for: action))
    }

    /// What `action` does to the Mac. Pointer and front-app effects were
    /// watched on 2026-10-04/07 and not seen to change for tap, key or paste;
    /// the flags below follow the code paths, which is what may happen: a
    /// path that puts the user's app back in front after Mirroring came
    /// forward means Mirroring may be the front app for a moment.
    public static func hostEffects(for action: Action) -> HostEffects {
        switch action {
        case .tap:
            HostEffects(
                usesPhysicalPointer: false, mayTemporarilyActivateApp: true, borrowsKeyFocus: true,
                usesHostClipboard: false,
                basis: "BackgroundInput.click: SkyLight.focusWithoutRaise makes the window key without raising "
                    + "it, posts the click, then restoreFocus gives focus back; the click itself may bring "
                    + "Mirroring forward, in which case the user's app is reactivated afterwards, so Mirroring "
                    + "may be the front app for a moment")
        case .typeText:
            HostEffects(
                usesPhysicalPointer: false, mayTemporarilyActivateApp: true, borrowsKeyFocus: true,
                usesHostClipboard: true,
                basis: "IPhoneAgentScreen.paste writes NSPasteboard.general (after saving every item and type, "
                    + "or refuses), sends ⌘V with holdModifiers (no activation) and puts the clipboard back, "
                    + "later if the phone may still fetch it; pressing Allow Paste is the same click as a tap, "
                    + "which borrows key focus and may bring Mirroring forward for a moment; a trailing "
                    + "newline adds Return")
        case .pressReturn, .pressDelete:
            HostEffects(
                usesPhysicalPointer: false, mayTemporarilyActivateApp: false, borrowsKeyFocus: false,
                usesHostClipboard: false,
                basis: "BackgroundInput.key without ⌘: posted to Mirroring's process")
        case .home, .appSwitcher, .spotlight:
            HostEffects(
                usesPhysicalPointer: false, mayTemporarilyActivateApp: true, borrowsKeyFocus: false,
                usesHostClipboard: false,
                basis: "BackgroundInput.key with ⌘: SkyLight.withMenuShortcutActivation makes Mirroring front "
                    + "while the key is queued, then the previous app front again")
        case .swipe, .drag, .longPress, .scroll:
            .none
        }
    }

    // MARK: The model's action space

    /// The device action a UI-TARS verb asks for, for verbs that act on the
    /// phone; nil for `wait`, `finished`, `call_user` and verbs this backend
    /// has no action for (`press_back`: an iPhone has no Back key).
    public static func action(forModelVerb verb: String) -> Action? {
        switch verb {
        case "click", "left_single", "tap": .tap
        case "type": .typeText
        case "press_home": .home
        case "scroll": .scroll
        case "drag", "swipe": .drag
        case "long_press": .longPress
        default: nil
        }
    }

    /// Verbs that do not act on the phone.
    public static let controlVerbs: Set<String> = ["wait", "finished", "call_user"]
}
