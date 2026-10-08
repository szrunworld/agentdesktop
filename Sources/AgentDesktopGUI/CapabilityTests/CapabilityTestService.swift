import AgentDesktopAI
import AgentDesktopProtocol
import Foundation

/// `ai.tests.start` (spec §11, §18.1, TRN-008): four layers against one GUI
/// profile revision, using only the synthetic fixture.
///
/// - network: a plain GET of the base URL; any HTTP answer means reachable.
/// - auth_model: one tiny text call.
/// - image_input: the two-colour image and a question with one right answer.
/// - gui_contract: the one-button screen; the reply must decode with the
///   profile's codec into a click inside the button.
///
/// A layer runs only when the one before it passed; later layers are
/// skipped, never guessed. At most three model calls per operation, no
/// hidden retries, one 120 s deadline. Every call goes through the shared
/// `AiService`, so it is reserved in the ledger and counted in usage.
///
/// The service holds no observation, capture or input port: a capability
/// test can never act on a desktop (`performedDesktopInput` is always false).
public final class CapabilityTestService: Sendable {
    public static let deadlineMs = 120_000
    public static let maxModelCalls = 3

    let store: ConfigStore
    let ai: AiService
    let http: HTTPTransport
    let runner: AiOperationRunner
    let codecs: GuiCodecRegistry
    let clock: MonotonicClock

    public init(store: ConfigStore, ai: AiService, http: HTTPTransport, runner: AiOperationRunner,
                codecs: GuiCodecRegistry = GuiCodecRegistry(), clock: MonotonicClock = SystemMonotonicClock()) {
        self.store = store
        self.ai = ai
        self.http = http
        self.runner = runner
        self.codecs = codecs
        self.clock = clock
    }

    public func handlers(callerScope: String) -> [String: ServiceHandler] {
        ["ai.tests.start": { req in try await self.start(req, callerScope: callerScope) }]
    }

    /// Create the operation (once per idempotency key) and start its work.
    public func start(_ req: ServiceRequest, callerScope: String) async throws -> JSONValue {
        let p = req.params
        let profileId = p["guiProfileId"]?.stringValue ?? ""
        let revision = p["expectedRevision"]?.intValue ?? 0
        let codecs = self.codecs
        let result = try await store.runIdempotent(scope: callerScope, command: req.method, key: req.idempotencyKey,
                                                   semantic: p) { store in
            let resolved = try store.resolveGuiProfile(profileId, revision: revision, callerScope: callerScope)
            _ = try codecs.codec(adapterId: resolved.adapterId, coordinateProtocol: resolved.coordinateProtocol)
            let op = try store.createOperation(kind: .capabilityTest, callerScope: callerScope,
                                               resourceId: profileId, resourceRevision: revision)
            return .obj([("operationId", .string(op)), ("state", .string("queued"))])
        }
        if let op = result["operationId"]?.stringValue {
            await runner.start(op) {
                await self.run(operationId: op, profileId: profileId, revision: revision, callerScope: callerScope)
            }
        }
        return result
    }

    enum Level: String, CaseIterable {
        case network
        case authModel = "auth_model"
        case imageInput = "image_input"
        case guiContract = "gui_contract"

        var layer: CapabilityLayer {
            switch self {
            case .network: return .network
            case .authModel: return .authModel
            case .imageInput: return .imageInput
            case .guiContract: return .guiContract
            }
        }

        var modelLevel: CapabilityModelTestLevel? {
            switch self {
            case .network: return nil
            case .authModel: return .authModel
            case .imageInput: return .imageInput
            case .guiContract: return .guiContract
            }
        }
    }

    struct LevelOutcome {
        var status: String       // passed, failed, skipped
        var latencyMs: Int?
        var reasonCode: String?
        var httpStatus: Int?
        var error: ContractError?

        static let skipped = LevelOutcome(status: "skipped")

