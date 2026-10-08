import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopACP

// Lane Q, layer L1: the event catalogue frozen on main by #102 (F1-01,
// runtime.schema.json `PlatformRunEvent`) against what the ACP projector
// knows (ACPEventCatalog.swift) and how it shows each catalogued event.
// Conformance only: the samples below are validated against the contract
// first, so a failure here is a projector/catalogue mismatch, not a bad
// fixture. Written against #102 before #114 landed; after merging #114
// (projector aligned to the catalogue) every check holds without a known
// issue (docs/acp/tests/README.md §4.8).

enum QTestCatalog {
    /// Every `type` value the contract allows in `PlatformRunEvent`.
    static let types: [String] = {
        guard let schema = try? StrictJSON.parse(Data(RuntimeContract.embedded.schema.utf8)),
              let alts = schema["$defs"]?["PlatformRunEvent"]?["oneOf"]?.arrayValue else { return [] }
        var out: [String] = []
        for alt in alts {
            let t = alt["properties"]?["type"]
            if let c = t?["const"]?.stringValue { out.append(c) }
            for v in t?["enum"]?.arrayValue ?? [] { if let s = v.stringValue { out.append(s) } }
        }
        return out
    }()

    static let secret = "QTEST-SECRET 王小明 13800138000"
    static let run = "run_0a1b2c3d4e5f"
    static let req = "req_0001aaaabbbb"

    static let target: JSONValue = .obj([
        ("generation", .int(1)), ("process", .obj([("pid", .int(4242)), ("startedAt", .string("2026-10-08T12:00:00.000Z"))])),
        ("windowId", .int(813)), ("elementRef", .string("el_7")), ("point", .null)])

    static func receipt(delivery: String, execution: String, reason: Bool) -> JSONValue {
        var m: [(String, JSONValue)] = [
            ("receiptId", .string("rcpt_00aa11bb22cc")), ("requestId", .string(req)), ("runId", .string(run)),
            ("desktopId", .string("desk_000000aaaaaa")), ("sessionId", .string("sess_000000bbbbbb")),
            ("snapshotId", .string("snap_000000cccccc")), ("delivery", .string(delivery)), ("execution", .string(execution)),
            ("verification", .string("not_requested")), ("businessResult", .string("not_evaluated")),
        ]
        if reason { m.append(("reason", .obj([("code", .string("action_delivery_unknown")), ("message", .string(secret))]))) }
        m += [("route", .string("ax")), ("target", target),
              ("timing", .obj([("acceptedAt", .string("2026-10-08T12:00:00.000Z")),
                               ("dispatchedAt", .string("2026-10-08T12:00:00.120Z")),
                               ("completedAt", .string("2026-10-08T12:00:00.350Z"))]))]
        return .obj(m)
    }

    /// The whole RunEvent as runtime/1 writes it (and as the bridge delivers
    /// it since R2: the whole event as payload).
    static func event(_ type: String, _ data: [(String, JSONValue)], seq: Int) -> (ACPRuntimeEvent, JSONValue) {
        let whole = JSONValue.obj([("runId", .string(run)), ("sequence", .int(seq)), ("at", .string("2026-10-08T12:00:0\(seq % 10).000Z")),
                                   ("type", .string(type)), ("data", .obj(data))])
        return (ACPRuntimeEvent(runId: run, cursor: seq, type: type, payload: whole), whole)
    }

