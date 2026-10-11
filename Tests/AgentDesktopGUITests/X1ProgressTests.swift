import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopGUI

// X1-2 (docs/plan/05 §5.2, 08 GX-17…20): stall detection. A run that stops
// making progress takes one bounded recovery, then ends with a reason
// instead of spending every step.

private func bundle(_ elements: [ObservedElement]?, _ coverage: ElementCoverage = .complete) throws -> ObservationBundle {
    let serial = UUID().uuidString.prefix(8).lowercased()
    let shot = try ScreenshotDescriptor(screenshotId: "shot-p\(serial)", artifactRef: "art-p\(serial)", sha256: String(repeating: "b", count: 64),
                                        mimeType: "image/png", transformVersion: "t1", sourceToDesktop: .scale(0.5, 0.5),
                                        transform: .pipeline(sourceSize: Size(width: 1000, height: 800)))
    let obs = Observation(observationId: "obs-p\(serial)",
                          stamp: ObservationStamp(sessionId: "sess-a", desktopId: "desk-a", snapshotId: "snap-p\(serial)",
                                                  bindingEpoch: 1, runGeneration: 1),
                          target: target, observedAt: Date(timeIntervalSince1970: 1_791_000_000), screenshots: [shot])
    return ObservationBundle(observation: obs, authorizedImages: [], elements: elements, elementCoverage: coverage)
}

private func page(_ status: String, name: String = "") -> [ObservedElement] {
    [ObservedElement(role: "static_text", label: status, value: nil), ObservedElement(role: "text_field", label: "姓名", value: name)]
}

private let clickA = ProgressTracker.Intent(.click(sourcePixel: Point(x: 100, y: 100)))
private let clickANudged = ProgressTracker.Intent(.click(sourcePixel: Point(x: 110, y: 105)))
private let clickB = ProgressTracker.Intent(.click(sourcePixel: Point(x: 400, y: 600)))
private let typeAda = ProgressTracker.Intent(.type(text: "Ada"))

@Suite("X1 progress detection")
struct X1ProgressTrackerTests {
    // GX-17: the same intent in the same state changed nothing twice: the
    // third is not sent before a recovery. A nudge within one cell is the
    // same intent; a change in between starts over.
    @Test func gx17_repeatedStateAndAction() throws {
        var t = ProgressTracker()
        t.start(try bundle(page("未提交")))
        #expect(t.afterAction(clickA, try bundle(page("未提交"))) == nil)
        #expect(t.afterAction(clickANudged, try bundle(page("未提交"))) == .repeatedAction)

        var u = ProgressTracker()
        u.start(try bundle(page("未提交")))
        #expect(u.afterAction(clickA, try bundle(page("未提交"))) == nil)
        #expect(u.afterAction(typeAda, try bundle(page("未提交", name: "Ada"))) == nil)   // progress
        #expect(u.afterAction(clickA, try bundle(page("未提交", name: "Ada"))) == nil)    // starts over
        // Typed text is only a digest inside the tracker.
        #expect(!typeAda.digest.contains("Ada"))
    }

    // GX-18: A → B → A after actions is a small loop.
    @Test func gx18_aBaLoop() throws {
        var t = ProgressTracker()
        t.start(try bundle(page("A")))
        #expect(t.afterAction(clickA, try bundle(page("B"))) == nil)
        #expect(t.afterAction(clickB, try bundle(page("A"))) == .stateLoop)
        #expect(ProgressTracker.Stall.stateLoop.closingReason == "loop_detected")
        // A → B → C is progress.
        var u = ProgressTracker()
        u.start(try bundle(page("A")))
        #expect(u.afterAction(clickA, try bundle(page("B"))) == nil)
        #expect(u.afterAction(clickB, try bundle(page("C"))) == nil)
    }

