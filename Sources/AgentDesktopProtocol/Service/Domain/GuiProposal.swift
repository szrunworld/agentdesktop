import Foundation

// GUI proposals of contract v1 (spec §04, §06.2, §08.4). A proposal is a
// suggestion: it carries no execution authority, and the Runtime rechecks
// everything in it before any input.

public enum GuiAdapterId: String, CaseIterable, Sendable {
    /// Production adapter: the UI-TARS prompt and action grammar.
    case uitarsV1 = "uitars_v1"
    /// Neutral test protocol; never selectable in a production build.
    case fixtureJsonV1 = "fixture_json_v1"
}

public struct AdapterProvenance: Equatable, Sendable {
    public let adapterId: GuiAdapterId
    public let adapterVersion: String
    public let promptVersion: String
    public let parserVersion: String
    public let coordinateProtocol: CoordinateProtocol

    public init(adapterId: GuiAdapterId, adapterVersion: String, promptVersion: String,
                parserVersion: String, coordinateProtocol: CoordinateProtocol) {
        self.adapterId = adapterId; self.adapterVersion = adapterVersion
        self.promptVersion = promptVersion; self.parserVersion = parserVersion
        self.coordinateProtocol = coordinateProtocol
    }

    public var json: JSONValue {
        .obj([
            ("adapterId", .string(adapterId.rawValue)), ("adapterVersion", .string(adapterVersion)),
            ("promptVersion", .string(promptVersion)), ("parserVersion", .string(parserVersion)),
            ("coordinateProtocol", .string(coordinateProtocol.rawValue)),
        ])
    }
}

public enum GuiActionKind: String, CaseIterable, Hashable, Sendable {
    case click, type, key, scroll
}

public enum ScrollDirection: String, CaseIterable, Sendable {
    case up, down, left, right
}

/// The key names a `key` action may use (domain.schema.json KeyAction).
public enum GuiKeys {
    public static let named: Set<String> = [
        "Shift", "Control", "Alt", "Meta", "Enter", "Tab", "Escape", "Backspace", "Delete",
        "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Home", "End", "PageUp", "PageDown", "Space",
    ]
    public static let maxKeys = 4

    public static func isValid(_ key: String) -> Bool {
        if named.contains(key) { return true }
        guard key.count == 1, let s = key.unicodeScalars.first else { return false }
        return ("A"..."Z").contains(s) || ("0"..."9").contains(s)
    }
}

public enum GuiAction: Equatable, Sendable {
    /// Left button only in v1. `sourcePixel` is in source screenshot pixels.
    case click(sourcePixel: Point)
    /// Sensitive: never put the text into ordinary logs or run events.
    case type(text: String)
    case key(keys: [String])
    case scroll(sourcePixel: Point, direction: ScrollDirection, amountPixels: Int)

    public static let maxTypeLength = 65_536
    public static let scrollAmountRange = 1...2000

    public var kind: GuiActionKind {
        switch self {
        case .click: return .click
        case .type: return .type
        case .key: return .key
        case .scroll: return .scroll
        }
    }

    public var json: JSONValue {
        switch self {
        case let .click(p):
            return .obj([("type", .string("click")), ("x", .double(p.x)), ("y", .double(p.y)), ("button", .string("left"))])
        case let .type(text):
            return .obj([("type", .string("type")), ("text", .string(text))])
        case let .key(keys):
            return .obj([("type", .string("key")), ("keys", .array(keys.map(JSONValue.string)))])
        case let .scroll(p, dir, amount):
            return .obj([("type", .string("scroll")), ("x", .double(p.x)), ("y", .double(p.y)),
                         ("direction", .string(dir.rawValue)), ("amountPixels", .int(amount))])
        }
    }

    /// For ordinary logs and events: typed text is reduced to its length.
    public var redactedDescription: String {
        switch self {
        case let .click(p): return "click \(p)"
        case let .type(text): return "type <\(text.count) chars>"
        case let .key(keys): return "key \(keys.joined(separator: "+"))"
        case let .scroll(p, dir, amount): return "scroll \(dir.rawValue) \(amount)px at \(p)"
        }
    }
}

public enum GuiProposalBody: Equatable, Sendable {
    case action(GuiAction)
    case wait(milliseconds: Int)
    /// Asks the verifier to look; it can never mark the run succeeded.
    case finish(reason: String)
    case needsUser(reasonCode: String, message: String)

    public var kindName: String {
        switch self {
        case .action: return "action"
        case .wait: return "wait"
        case .finish: return "finish"
        case .needsUser: return "needs_user"
        }
    }

    public var redactedDescription: String {
        switch self {
        case let .action(a): return a.redactedDescription
        case let .wait(ms): return "wait \(ms)ms"
        case .finish: return "finish"
        case let .needsUser(code, _): return "needs_user \(code)"
        }
    }
}

public struct GuiProposal: Equatable, Sendable {
    public let proposalId: String
    public let runId: String
    public let stepIndex: Int
    public let inferenceAttemptId: String
    public let stamp: ObservationStamp
    public let screenshotId: String
    public let provenance: AdapterProvenance
    public let body: GuiProposalBody

    public init(proposalId: String, runId: String, stepIndex: Int, inferenceAttemptId: String,
                stamp: ObservationStamp, screenshotId: String, provenance: AdapterProvenance, body: GuiProposalBody) {
        self.proposalId = proposalId; self.runId = runId; self.stepIndex = stepIndex
        self.inferenceAttemptId = inferenceAttemptId; self.stamp = stamp; self.screenshotId = screenshotId
        self.provenance = provenance; self.body = body
    }

    /// The wire form (domain.schema.json#/$defs/GuiProposal). Contains typed
    /// text for an internal execution path; use `redactedDescription` for logs.
    public var json: JSONValue {
        var m: [(String, JSONValue)] = [
            ("proposalId", .string(proposalId)), ("runId", .string(runId)),
            ("stepIndex", .int(stepIndex)), ("inferenceAttemptId", .string(inferenceAttemptId)),
            ("desktopId", .string(stamp.desktopId)), ("snapshotId", .string(stamp.snapshotId)),
            ("bindingEpoch", .int(Int(stamp.bindingEpoch))), ("runGeneration", .int(Int(stamp.runGeneration))),
            ("screenshotId", .string(screenshotId)), ("provenance", provenance.json),
            ("kind", .string(body.kindName)),
        ]
        switch body {
        case let .action(a): m.append(("action", a.json))
        case let .wait(ms): m.append(("waitMs", .int(ms)))
        case let .finish(reason): m.append(("reason", .string(reason)))
        case let .needsUser(code, message):
            m.append(("reasonCode", .string(code)))
            m.append(("message", .string(message)))
        }
        return .obj(m)
    }

    public var redactedDescription: String {
        "proposal \(proposalId) run \(runId) step \(stepIndex) snapshot \(stamp.snapshotId): \(body.redactedDescription)"
    }
}