        var json: (String) -> JSONValue {
            { level in
                .obj([
                    ("level", .string(level)), ("status", .string(self.status)),
                    ("latencyMs", self.latencyMs.map { .int(min(max($0, 0), 120_000)) } ?? .null),
                    ("reasonCode", self.reasonCode.map { .string(String($0.prefix(96))) } ?? .null),
                    ("httpStatus", self.httpStatus.flatMap { (100...599).contains($0) ? .int($0) : nil } ?? .null),
                ])
            }
        }
    }

    /// The operation's work. Ends the operation in exactly one terminal state.
    func run(operationId: String, profileId: String, revision: Int, callerScope: String) async {
        do {
            guard try await store.setOperation(operationId, state: .running) else {
                if try await store.operationState(operationId) == .cancelling {
                    try await store.setOperation(operationId, state: .cancelled)
                }
                return
            }
            let resolved = try await store.resolveGuiProfile(profileId, revision: revision, callerScope: callerScope)
            let codec = try codecs.codec(adapterId: resolved.adapterId, coordinateProtocol: resolved.coordinateProtocol)
            let deadline = clock.nowNanoseconds() + UInt64(Self.deadlineMs) * 1_000_000

            var outcomes: [Level: LevelOutcome] = [:]
            var firstFailure: ContractError?
            for level in Level.allCases {
                try Task.checkCancellation()
                let previousPassed = level == .network || outcomes[Level.allCases[Level.allCases.firstIndex(of: level)! - 1]]?.status == "passed"
                let outcome = previousPassed
                    ? try await runLevel(level, resolved: resolved, codec: codec, operationId: operationId,
                                         callerScope: callerScope, deadline: deadline)
                    : .skipped
                try Task.checkCancellation()
                outcomes[level] = outcome
                if outcome.status != "skipped" {
                    try await recordEvidence(level, outcome, resolved: resolved, codec: codec, operationId: operationId)
                }
                if outcome.status == "failed", firstFailure == nil {
                    firstFailure = outcome.error ?? ContractError(.capabilityMismatch, "the \(level.rawValue) test failed",
                                                                  details: .obj([("reasonCode", .string(outcome.reasonCode ?? "FAILED"))]))
                }
                try await store.saveOperationProgress(operationId, try await testResult(resolved, outcomes))
            }
            let result = try await testResult(resolved, outcomes)
            if let firstFailure {
                try await store.setOperation(operationId, state: .failed, result: result, error: firstFailure)
            } else {
                try await store.setOperation(operationId, state: .succeeded, result: result)
            }
        } catch is CancellationError {
            _ = try? await store.setOperation(operationId, state: .cancelled)
        } catch {
            if Task.isCancelled {
                _ = try? await store.setOperation(operationId, state: .cancelled)
                return
            }
            let e = (error as? ContractError) ?? ContractError(.internalError, "the capability test stopped")
            let partial = (try? await store.operationProgress(operationId)) ?? nil
            if let partial {
                _ = try? await store.setOperation(operationId, state: .failed, result: partial, error: e)
            } else {
                // A failed capability test must still carry its (all skipped) report.
                let skipped = JSONValue.obj([
                    ("guiProfileId", .string(profileId)), ("guiProfileRevision", .int(max(revision, 1))),
                    ("levels", .array(Level.allCases.map { LevelOutcome.skipped.json($0.rawValue) })),
                    ("capabilities", (try? await skippedCapabilities(profileId: profileId, revision: revision)) ?? .null),
                    ("performedDesktopInput", .bool(false)),
                ])
                let usable = (try? ContractBundle.shared.validate(skipped, "AiTestResult"))?.isEmpty == true
                _ = try? await store.setOperation(operationId, state: .failed, result: usable ? skipped : nil, error: e)
            }
        }
    }