    // GX-19: three actions in a row that change nothing. Clock text is not
    // progress; a read that is not complete counts neither way.
    @Test func gx19_longNoProgress() throws {
        var t = ProgressTracker()
        t.start(try bundle(page("12:00 未提交")))
        #expect(t.afterAction(clickA, try bundle(page("12:01 未提交"))) == nil)
        #expect(t.afterAction(clickB, try bundle(page("12:02 未提交"))) == nil)
        #expect(t.afterAction(typeAda, try bundle(page("2026-10-11 12:03:09 未提交"))) == nil)  // still the same state…
        var u = ProgressTracker()
        u.start(try bundle(page("12:00 未提交")))
        _ = u.afterAction(clickA, try bundle(page("12:01 未提交")))
        _ = u.afterAction(clickB, try bundle(page("12:02 未提交")))
        #expect(u.afterAction(ProgressTracker.Intent(.key(keys: ["Enter"])), try bundle(page("12:03 未提交"))) == .noProgress)

        // Partial and unavailable reads have no fingerprint: no stall from them.
        var v = ProgressTracker()
        v.start(try bundle(page("未提交")))
        for _ in 0..<5 { #expect(v.afterAction(clickA, try bundle(page("未提交"), .partial)) == nil) }
        #expect(v.afterAction(clickA, try bundle(nil)) == nil)
        #expect(ProgressTracker.fingerprint(try bundle(page("x"), .partial)) == nil)
    }

    // Waits: a change is progress, no change counts nothing.
    @Test func waitsResetOnChangeOnly() throws {
        var t = ProgressTracker()
        t.start(try bundle(page("未提交")))
        #expect(t.afterAction(clickA, try bundle(page("未提交"))) == nil)
        t.afterWait(try bundle(page("加载中")))
        #expect(t.afterAction(clickA, try bundle(page("加载中"))) == nil)   // the earlier ineffective click no longer counts
    }

    // One recovery by default; after it the counters start over.
    @Test func recoveryBudget() throws {
        var t = ProgressTracker()
        t.start(try bundle(page("未提交")))
        #expect(t.mayRecover)
        t.recovered(try bundle(page("未提交")))
        #expect(!t.mayRecover)
        #expect(t.afterAction(clickA, try bundle(page("未提交"))) == nil)
        #expect(t.afterAction(clickA, try bundle(page("未提交"))) == .repeatedAction)
    }
}

@Suite("X1 progress in a run")
struct X1ProgressRunTests {
    // GX-17/19/20 in a run: the model keeps clicking a spot that does
    // nothing. One recovery, then the run ends with no_progress, long
    // before its 20 steps; nothing is sent twice for the recovery.
    @Test func gx20_stallEndsTheRunWithinTheSameBudget() async throws {
        let h = try GuiHarness(Array(repeating: click(450, 380), count: 20))
        try await h.setUpProfile()
        let runId = try await h.start()
        await h.finished(runId)
        let run = h.run(runId)
        #expect(run.ending == .failed(reason: "no_progress"))
        let recoveries = run.events.filter { $0["type"]?.stringValue == "unit.recovery" }
        #expect(recoveries.count == 1)
        #expect(recoveries.first?["data"]?["kind"]?.stringValue == "repeated_action")
        for r in recoveries { #expect(RuntimeContract.shared.validate(r, "UnitRunEvent").isEmpty, "\(r.encoded())") }
        // Two ineffective clicks, one recovery, two more: four inputs in all.
        let sent = await h.executor.executed.count
        #expect(sent == 4)
        #expect(run.steps <= 4)
        #expect(h.ai.callCount == 4)
    }

    // Real progress never trips it: the neutral form flow still succeeds.
    @Test func progressingRunIsUntouched() async throws {
        let h = try GuiHarness([click(200, 100), typeText("Ada"), click(200, 300), finish])
        try await h.setUpProfile()
        let runId = try await h.start()
        await h.finished(runId)
        let run = h.run(runId)
        #expect(run.ending == .verified)
        #expect(run.count("unit.recovery") == 0)
    }

    // A partial element read never counts as "no change": the run spends
    // its steps instead of ending as stalled.
    @Test func partialReadsNeverStall() async throws {
        let h = try GuiHarness(Array(repeating: click(450, 380), count: 6), limits: [("maxSteps", .int(6))])
        try await h.setUpProfile()
        await h.observation.set(coverage: .partial)
        let runId = try await h.start()
        await h.finished(runId)
        let run = h.run(runId)
        #expect(run.ending == .failed(reason: "limit_exceeded"))
        #expect(run.count("unit.recovery") == 0)
    }
}

// X1-3: after a stall's recovery the next inference is told the previous
// action brought no change (the stall kind only) so the model tries
// another way. No extra model call; nothing from the screen goes in.

/// The text parts of a request's last (current) user message.
private func lastUserTexts(_ r: AiInferenceRequest) -> [String] {
    guard let last = r.messages.last, last.role == .user else { return [] }
    return last.content.compactMap { if case let .text(t) = $0 { return t }; return nil }
}

/// Every hint text the request carries, wherever it is.
private func hintTexts(_ r: AiInferenceRequest) -> [String] {
    let hints = Set(GuiRecoveryHint.allCases.map(\.promptText))
    return r.messages.flatMap(\.content).compactMap { if case let .text(t) = $0, hints.contains(t) { return t }; return nil }
}

@Suite("X1 recovery hint")
struct X1RecoveryHintTests {
    // The hint is a fixed string per stall kind: it names the kind and
    // nothing else, and every kind maps to its own hint.
    @Test func hintTextIsFixedPerKind() {
        #expect(Set(GuiRecoveryHint.allCases.map(\.promptText)).count == 3)
        for h in GuiRecoveryHint.allCases {
            #expect(h.promptText.contains(h.rawValue))
            #expect(h.promptText.contains("different approach"))
            let ascii = h.promptText.unicodeScalars.allSatisfy { $0.isASCII }
            #expect(ascii, "no screen or user text can be in a fixed ASCII line")
        }
        #expect(ProgressTracker.Stall.repeatedAction.hint == .repeatedAction)
        #expect(ProgressTracker.Stall.noProgress.hint == .noProgress)
        #expect(ProgressTracker.Stall.stateLoop.hint == .stateLoop)
        for s in [ProgressTracker.Stall.repeatedAction, .noProgress, .stateLoop] { #expect(s.hint.rawValue == s.rawValue) }
    }

    // In the request: one more text part between the task line and the
    // current screenshot; without a hint the request is as before.
    @Test func hintIsOneTextPartOfTheCurrentMessage() async throws {
        let h = try GuiHarness([])
        try await h.setUpProfile()
        let binding = try await boundBinding(h)
        let codec = UITarsCodec(coordinateProtocol: .imagePixels)
        let current = AiImageContent(screenshotId: "now", mimeType: "image/png", bytes: Data(count: 10))
        let history = [GuiHistoryTurn(image: nil, reply: "Action: click(start_box='(1,1)')")]
        let (plain, _, _) = try GuiAiProvider.buildRequest(binding: binding, codec: codec, current: current, history: history)
        #expect(hintTexts(plain).isEmpty)
        for kind in GuiRecoveryHint.allCases {
            let (hinted, sent, _) = try GuiAiProvider.buildRequest(binding: binding, codec: codec, current: current,
                                                                   history: history, hint: kind)
            #expect(sent == 1)
            #expect(hinted.messages.count == plain.messages.count)
            #expect(Array(hinted.messages.dropLast()) == Array(plain.messages.dropLast()), "system prompt and history unchanged")
            let content = try #require(hinted.messages.last?.content)
            #expect(content == [.text("Task: \(GuiHarness.goal)"), .text(kind.promptText), .image(current)])
            #expect(hintTexts(hinted) == [kind.promptText])
        }
    }

    // GX-17/20 recovery branch, run level: the inference right after the
    // recovery carries the repeated_action hint; the ones before and after
    // do not. Still four calls in all, the same as without the hint.
    @Test func theInferenceAfterRecoveryCarriesTheHint() async throws {
        let h = try GuiHarness(Array(repeating: click(450, 380), count: 20))
        try await h.setUpProfile()
        let runId = try await h.start()
        await h.finished(runId)
        let run = h.run(runId)
        #expect(run.ending == .failed(reason: "no_progress"))
        let requests = h.ai.requests
        #expect(requests.count == 4)
        #expect(requests.map { hintTexts($0) } == [[], [], [GuiRecoveryHint.repeatedAction.promptText], []])
        #expect(lastUserTexts(requests[2]) == ["Task: \(GuiHarness.goal)", GuiRecoveryHint.repeatedAction.promptText])
        // Nothing from the screen, the goal's parameters or the window in it.
        let hint = GuiRecoveryHint.repeatedAction.promptText
        for leak in [GuiHarness.goal, GuiHarness.expected, "Ada", "MAC-001", "姓名", "中立表单"] { #expect(!hint.contains(leak)) }
        #expect(run.modelAttempts == 4)
        #expect(unitEventsClean(run.events))
    }

    // An empty reply right after the recovery: the retry of the same step
    // keeps the hint; the step after a real reply does not.
    @Test func hintSurvivesAnEmptyReplyRetryOnly() async throws {
        let h = try GuiHarness([click(450, 380), click(450, 380), .text(" \n "), click(450, 380), click(450, 380)])
        try await h.setUpProfile()
        let runId = try await h.start()
        await h.finished(runId)
        let run = h.run(runId)
        #expect(run.ending == .failed(reason: "no_progress"))
        let hint = GuiRecoveryHint.repeatedAction.promptText
        #expect(h.ai.requests.map { hintTexts($0) } == [[], [], [hint], [hint], []])
        #expect(run.count("unit.recovery") == 2, "the stall's recovery and the empty reply's")
        #expect(await h.executor.executed.count == 4)
    }

    // A run that keeps progressing never sees a hint.
    @Test func noStallNoHint() async throws {
        let h = try GuiHarness([click(200, 100), typeText("Ada"), click(200, 300), finish])
        try await h.setUpProfile()
        let runId = try await h.start()
        await h.finished(runId)
        #expect(h.run(runId).ending == .verified)
        #expect(h.ai.requests.allSatisfy { hintTexts($0).isEmpty })
    }
}
