import Foundation
import Testing
@testable import TarsAgent

struct IPhoneCapabilitiesTests {
    /// The verbs an action space offers: each line's name before "(".
    private func verbs(_ actionSpace: String) -> [String] {
        actionSpace.split(separator: "\n").compactMap { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard let open = line.firstIndex(of: "(") else { return nil }
            return String(line[..<open])
        }
    }

    @Test func everyCapabilityIsDeclaredOnce() {
        let declared = IPhoneCapabilities.declarations.map(\.capability)
        #expect(Set(declared) == Set(IPhoneCapabilities.Capability.allCases))
        #expect(declared.count == IPhoneCapabilities.Capability.allCases.count)
        for declaration in IPhoneCapabilities.declarations {
            #expect(!declaration.basis.isEmpty, "\(declaration.capability)")
            // A supported capability says what it needs.
            if declaration.support == .supported {
                #expect(!declaration.conditions.isEmpty, "\(declaration.capability)")
                #expect(declaration.evidence == .deviceTested, "\(declaration.capability)")
            }
        }
    }

    @Test func gesturesAreNotSupported() {
        for gesture: IPhoneCapabilities.Capability in [.swipe, .drag, .longPress, .scroll, .elementTree] {
            #expect(IPhoneCapabilities.support(gesture) == .unsupported, "\(gesture)")
        }
        // Never stated as a limit of iPhone Mirroring itself.
        #expect(IPhoneCapabilities.declaration(.swipe).basis.contains("this backend"))
    }

    @Test func everyOfferedVerbIsSupported() {
        var options = TarsAgent.Options()
        options.forIPhone()
        #expect(options.actionSpaces == TarsAgent.iPhoneActionSpaces)
        for verb in verbs(TarsAgent.iPhoneActionSpaces) {
            if IPhoneCapabilities.controlVerbs.contains(verb) { continue }
            guard let action = IPhoneCapabilities.action(forModelVerb: verb) else {
                Issue.record("\(verb) is offered but acts on nothing this backend declares")
                continue
            }
            #expect(IPhoneCapabilities.declaration(for: action).support == .supported, "\(verb)")
        }
    }

    @Test func noUnsupportedVerbIsOffered() {
        let offered = Set(verbs(TarsAgent.iPhoneActionSpaces))
        // Every verb the desktop and Android agents know.
        let known = Set(verbs(TarsAgent.actionSpaces) + verbs(TarsAgent.phoneActionSpaces))
        for verb in known.subtracting(IPhoneCapabilities.controlVerbs) {
            let action = IPhoneCapabilities.action(forModelVerb: verb)
            let supported = action.map { IPhoneCapabilities.declaration(for: $0).support == .supported } ?? false
            if !supported {
                #expect(!offered.contains(verb), "\(verb) is offered but not supported")
            }
        }
        #expect(!offered.contains("press_back"))
    }

    @Test func gestureSwitchFollowsTheDeclaration() {
        var options = TarsAgent.Options()
        options.forIPhone()
        let swipes = [IPhoneCapabilities.Capability.swipe, .drag, .scroll]
            .contains { IPhoneCapabilities.support($0) == .supported }
        #expect(options.gestures == swipes)
        #expect(options.listElements == (IPhoneCapabilities.support(.elementTree) == .supported))
    }

    @Test func hostEffectsAreSeparate() {
        for action in IPhoneCapabilities.Action.allCases {
            #expect(!IPhoneCapabilities.hostEffects(for: action).usesPhysicalPointer, "\(action)")
        }
        let tap = IPhoneCapabilities.hostEffects(for: .tap)
        #expect(tap.borrowsKeyFocus && !tap.mayTemporarilyActivateApp && !tap.usesHostClipboard)
        for shortcut: IPhoneCapabilities.Action in [.home, .appSwitcher, .spotlight] {
            #expect(IPhoneCapabilities.hostEffects(for: shortcut).mayTemporarilyActivateApp, "\(shortcut)")
        }
        let type = IPhoneCapabilities.hostEffects(for: .typeText)
        #expect(type.usesHostClipboard && !type.mayTemporarilyActivateApp)
        let enter = IPhoneCapabilities.hostEffects(for: .pressReturn)
        #expect(!enter.borrowsKeyFocus && !enter.mayTemporarilyActivateApp && !enter.usesHostClipboard)
        // What is refused touches nothing.
        for action in IPhoneCapabilities.Action.allCases
        where IPhoneCapabilities.declaration(for: action).support != .supported {
            #expect(IPhoneCapabilities.hostEffects(for: action) == .none, "\(action)")
        }
    }
}