    func runLevel(_ level: Level, resolved: ResolvedGuiProfile, codec: GuiActionCodec, operationId: String,
                  callerScope: String, deadline: UInt64) async throws -> LevelOutcome {
        let started = clock.nowNanoseconds()
        func elapsed() -> Int { Int((clock.nowNanoseconds() &- started) / 1_000_000) }
        if level == .network { return await probe(resolved, deadline: deadline) }

        let request: AiInferenceRequest
        let snapshotId = "\(SyntheticGuiFixture.fixtureId):\(level.rawValue)"
        switch level {
        case .authModel:
            request = AiInferenceRequest(messages: [.text(.user, SyntheticGuiFixture.authPrompt)], maxOutputTokens: 16)
        case .imageInput:
            request = AiInferenceRequest(messages: [AiMessage(role: .user, content: [
                .text(SyntheticGuiFixture.colorQuestion),
                .image(AiImageContent(screenshotId: snapshotId, mimeType: "image/png", bytes: try SyntheticGuiFixture.colorImage())),
            ])], maxOutputTokens: 16)
        case .guiContract:
            let proto = codec.provenance.coordinateProtocol
            request = AiInferenceRequest(messages: [
                .text(.system, UITarsCodec.actionSpace(for: proto)),
                AiMessage(role: .user, content: [
                    .text("Task: \(SyntheticGuiFixture.guiTask)"),
                    .image(AiImageContent(screenshotId: snapshotId, mimeType: "image/png", bytes: try SyntheticGuiFixture.screenImage())),
                ]),
            ], maxOutputTokens: min(resolved.model.model.maxOutputTokens, 256))
        case .network:
            fatalError("handled above")
        }
        let context = AiCallContext(
            inferenceAttemptId: ConfigStore.randomId("att"),
            purpose: .capabilityTest(CapabilityTestCallPurpose(
                operationId: operationId, level: level.modelLevel!, syntheticSnapshotId: snapshotId,
                fixtureId: SyntheticGuiFixture.fixtureId, guiProfileId: resolved.guiProfileId,
                guiProfileRevision: Revision(resolved.guiProfileRevision))),
            callerScopeRef: callerScope, budgetScopeRef: operationId, deadlineMonotonicNanoseconds: deadline)
        let reply: AiInferenceResult
        do {
            reply = try await ai.infer(request, resolvedModel: resolved.model, context: context)
        } catch let e as ContractError {
            return LevelOutcome(status: "failed", latencyMs: elapsed(), reasonCode: e.code.rawValue,
                                httpStatus: e.details?["httpStatus"]?.intValue, error: e)
        }
        let status = reply.record.httpStatus
        switch level {
        case .authModel:
            let ok = !reply.outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return LevelOutcome(status: ok ? "passed" : "failed", latencyMs: elapsed(),
                                reasonCode: ok ? nil : "EMPTY_RESPONSE", httpStatus: status,
                                error: ok ? nil : ContractError(.upstreamProtocolError, "the model returned no text"))
        case .imageInput:
            let words = reply.outputText.lowercased().split { !$0.isLetter }
            let ok = words.first.map(String.init) == SyntheticGuiFixture.colorAnswer
            return LevelOutcome(status: ok ? "passed" : "failed", latencyMs: elapsed(),
                                reasonCode: ok ? nil : "IMAGE_ANSWER_MISMATCH", httpStatus: status,
                                error: ok ? nil : ContractError(.capabilityMismatch, "the model did not read the test image correctly"))
        case .guiContract:
            do {
                let decoded = try codec.decode(reply.outputText, context: CodecContext(
                    transform: try SyntheticGuiFixture.screenTransform(),
                    maxWaitMs: resolved.limits["maxWaitMs"]?.intValue ?? 5000))
                guard case let .action(.click(p)) = decoded.body else {
                    return LevelOutcome(status: "failed", latencyMs: elapsed(), reasonCode: "UNEXPECTED_SUGGESTION",
                                        httpStatus: status,
                                        error: ContractError(.capabilityMismatch, "the model did not click the test button"))
                }
                let r = SyntheticGuiFixture.buttonRect
                let hit = p.x >= r.origin.x && p.x < r.origin.x + r.size.width && p.y >= r.origin.y && p.y < r.origin.y + r.size.height
                return LevelOutcome(status: hit ? "passed" : "failed", latencyMs: elapsed(),
                                    reasonCode: hit ? nil : "TARGET_MISSED", httpStatus: status,
                                    error: hit ? nil : ContractError(.capabilityMismatch, "the model's click missed the test button"))
            } catch let e as ContractError {
                return LevelOutcome(status: "failed", latencyMs: elapsed(), reasonCode: e.code.rawValue,
                                    httpStatus: status, error: e)
            }
        case .network:
            fatalError("handled above")
        }
    }