    /// One contract-valid sample of every catalogued type, in Run order.
    static func samples(runEnded outcome: String = "unknown") -> [(String, ACPRuntimeEvent, JSONValue)] {
        var seq = 0
        func e(_ type: String, _ data: [(String, JSONValue)]) -> (String, ACPRuntimeEvent, JSONValue) {
            seq += 1
            let (ev, whole) = event(type, data, seq: seq)
            return (type, ev, whole)
        }
        return [
            e("run.started", [("kind", .string("act")), ("origin", .string("agent_hub")), ("ownership", .string("external_client")),
                              ("lifetime", .string("connection_scoped")), ("desktopId", .string("desk_000000aaaaaa")),
                              ("sessionId", .string("sess_000000bbbbbb"))]),
            e("action.accepted", [("requestId", .string(req)), ("kind", .string("click"))]),
            e("action.dispatched", [("requestId", .string(req))]),
            e("action.completed", [("receipt", receipt(delivery: "dispatched", execution: "completed", reason: false))]),
            e("action.failed", [("receipt", receipt(delivery: "not_dispatched", execution: "failed", reason: true))]),
            e("action.unknown", [("receipt", receipt(delivery: "unknown", execution: "unknown", reason: true))]),
            e("action.refused", [("requestId", .string(req)),
                                 ("reason", .obj([("code", .string("stale_observation")), ("message", .string(secret))]))]),
            e("stop.accepted", [("reason", .string("cancel_requested")), ("inFlight", .bool(true)), ("revision", .int(3))]),
            e("run.finishing", [("reason", .string("cancel_requested")), ("inFlight", .bool(false)), ("revision", .int(4))]),
            e("run.quiescent", [("revision", .int(5))]),
            e("run.ended", [("phase", .string("ended")), ("outcome", .string(outcome)), ("reason", .string("owner_lost"))]),
        ]
    }

    static func calls(_ ups: [ACPSessionUpdate]) -> [ACPToolCall] {
        ups.compactMap { u -> ACPToolCall? in
            switch u {
            case let .toolCall(c), let .toolCallUpdate(c): return c
            default: return nil
            }
        }
    }

    static func text(_ ups: [ACPSessionUpdate]) -> String { ups.map { String(describing: $0) }.joined(separator: "\n") }
}

@Suite("Q · L1 conformance: #102 event catalogue vs the ACP projector")
struct QTestEventCatalogConformanceTests {
    @Test func theCatalogueIsReadFromTheEmbeddedContract() {
        // Guard against an empty pass: #102 froze 11 types.
        #expect(QTestCatalog.types.count >= 11, "\(QTestCatalog.types)")
        #expect(Set(QTestCatalog.types).count == QTestCatalog.types.count)
    }

    /// Every type the Runtime may write on a Run is one the projector knows
    /// (else it falls to the neutral "unrecognised" line).
    @Test func everyCatalogueTypeIsKnownToTheProjector() {
        for t in QTestCatalog.types {
            #expect(ACPEventType(rawValue: t) != nil, "\(t) is in PlatformRunEvent but not in ACPEventType")
        }
    }

    /// And the other way: ACP knows no type outside the catalogue (#114
    /// retired the provisional names), so the enum is exactly the catalogue.
    @Test func theProjectorKnowsExactlyTheCatalogue() {
        #expect(Set(ACPEventType.allCases.map(\.rawValue)) == Set(QTestCatalog.types))
    }

    /// The samples are contract-valid, and each projects to something
    /// specific (never the neutral "unrecognised" line), with the tier the
    /// catalogue implies.
    @Test func everyCataloguedEventProjects() {
        let samples = QTestCatalog.samples()
        #expect(Set(samples.map(\.0)) == Set(QTestCatalog.types), "samples do not cover the catalogue")
        var ctx = ACPEventContext()
        let p = ACPProjector()
        for (type, ev, whole) in samples {
            let v = RuntimeContract.shared.validate(whole, "PlatformRunEvent")
            #expect(v.isEmpty, "sample \(type) is not contract-valid: \(v.prefix(3))")
            let ups = p.project(ev, policy: ACPPrivacyPolicy(), context: ctx)
            ctx.absorb(ev)
            #expect(!ups.isEmpty, "\(type) projects to nothing")
            #expect(!QTestCatalog.text(ups).contains("未识别"), "\(type) shown as unrecognised")
        }
    }

    /// Free text the Runtime puts in FailureReason.message (and in receipt
    /// reasons) never reaches the editor under the default policy.
    @Test func failureReasonMessagesDoNotLeak() {
        var ctx = ACPEventContext()
        let p = ACPProjector()
        for (type, ev, _) in QTestCatalog.samples() {
            let ups = p.project(ev, policy: ACPPrivacyPolicy(), context: ctx)
            ctx.absorb(ev)
            let t = QTestCatalog.text(ups)
            for needle in ["QTEST-SECRET", "王小明", "13800138000"] {
                #expect(!t.contains(needle), "\(type): \(needle) reached the editor")
            }
        }
    }

