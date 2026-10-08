import AgentDesktopContracts
import Testing
@testable import AgentDesktopACP

// Lane Q conformance (docs/acp/tests/README.md §五). These tests use only the
// frozen model and ports (Model/ACPModel.swift, Ports.swift) and pin the
// invariants every lane must keep. The exhaustive switches below have no
// `default`: adding a case to a frozen enum stops this file from compiling,
// which is the signal to review docs/acp/tests/cases.csv with the coordinator.

/// Spellings from the ACP schema of @agentclientprotocol/sdk 1.7.0
/// (schema/types.gen.d.ts: ToolKind, ToolCallStatus, StopReason,
/// PermissionOptionKind, PlanEntryStatus).
enum QTestACPSchema {
    static let toolKinds: Set<String> = ["read", "edit", "delete", "move", "search", "execute", "think", "fetch", "switch_mode", "other"]
    static let toolStatuses: Set<String> = ["pending", "in_progress", "completed", "failed"]
    static let stopReasons: Set<String> = ["end_turn", "max_tokens", "max_turn_requests", "refusal", "cancelled"]
    static let permissionKinds: Set<String> = ["allow_once", "allow_always", "reject_once", "reject_always"]
    static let planStatuses: Set<String> = ["pending", "in_progress", "completed"]
}

@Suite("Q · approval invariants (T16, scene D)")
struct QTestApprovalConformanceTests {
    /// Every case of ACPPermissionOptionKind, by exhaustive switch.
    static func allKinds() -> [ACPPermissionOptionKind] {
        let probe: [ACPPermissionOptionKind] = [.allowOnce, .rejectOnce]
        for k in probe {
            switch k {
            case .allowOnce, .rejectOnce: break
            }
        }
        return probe
    }

    @Test func onlyOnceOptionsExist() {
        #expect(Self.allKinds().map(\.rawValue).sorted() == ["allow_once", "reject_once"])
        #expect(ACPPermissionOptionKind(rawValue: "allow_always") == nil)
        #expect(ACPPermissionOptionKind(rawValue: "reject_always") == nil)
        for k in Self.allKinds() { #expect(QTestACPSchema.permissionKinds.contains(k.rawValue)) }
    }

    @Test func aDefaultRequestOffersAllowOnceAndRejectOnce() {
        let call = ACPToolCall(toolCallId: "q1", title: "Action", kind: .execute, status: .pending)
        let r = ACPPermissionRequest(sessionId: "s", toolCall: call, summary: [])
        #expect(r.options == [.allowOnce, .rejectOnce])
    }

    /// Only `.selected(.allowOnce)` is an allow; cancelled and unavailable
    /// are refusals (README §4 rule 4, scene D).
    static func isAllow(_ o: ACPPermissionOutcome) -> Bool {
        switch o {
        case .selected(.allowOnce): return true
        case .selected(.rejectOnce): return false
        case .cancelled: return false
        case .unavailable: return false
        }
    }

    @Test func unavailableAndCancelledAreNeverAnAllow() {
        #expect(!Self.isAllow(.unavailable))
        #expect(!Self.isAllow(.cancelled))
        #expect(!Self.isAllow(.selected(.rejectOnce)))
        #expect(Self.isAllow(.selected(.allowOnce)))
        #expect(ACPPermissionOutcome.unavailable != .selected(.allowOnce))
        #expect(ACPPermissionOutcome.cancelled != .unavailable)
    }

    static func isAnswer(_ a: ACPAnswer) -> Bool {
        switch a {
        case .answered: return true
        case .declined, .unavailable: return false
        }
    }

    @Test func anUnavailableQuestionChannelIsNotAnAnswer() {
        #expect(!Self.isAnswer(.unavailable))
        #expect(!Self.isAnswer(.declined))
        #expect(ACPAnswer.answered("") != .unavailable)
    }
}

@Suite("Q · action result levels (§5.2, T11, T25)")
struct QTestActionLevelConformanceTests {
    /// Exhaustive: a new level must be placed in the display table first.
    static func displayed(_ l: ACPActionLevel) -> String {
        switch l {
        case .accepted: return "accepted"
        case .dispatched: return "dispatched"
        case .executed: return "executed"
        case .verified: return "verified"
        case .contradicted: return "contradicted"
        case .unknown: return "待核实"
        case .refused(let code): return "refused:\(code)"
        }
    }

