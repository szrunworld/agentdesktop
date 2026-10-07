import AgentDesktopContracts
import Foundation

/// fixture_json_v1: a neutral, strictly-JSON suggestion format for tests and
/// the synthetic capability service. Only `GuiCodecRegistry` with
/// `fixtureAdapterEnabled` hands it out.
///
/// One object, exactly one of:
///   {"kind":"action","action":{…ClickAction|TypeAction|KeyAction|ScrollAction…}}
///   {"kind":"wait","waitMs":N}
///   {"kind":"finish","reason":"…"}
///   {"kind":"needs_user","reasonCode":"…","message":"…"}
/// Coordinates are in the profile's coordinate protocol on the model canvas.
public struct FixtureJsonCodec: GuiActionCodec {
    public static let adapterVersion = "1.0.0"
    public static let promptVersion = "fixture-prompt-1"
    public static let parserVersion = "fixture-parser-1"

    public let provenance: AdapterProvenance

    public init(coordinateProtocol: CoordinateProtocol) {
        provenance = AdapterProvenance(adapterId: .fixtureJsonV1, adapterVersion: Self.adapterVersion,
                                       promptVersion: Self.promptVersion, parserVersion: Self.parserVersion,
                                       coordinateProtocol: coordinateProtocol)
    }

    public func decode(_ modelOutput: String, context: CodecContext) throws -> DecodedSuggestion {
        guard modelOutput.unicodeScalars.count <= CodecLimits.maxReplyScalars else { throw invalidAction("reply is too long") }
        let v: JSONValue
        do { v = try StrictJSON.parse(modelOutput) } catch { throw invalidAction("reply is not one strict JSON object") }
        guard let members = v.objectMembers else { throw invalidAction("reply is not a JSON object") }
        let keys = Set(members.map(\.key))
        func exactly(_ allowed: Set<String>) throws {
            guard keys == allowed else { throw invalidAction("suggestion members must be exactly \(allowed.sorted())") }
        }
        switch v["kind"]?.stringValue {
        case "action":
            try exactly(["kind", "action"])
            return DecodedSuggestion(body: .action(try action(v["action"]!, context)), thought: nil)
        case "wait":
            try exactly(["kind", "waitMs"])
            guard let ms = v["waitMs"]?.intValue else { throw invalidAction("waitMs must be an integer") }
            try SuggestionRules.checkWait(ms, max: context.maxWaitMs)
            return DecodedSuggestion(body: .wait(milliseconds: ms), thought: nil)
        case "finish":
            try exactly(["kind", "reason"])
            guard let r = v["reason"]?.stringValue else { throw invalidAction("reason must be a string") }
            try SuggestionRules.checkReason(r, "finish reason")
            return DecodedSuggestion(body: .finish(reason: r), thought: nil)
        case "needs_user":
            try exactly(["kind", "reasonCode", "message"])
            guard let code = v["reasonCode"]?.stringValue, let msg = v["message"]?.stringValue else {
                throw invalidAction("reasonCode and message must be strings")
            }
            try SuggestionRules.checkReason(code, "reasonCode", max: CodecLimits.maxReasonCodeLength)
            try SuggestionRules.checkReason(msg, "needs_user message")
            return DecodedSuggestion(body: .needsUser(reasonCode: code, message: msg), thought: nil)
        default:
            throw invalidAction("unknown suggestion kind")
        }
    }

    func action(_ a: JSONValue, _ context: CodecContext) throws -> GuiAction {
        // Shape first, by the contract's own GuiAction definition.
        let shape = try ContractBundle.shared.validateDomain(a, "GuiAction")
        guard shape.isEmpty else { throw invalidAction("action does not match the contract") }
        func source() throws -> Point {
            let raw = Point(x: a["x"]!.doubleValue!, y: a["y"]!.doubleValue!)
            return try CoordinateMapper.sourcePixel(fromModel: raw, protocol: provenance.coordinateProtocol,
                                                    transform: context.transform)
        }
        switch a["type"]?.stringValue {
        case "click":
            return .click(sourcePixel: try source())
        case "type":
            let text = a["text"]!.stringValue!
            try SuggestionRules.checkType(text)
            return .type(text: text)
        case "key":
            let keys = a["keys"]!.arrayValue!.compactMap(\.stringValue)
            try SuggestionRules.checkKeys(keys)
            return .key(keys: keys)
        case "scroll":
            return .scroll(sourcePixel: try source(), direction: ScrollDirection(rawValue: a["direction"]!.stringValue!)!,
                           amountPixels: a["amountPixels"]!.intValue!)
        default:
            throw invalidAction("unknown action type")
        }
    }
}