    /// ACP-T11-01 on catalogue-valid events: action.unknown is shown as
    /// "待核实" — neither completed nor failed — while the Run is active; a
    /// refused or failed action is never completed.
    @Test func resultLevelsFollowTheReceipt() throws {
        var ctx = ACPEventContext()
        let p = ACPProjector()
        var byType: [String: [ACPToolCall]] = [:]
        for (type, ev, _) in QTestCatalog.samples() {
            byType[type] = QTestCatalog.calls(p.project(ev, policy: ACPPrivacyPolicy(), context: ctx))
            ctx.absorb(ev)
        }
        let unknown = try #require(byType["action.unknown"]?.last, "action.unknown shows no tool call")
        #expect(unknown.level == .unknown)
        #expect(unknown.status != .completed && unknown.status != .failed, "unknown shown as \(unknown.status)")
        #expect(unknown.title.contains("待核实") || unknown.detail.joined().contains("待核实"), "\(unknown)")
        for t in ["action.failed", "action.refused"] {
            let c = try #require(byType[t]?.last, "\(t) shows no tool call")
            #expect(c.status != .completed, "\(t) shown completed")
        }
        let done = try #require(byType["action.completed"]?.last)
        #expect(done.level == .executed, "delivered+completed is executed, not verified: \(String(describing: done.level))")
    }

    /// action.refused carries `reason{code,message}` (#102). The editor should
    /// see the code (here stale_observation), not a generic fallback.
    @Test func refusedShowsTheCataloguedReasonCode() throws {
        var ctx = ACPEventContext()
        let p = ACPProjector()
        var refused: ACPToolCall?
        for (type, ev, _) in QTestCatalog.samples() {
            let c = QTestCatalog.calls(p.project(ev, policy: ACPPrivacyPolicy(), context: ctx))
            ctx.absorb(ev)
            if type == "action.refused" { refused = c.last }
        }
        let c = try #require(refused)
        #expect(c.level == .refused(code: "stale_observation"), "\(String(describing: c.level))")
    }

    /// Every run.ended outcome the catalogue allows projects; unknown says so
    /// and nothing but success reads as success.
    @Test func everyRunEndedOutcomeProjects() {
        for outcome in ["success", "failed", "cancelled", "unknown"] {
            let (ev, whole) = QTestCatalog.event("run.ended", [("phase", .string("ended")), ("outcome", .string(outcome)),
                                                               ("reason", .string("owner_lost"))], seq: 9)
            #expect(RuntimeContract.shared.validate(whole, "PlatformRunEvent").isEmpty)
            let t = QTestCatalog.text(ACPProjector().project(ev, policy: ACPPrivacyPolicy()))
            #expect(!t.isEmpty)
            #expect(t.contains("编辑器连接已断开"), "\(outcome): closing reason owner_lost not shown: \(t)")
            if outcome == "unknown" { #expect(t.contains("结果未知"), "unknown: \(t)") }
            if outcome != "success" { #expect(!t.contains("任务已完成"), "\(outcome) reads as success: \(t)") }
        }
    }

    /// A type outside the catalogue (reserved prefix) is protected: a neutral
    /// line, nothing of its payload.
    @Test func aTypeOutsideTheCatalogueShowsNoPayload() {
        for type in ["unit.qtest_future", "approval.qtest_future", "qtest.unknown"] {
            #expect(ACPEventType.tier(of: type) == .protected)
            let (ev, _) = QTestCatalog.event(type, [("title", .string(QTestCatalog.secret)), ("text", .string(QTestCatalog.secret))], seq: 1)
            let t = QTestCatalog.text(ACPProjector().project(ev, policy: ACPPrivacyPolicy()))
            #expect(!t.contains("QTEST-SECRET") && !t.contains("王小明"), "\(type): \(t)")
        }
    }
}