    /// network: GET the base URL with no credential. Any HTTP answer, a
    /// redirect included, proves the endpoint is reachable.
    func probe(_ resolved: ResolvedGuiProfile, deadline: UInt64) async -> LevelOutcome {
        let started = clock.nowNanoseconds()
        func elapsed() -> Int { Int((clock.nowNanoseconds() &- started) / 1_000_000) }
        var req = URLRequest(url: resolved.model.connection.baseUrl)
        req.httpMethod = "GET"
        let remaining = Double(deadline &- clock.nowNanoseconds()) / 1e9
        req.timeoutInterval = max(0.1, min(Double(resolved.model.connection.timeoutMs) / 1000, remaining))
        req.httpShouldHandleCookies = false
        do {
            let r = try await http.send(req, maxResponseBytes: 64 * 1024)
            return LevelOutcome(status: "passed", latencyMs: elapsed(), reasonCode: nil, httpStatus: r.status)
        } catch HTTPTransportError.redirect(let status) {
            return LevelOutcome(status: "passed", latencyMs: elapsed(), reasonCode: nil, httpStatus: status == 0 ? nil : status)
        } catch HTTPTransportError.responseTooLarge {
            return LevelOutcome(status: "passed", latencyMs: elapsed(), reasonCode: nil, httpStatus: nil)
        } catch HTTPTransportError.timedOut {
            return LevelOutcome(status: "failed", latencyMs: elapsed(), reasonCode: "NETWORK_TIMEOUT",
                                error: ContractError(.upstreamUnavailable, "the endpoint did not answer in time"))
        } catch {
            return LevelOutcome(status: "failed", latencyMs: elapsed(), reasonCode: "NETWORK_UNREACHABLE",
                                error: ContractError(.upstreamUnavailable, "the endpoint could not be reached"))
        }
    }

    func recordEvidence(_ level: Level, _ o: LevelOutcome, resolved: ResolvedGuiProfile, codec: GuiActionCodec,
                        operationId: String) async throws {
        let v = codec.provenance
        try await store.recordCapabilityEvidence(
            modelProfileId: resolved.model.model.modelProfileId, revision: Int(resolved.model.model.revision),
            layer: level.layer, status: o.status == "passed" ? "verified" : "failed",
            operationId: operationId, reasonCode: o.reasonCode,
            adapter: level == .guiContract ? (v.adapterVersion, v.promptVersion, v.parserVersion) : nil)
    }

    func testResult(_ resolved: ResolvedGuiProfile, _ outcomes: [Level: LevelOutcome]) async throws -> JSONValue {
        let caps = try await store.revisionBody(.modelProfile, resolved.model.model.modelProfileId,
                                                Int(resolved.model.model.revision))?["capabilities"] ?? .null
        return .obj([
            ("guiProfileId", .string(resolved.guiProfileId)),
            ("guiProfileRevision", .int(resolved.guiProfileRevision)),
            ("levels", .array(Level.allCases.map { (outcomes[$0] ?? .skipped).json($0.rawValue) })),
            ("capabilities", caps),
            ("performedDesktopInput", .bool(false)),
        ])
    }

    func skippedCapabilities(profileId: String, revision: Int) async throws -> JSONValue? {
        guard let gui = try await store.revisionBody(.guiProfile, profileId, revision),
              let mp = gui["modelProfileId"]?.stringValue, let mpRev = gui["modelProfileRevision"]?.intValue else { return nil }
        return try await store.revisionBody(.modelProfile, mp, mpRev)?["capabilities"]
    }
}
