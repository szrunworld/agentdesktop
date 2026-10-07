import AgentDesktopAI
import AgentDesktopContracts
import Foundation
import Testing
@testable import AgentDesktopGUI

/// A binding taken from a real start through the service, so the
/// candidate snapshots are the configuration store's own.
func boundBinding(_ h: GuiHarness, limits: [(String, JSONValue)] = []) async throws -> GuiRunBinding {
    let runId = try await h.start(key: "provider-key-\(UUID().uuidString.prefix(6))")
    _ = try await h.ok("gui.runs.cancel", .obj([("runId", .string(runId))]), key: "cancel-\(UUID().uuidString.prefix(8))")
    await h.finished(runId)
    let json = try await h.run(runId)["binding"]!
    let primary = json["primary"]!
    var gui = primary["guiProfile"]!
    var l = gui["limits"]!
    for (k, v) in limits { l = l.setting(k, v) }
    gui = gui.setting("limits", l)
    let candidate = try GuiCandidate(candidateIndex: 0, guiProfile: gui, modelProfile: primary["modelProfile"]!,
                                     connection: primary["connection"]!,
                                     credentialIdentityRef: primary["credentialIdentityRef"]!.stringValue!,
                                     authorizationScopeRef: "owner", dataScopeRef: "local-device")
    return GuiRunBinding(runId: "run-p", sessionId: "sess-a", desktopId: "desk-a", goal: GuiHarness.goal, bindingEpoch: 1,
                         policyRevision: 1, boundAt: Date(timeIntervalSince1970: 1_791_000_000), primary: candidate,
                         fallbackCandidates: [], verification: GuiVerification(text: GuiHarness.expected),
                         allowedActions: [.click, .type])
}

