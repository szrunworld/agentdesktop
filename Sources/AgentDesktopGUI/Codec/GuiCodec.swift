import AgentDesktopProtocol
import Foundation

/// What a codec needs to read one model reply. Everything here comes from
/// the Runtime's observation and the run's bound profile, never from the
/// model's text.
public struct CodecContext: Sendable {
    /// The screenshot the model was shown; its transform maps coordinates.
    public let transform: ScreenshotTransform
    /// The bound profile's `limits.maxWaitMs`.
    public let maxWaitMs: Int

    public init(transform: ScreenshotTransform, maxWaitMs: Int) {
        self.transform = transform
        self.maxWaitMs = maxWaitMs
    }
}

/// One reply, decoded: exactly one suggestion, coordinates already in
/// source screenshot pixels.
public struct DecodedSuggestion: Equatable, Sendable {
    public let body: GuiProposalBody
    /// The model's reasoning text, for diagnostics only. Never parsed for
    /// actions or fields.
    public let thought: String?
}

/// Turns a complete model reply into one suggestion. A codec holds no
/// screen, input engine, window or capture capability: it is pure.
public protocol GuiActionCodec: Sendable {
    var provenance: AdapterProvenance { get }
    func decode(_ modelOutput: String, context: CodecContext) throws -> DecodedSuggestion
}

enum CodecLimits {
    /// Longest reply a codec reads (the transport already caps bodies at 2 MiB).
    static let maxReplyScalars = 140_000
    static let maxReasonLength = 512
    static let maxReasonCodeLength = 96
}

func invalidAction(_ message: String) -> ContractError {
    ContractError(.invalidAction, message)
}

/// Shared checks on a decoded body, so both codecs enforce the same rules.
enum SuggestionRules {
    static func checkType(_ text: String) throws {
        guard text.count <= GuiAction.maxTypeLength else { throw invalidAction("type text is longer than \(GuiAction.maxTypeLength)") }
        for s in text.unicodeScalars where s.properties.generalCategory == .control && s != "\n" && s != "\t" {
            throw invalidAction("type text holds a control character")
        }
    }

    static func checkKeys(_ keys: [String]) throws {
        guard (1...GuiKeys.maxKeys).contains(keys.count) else { throw invalidAction("key needs 1 to \(GuiKeys.maxKeys) keys") }
        guard Set(keys).count == keys.count else { throw invalidAction("key repeats a key") }
        for k in keys where !GuiKeys.isValid(k) { throw invalidAction("key \"\(k)\" is not allowed") }
    }

    static func checkWait(_ ms: Int, max: Int) throws {
        guard ms >= 0 else { throw invalidAction("wait must not be negative") }
        guard ms <= max, ms <= 5000 else { throw ContractError(.limitExceeded, "wait is longer than \(min(max, 5000))ms") }
    }

    static func checkReason(_ s: String, _ what: String, max: Int = CodecLimits.maxReasonLength) throws {
        guard !s.isEmpty, s.count <= max else { throw invalidAction("\(what) must be 1 to \(max) characters") }
    }
}

/// Picks the codec for a bound profile. The fixture adapter exists only for
/// test builds and test mode: with `fixtureAdapterEnabled` false (the
/// production default) it is refused like an unknown adapter.
public struct GuiCodecRegistry: Sendable {
    public let fixtureAdapterEnabled: Bool

    public init(fixtureAdapterEnabled: Bool = false) {
        self.fixtureAdapterEnabled = fixtureAdapterEnabled
    }

    public var availableAdapters: [GuiAdapterId] {
        fixtureAdapterEnabled ? [.uitarsV1, .fixtureJsonV1] : [.uitarsV1]
    }

    public func codec(adapterId: String, coordinateProtocol: String?) throws -> GuiActionCodec {
        let proto = try CoordinateMapper.coordinateProtocol(coordinateProtocol)
        switch GuiAdapterId(rawValue: adapterId) {
        case .uitarsV1?:
            return UITarsCodec(coordinateProtocol: proto)
        case .fixtureJsonV1? where fixtureAdapterEnabled:
            return FixtureJsonCodec(coordinateProtocol: proto)
        case .fixtureJsonV1?:
            throw ContractError(.capabilityMismatch, "fixture_json_v1 is only available in test mode")
        case nil:
            throw ContractError(.capabilityMismatch, "GUI adapter is not supported by this build")
        }
    }
}