    static let all: [ACPActionLevel] = [.accepted, .dispatched, .executed, .verified, .contradicted, .unknown, .refused(code: "x")]

    @Test func unknownExistsAndIsDistinctFromEveryOtherLevel() {
        for l in Self.all where l != .unknown {
            #expect(l != .unknown)
        }
        #expect(Self.displayed(.unknown) == "待核实")
    }

    @Test func acceptedExecutedAndVerifiedAreThreeDifferentThings() {
        #expect(ACPActionLevel.accepted != .executed)
        #expect(ACPActionLevel.executed != .verified)
        #expect(ACPActionLevel.dispatched != .executed)
        #expect(ACPActionLevel.contradicted != .verified)
        #expect(Set(Self.all.map(Self.displayed)).count == Self.all.count)
    }

    @Test func refusalsKeepTheirCode() {
        #expect(ACPActionLevel.refused(code: "policy_denied") != .refused(code: "grant_missing"))
    }

    @Test func aToolCallCarriesNoLevelAndNoDetailUnlessSet() {
        let c = ACPToolCall(toolCallId: "q", title: "t", kind: .other, status: .completed)
        #expect(c.level == nil)
        #expect(c.detail.isEmpty)
    }
}

@Suite("Q · privacy defaults (T19–T21)")
struct QTestPrivacyDefaultsConformanceTests {
    @Test func defaultsAreTheStrictest() {
        let p = ACPPrivacyPolicy()
        #expect(p.screenshots == .off)
        #expect(p.pageText == false)
    }

    @Test func disclosureLevelsAreExactlyOffSubmitAll() {
        let all: [ACPDisclosure] = [.off, .onSubmit, .all]
        for d in all {
            switch d {
            case .off, .onSubmit, .all: break
            }
        }
        #expect(all.map(\.rawValue) == ["off", "submit", "all"])
    }
}

@Suite("Q · capability honesty (T05)")
struct QTestCapabilityConformanceTests {
    @Test func agentCapabilitiesClaimNothingByDefault() {
        let a = ACPAgentCapabilities()
        #expect(!a.resumeSessions && !a.listSessions && !a.closeSessions && !a.promptImages && !a.promptEmbeddedContext)
    }

    @Test func clientCapabilitiesAssumeNothingByDefault() {
        let c = ACPClientCapabilities()
        #expect(!c.readTextFile && !c.writeTextFile && !c.terminal && !c.elicitation)
    }

    @Test func versionsAreV1AndV2Only() {
        #expect(ACPVersion.allCases.map(\.rawValue) == ["v1", "v2"])
    }
}

@Suite("Q · wire spellings match the ACP schema")
struct QTestSpellingConformanceTests {
    @Test func toolKindsAreSchemaKindsAndNeverFileEdits() {
        let kinds: [ACPToolKind] = [.read, .execute, .other, .think, .fetch, .search]
        for k in kinds {
            switch k {
            case .read, .execute, .other, .think, .fetch, .search: break
            }
            #expect(QTestACPSchema.toolKinds.contains(k.rawValue))
        }
        // AgentDesktop never presents an action as a file edit.
        for spelling in ["edit", "delete", "move", "switch_mode"] {
            #expect(ACPToolKind(rawValue: spelling) == nil)
        }
    }

    @Test func toolStatusesStopReasonsAndPlanStatusesAreSchemaSpellings() {
        let statuses: [ACPToolStatus] = [.pending, .inProgress, .completed, .failed]
        for s in statuses {
            switch s {
            case .pending, .inProgress, .completed, .failed: break
            }
        }
        #expect(Set(statuses.map(\.rawValue)) == QTestACPSchema.toolStatuses)

        let reasons: [ACPStopReason] = [.endTurn, .cancelled, .refusal, .maxTurnRequests]
        for r in reasons {
            switch r {
            case .endTurn, .cancelled, .refusal, .maxTurnRequests: break
            }
            #expect(QTestACPSchema.stopReasons.contains(r.rawValue))
        }

        let plan: [ACPPlanEntry.Status] = [.pending, .inProgress, .completed]
        #expect(Set(plan.map(\.rawValue)) == QTestACPSchema.planStatuses)
    }
}

@Suite("Q · submission receipts (T10, T11)")
struct QTestReceiptConformanceTests {
    enum QTestNextStep: Equatable { case follow, query, explainRefusal }