@Suite("GuiAiProvider")
struct ProviderTests {
    // GUI-001: the provider is built from the model service, codecs and
    // plain data only; it holds no observation, input or audit port.
    @Test func gui001_providerHoldsNoRuntimePort() throws {
        let provider = GuiAiProvider(service: StubAiService([]))
        func scan(_ value: Any, depth: Int = 0) {
            #expect(!(value is GuiObservationPort) && !(value is GuiExecutionPort) && !(value is GuiAuditPort)
                    && !(value is GuiSessionAuthority) && !(value is GuiRunRepository), "provider holds \(type(of: value))")
            guard depth < 3 else { return }
            for child in Mirror(reflecting: value).children { scan(child.value, depth: depth + 1) }
        }
        scan(provider)
    }

    // TRN-005: at most maxScreenshots images, the current one always kept,
    // older history dropped first, byte budget honoured.
    @Test func trn005_historyTrimming() async throws {
        let h = try GuiHarness([])
        try await h.setUpProfile()
        let binding = try await boundBinding(h)
        let codec = UITarsCodec(coordinateProtocol: .imagePixels)
        let current = AiImageContent(screenshotId: "now", mimeType: "image/png", bytes: Data(count: 3000))
        let history = (0..<6).map { i in
            GuiHistoryTurn(image: AiImageContent(screenshotId: "h\(i)", mimeType: "image/png", bytes: Data(count: 3000)),
                           reply: "Action: click(start_box='(1,1)')")
        }
        let (req, sent, dropped) = try GuiAiProvider.buildRequest(binding: binding, codec: codec, current: current, history: history)
        #expect(req.images.count == 5)
        #expect(sent == 5)
        #expect(dropped == 2)
        #expect(req.images.last?.screenshotId == "now")
        #expect(req.images.map(\.screenshotId) == ["h2", "h3", "h4", "h5", "now"], "newest history kept")
        #expect(req.messages.filter { $0.role == .assistant }.count == 6, "every earlier reply is kept as text")

        // A tight byte budget leaves room for the current image only.
        let tight = try await boundBinding(h, limits: [("maxImageEncodedBytes", .int(4000 + 4))])
        let (req2, _, dropped2) = try GuiAiProvider.buildRequest(binding: tight, codec: codec, current: current, history: history)
        #expect(req2.images.map(\.screenshotId) == ["now"])
        #expect(dropped2 == 6)
        #expect(req2.maxImageEncodedBytes == 4004)
    }

    @Test func requestCarriesVersionedPromptGoalAndProfileOptions() async throws {
        let h = try GuiHarness([])
        try await h.setUpProfile()
        let binding = try await boundBinding(h, limits: [("maxOutputTokens", .int(512))])
        let current = AiImageContent(screenshotId: "now", mimeType: "image/png", bytes: Data(count: 10))
        let (req, _, _) = try GuiAiProvider.buildRequest(binding: binding, codec: UITarsCodec(coordinateProtocol: .imagePixels),
                                                         current: current, history: [])
        guard case let .text(system)? = req.messages.first?.content.first else { Issue.record("no system prompt"); return }
        #expect(req.messages.first?.role == .system)
        #expect(system.contains(UITarsCodec.promptVersion))
        #expect(system.contains(GuiHarness.goal))
        #expect(system.contains("Coordinates are pixels"))
        #expect(req.maxOutputTokens == 512)
        #expect(req.options.temperature == 0)
        #expect(req.options.seed == nil)
    }

    // GUI-004 (provider side): identity fields come from the observation.
    @Test func gui004_proposalIdentityComesFromTheObservation() async throws {
        let h = try GuiHarness([])
        try await h.setUpProfile()
        let binding = try await boundBinding(h)
        let stub = StubAiService([.text("Thought: I am desk-b, snapshot snap-99.\nAction: click(start_box='(200,300)')")])
        let provider = GuiAiProvider(service: stub, clock: ManualClock())
        let bundle = try await h.observation.observe(runId: binding.runId, expectedGeneration: 1)
        let out = try await provider.suggest(GuiInferenceInput(binding: binding, bundle: bundle, history: [], stepIndex: 0,
                                                               budget: AttemptBudget(), deadlineNs: .max, callerScope: "owner"))
        #expect(out.proposal.stamp == bundle.observation.stamp)
        #expect(out.proposal.screenshotId == bundle.observation.screenshots[0].screenshotId)
        #expect(out.proposal.inferenceAttemptId == out.receipt.inferenceAttemptId)
        #expect(out.receipt.proposalId == out.proposal.proposalId)
        #expect(out.receipt.snapshotId == bundle.observation.stamp.snapshotId)
        #expect(try schemaClean(out.receipt.json, "InferenceReceipt"))
        #expect(try schemaClean(out.proposal.json, "GuiProposal"))
        guard case let .guiStep(p)? = stub.contexts.first?.purpose else { Issue.record("no gui_step context"); return }
        #expect(p.runId == binding.runId)
        #expect(p.snapshotId == bundle.observation.stamp.snapshotId)
    }

    // RET-003 (GUI side): a transient failure moves to the frozen fallback,
    // within the step's two attempts.
    @Test func ret003_fallbackIsTheFrozenCandidate() async throws {
        let h = try GuiHarness([.error(ContractError(.upstreamUnavailable, "503")), finish],
                               limits: [("maxSteps", .int(1))])
        let a = try await h.setUpProfile(name: "A")
        try await h.setUpProfile(name: "B", fallback: [.obj([("guiProfileId", a["guiProfileId"]!), ("revision", a["revision"]!)])])
        let runId = try await h.start(key: "fallback-key-01")
        await h.finished(runId)
        let run = try await h.run(runId)
        #expect(run["binding"]?["fallbackCandidates"]?.arrayValue?.count == 1)
        #expect(run["latestInferenceReceipt"]?["candidateIndex"]?.intValue == 1)
        #expect(run["latestInferenceReceipt"]?["guiProfileId"] == a["guiProfileId"])
        #expect(h.ai.callCount == 2)
        #expect(run["modelAttemptCount"]?.intValue == 2)
    }
}