    /// What the server does with each receipt. No case leads to a resend.
    static func next(_ r: ACPSubmissionReceipt) -> QTestNextStep {
        switch r {
        case .accepted: return .follow
        case .duplicate: return .follow
        case .refused: return .explainRefusal
        case .unconfirmed: return .query
        }
    }

    @Test func anUnconfirmedSubmissionIsQueriedNotResent() {
        #expect(Self.next(.unconfirmed) == .query)
        let run = ACPRunSnapshot(runId: "r1", phase: "running", outcome: nil, quiescence: "not_confirmed", lifetime: "connection_scoped")
        #expect(Self.next(.duplicate(run)) == .follow)
        #expect(ACPSubmissionReceipt.duplicate(run) != .accepted(run))
        #expect(ACPSubmissionReceipt.unconfirmed != .refused(code: "", message: ""))
    }
}

@Suite("Q · connection events (T03, T14)")
struct QTestConnectionEventConformanceTests {
    @Test func losingTheConnectionIsItsOwnEvent() {
        let e = ACPConnectionEvent.closed(reason: "eof")
        switch e {
        case .closed: break
        case .request, .notification: Issue.record("closed must stay a separate event")
        }
        #expect(e != .notification(.cancel(sessionId: "s")))
    }

    @Test func everyIncomingRequestKindIsKnown() {
        let all: [ACPIncoming] = [
            .initialize(client: nil, capabilities: ACPClientCapabilities(), requested: "1"),
            .newSession(cwd: "/"), .listSessions, .resumeSession(sessionId: "s"), .closeSession(sessionId: "s"),
            .prompt(sessionId: "s", content: [.text("x")]), .cancel(sessionId: "s"),
            .setConfigOption(sessionId: "s", optionId: "mode", value: "ask"),
        ]
        for i in all {
            switch i {
            case .initialize, .newSession, .listSessions, .resumeSession, .closeSession, .prompt, .cancel, .setConfigOption: break
            }
        }
        #expect(all.count == 8)
    }
}

@Suite("Q · identity (T07, README §4 rule 3)")
struct QTestIdentityConformanceTests {
    /// Until A4 the bridge only has a local-owner placeholder; a caller is
    /// unverified unless the Runtime says otherwise.
    @Test func aCallerIsUnverifiedByDefault() {
        let c = ACPCaller(principalId: "p", clientId: "c", connectionId: "k")
        #expect(c.verified == false)
        #expect(c != ACPCaller(principalId: "p", clientId: "c", connectionId: "k", verified: true))
    }

    @Test func aSnapshotDoesNotInventACursor() {
        let s = ACPRunSnapshot(runId: "r", phase: "running", outcome: nil, quiescence: "not_confirmed", lifetime: "connection_scoped")
        #expect(s.lastCursor == nil)
    }
}

@Suite("Q · request ids")
struct QTestRequestIdConformanceTests {
    @Test func stringAndNumberIdsNeverCollide() {
        #expect(ACPRequestId(.string("7")) != ACPRequestId(.number(raw: "7", value: 7)))
        let set: Set<ACPRequestId> = [ACPRequestId(.string("7")), ACPRequestId(.number(raw: "7", value: 7)), ACPRequestId(.string("7"))]
        #expect(set.count == 2)
    }

    /// Hashable requires equal values to hash equally. JSONValue compares
    /// numbers by value but ACPRequestId hashes the raw spelling, so 1 and
    /// 1.0 are equal yet hash apart. Reported to the coordinator as an
    /// interface request (PR body); flip to a plain #expect once fixed.
    @Test func equalNumericIdsHashEqually() {
        let a = ACPRequestId(.number(raw: "1", value: 1))
        let b = ACPRequestId(.number(raw: "1.0", value: 1))
        #expect(a == b)
        withKnownIssue("ACPRequestId.hash uses the raw spelling; == uses the numeric value") {
            #expect(a.hashValue == b.hashValue)
        }
    }
}
