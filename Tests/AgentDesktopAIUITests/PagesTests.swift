import AgentDesktopAI
import AgentDesktopProtocol
import AgentDesktopGUI
import AgentDesktopService
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AgentDesktopAIUI

// View models of W01–W08 driven against the composed service through an
// in-process ContractClient (UI-001..006, USG-004). Native UI automation,
// screenshots of the real window and a real model are not part of these.

@MainActor
func waitUntil(_ what: String, _ check: () async throws -> Bool) async throws {
    for _ in 0..<500 {
        if try await check() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    Issue.record("timed out waiting for \(what)")
}

/// W02 create → returns the saved connection id.
@MainActor
func createConnection(_ client: ContractClient, name: String = "Ark") async throws -> String {
    let editor = ConnectionEditorModel(client: client, mode: .create, clock: FastClock())
    editor.name = name
    editor.baseUrl = "https://ark.cn-beijing.volces.com/api/v3"
    editor.secretInput = canary
    await editor.save()
    #expect(editor.problem == nil, "\(String(describing: editor.problem))")
    return try #require(editor.savedConnectionId)
}

/// W03: a model profile and a GUI profile, made the default.
@MainActor
func configure(_ client: ContractClient) async throws -> ProfilesModel {
    _ = try await createConnection(client)
    let p = ProfilesModel(client: client)
    await p.refresh()
    p.mpName = "Seed lite"
    p.mpModelId = "doubao-seed-2-1-lite-260915"
    p.mpTemperature = 0
    await p.saveModelProfile()
    p.name = "UI-TARS"
    await p.saveProfile()
    #expect(p.problem == nil, "\(String(describing: p.problem))")
    let row = try #require(p.profiles.first)
    await p.setDefault(row)
    return p
}

@MainActor
@Suite("AI/GUI pages", .serialized)
struct PagesTests {
    // UI-001: empty, list, failed refresh, no match; disabled rows; no key anywhere.
    @Test func ui001_connectionsStates() async throws {
        let h = try await Harness()
        let spy = SpyClient(h.client)
        let list = ConnectionsModel(client: spy)
        await list.refresh()
        #expect(list.emptyKind == .noConnections)

        _ = try await createConnection(spy)
        await list.refresh()
        let row = try #require(list.rows.first)
        #expect(row.revision == 1)
        #expect(row.enabled)
        #expect(row.credentialSummary.hasPrefix("已保存凭据"))
        #expect(list.emptyKind == .none)

        // A failed refresh keeps the last list and its time; it is not "empty".
        let loadedAt = list.lastLoadedAt
        spy.fail("ai.connections.list")
        await list.refresh()
        #expect(list.phase == .failed)
        #expect(list.rows.count == 1)
        #expect(list.lastLoadedAt == loadedAt)
        #expect(list.emptyKind == .none)
        #expect(list.problem?.code == .upstreamUnavailable)
        spy.fail("ai.connections.list", false)

        list.search = "zzz"
        #expect(list.emptyKind == .noMatch)
        list.search = ""

        await list.disable(row)
        #expect(list.rows.first?.enabled == false)
        #expect(list.rows.first?.revision == 2)
        // A stale revision is a conflict, never a local fake update.
        await list.disable(row)
        #expect(list.problem?.code == .configConflict)
        #expect(list.problem?.currentRevision == 2)

        #expect(!Harness.strings(in: list).contains { $0.contains(canary) })
    }

    // UI-002: client-side endpoint rules, metadata save keeps the credential,
    // conflict keeps the draft, rotation is separate; the key never stays.
    @Test func ui002_editorEndpointConflictRotation() async throws {
        let h = try await Harness()
        let spy = SpyClient(h.client)
        let bad = ConnectionEditorModel(client: spy, mode: .create)
        bad.name = "Bad"
        bad.secretInput = canary
        for url in ["https://user:pw@api.example.com/v1", "https://api.example.com/v1?key=sk-1",
                    "http://api.example.com/v1", "https://api.example.com/v1/chat/completions", "ftp://x"] {
            bad.baseUrl = url
            await bad.save()
            #expect(bad.fieldErrors["baseUrl"] != nil, "\(url)")
            #expect(!(bad.fieldErrors["baseUrl"] ?? "").contains("example"), "errors never quote the URL")
        }
        #expect(spy.commands.isEmpty, "invalid input sends nothing")
        #expect(bad.secretInput.isEmpty, "a refused submission still clears the key field")

        let id = try await createConnection(spy)
        let a = ConnectionEditorModel(client: spy, mode: .edit(id))
        let b = ConnectionEditorModel(client: spy, mode: .edit(id))
        await a.load()
        await b.load()
        #expect(a.baseRevision == 1)
        #expect(a.secretInput.isEmpty, "the saved key is never filled back")
        let summary = a.savedCredentialSummary

        a.name = "Ark renamed"
        await a.save()
        #expect(a.baseRevision == 2)
        #expect(a.savedCredentialSummary == summary, "a metadata save keeps the credential identity")

        b.timeoutMs = 45000
        await b.save()
        #expect(b.problem?.code == .configConflict)
        let conflict = try #require(b.conflict)
        #expect(conflict.baseRevision == 1 && conflict.serverRevision == 2)
        #expect(conflict.changedFields.contains("名称"))
        #expect(b.timeoutMs == 45000, "the draft is kept")
        await b.reloadKeepingDraft()
        #expect(b.baseRevision == 2 && b.timeoutMs == 45000 && b.name == "Ark renamed")
        await b.save()
        #expect(b.baseRevision == 3 && b.problem == nil)

        b.secretInput = canary + "-new"
        await b.rotateCredential()
        #expect(b.problem == nil, "\(String(describing: b.problem))")
        #expect(b.secretInput.isEmpty)
        #expect(b.savedCredentialSummary != summary)
        #expect(b.notice?.contains("凭据已更新") == true)

        // Fetching models refuses an unsaved Base URL.
        b.baseUrl = "https://other.example.com/v1"
        await b.refreshModels()
        #expect(b.problem?.title == "请先保存连接")
        #expect(spy.count("ai.models.refresh") == 0)

        for model in [a, b, bad] {
            #expect(!Harness.strings(in: model).contains { $0.contains(canary) })
        }
    }

    // UI-003: model sub-panel, GUI profile, default pointer CAS, ceilings,
    // and no fixture adapter in production.
    @Test func ui003_profilesAndDefaultPointer() async throws {
        let h = try await Harness()
        let spy = SpyClient(h.client)
        let p = try await configure(spy)
        #expect(!p.adapters.contains { $0.id == "fixture_json_v1" })
        let row = try #require(p.profiles.first)
        #expect(p.defaultPointer.guiProfileId == row.id)
        let d = p.defaultPointer.revision
        #expect(p.defaultLabel(for: row) == "默认（指针 d\(d)）")

        // A second window with the old pointer revision cannot overwrite it.
        let other = ProfilesModel(client: spy)
        await other.refresh()
        p.newProfile()
        p.name = "UI-TARS 2"
        await p.saveProfile()
        await p.refresh()
        let second = try #require(p.profiles.first { $0.name == "UI-TARS 2" })
        await p.setDefault(second)
        #expect(p.defaultPointer.revision == d + 1)
        await other.setDefault(try #require(other.profiles.first))
        #expect(other.problem?.code == .configConflict)

        // Limits above the server ceiling never leave the page.
        let before = spy.count("ai.profiles.update") + spy.count("ai.profiles.create")
        p.newProfile()
        p.limits.maxSteps = 21
        await p.saveProfile()
        #expect(p.fieldErrors["maxSteps"] != nil)
        #expect(spy.count("ai.profiles.update") + spy.count("ai.profiles.create") == before)

        #expect(ProfilesModel(client: spy, allowFixtureAdapter: true).adapters.contains { $0.id == "fixture_json_v1" })
    }

    // UI-004: four levels, each with its own state; a failed level stops
    // the next; cancel shows cancelling first; never any desktop input.
    @Test func ui004_capabilityTest() async throws {
        let h = try await Harness()
        let profiles = try await configure(h.client)
        let id = try #require(profiles.profiles.first?.id)

        let t = CapabilityTestModel(client: h.client, guiProfileId: id, clock: FastClock(), pollMs: 5)
        await t.start()
        #expect(t.phase == .finished("succeeded"))
        #expect(t.allPassed)
        #expect(t.performedDesktopInput == false)
        #expect(t.evidence["guiContract"] == "verified")
        #expect(h.form.inputCount == 0)

        h.upstream.colorAnswer = "blue"
        let f = CapabilityTestModel(client: h.client, guiProfileId: id, clock: FastClock(), pollMs: 5)
        await f.start()
        #expect(f.levels.map(\.status) == [.passed, .passed, .failed, .skipped])
        #expect(f.levels[3].statusText == "未执行（前一层未通过）")
        #expect(!f.allPassed)

        h.upstream.colorAnswer = SyntheticGuiFixture.colorAnswer
        h.upstream.delayMs = 300
        let c = CapabilityTestModel(client: h.client, guiProfileId: id, clock: FastClock(), pollMs: 5)
        let running = Task { await c.start() }
        try await waitUntil("the test to run") { c.phase == .running }
        await c.cancel()
        #expect(c.phase == .cancelling || c.phase == .finished("cancelled"))
        await running.value
        #expect(c.phase == .finished("cancelled"))
        #expect(!c.allPassed, "unfinished levels are never shown as passed")
        #expect(h.form.inputCount == 0)
    }

    // UI-005: validate-only does nothing; double start is one run; the
    // default moving later does not change the run's binding (A6: a
    // Durable unit Run started in-process).
    @Test func ui005_startRun() async throws {
        let h = try await Harness()
        let spy = SpyClient(h.client)
        let p = try await configure(spy)
        let first = try #require(p.profiles.first)

        let s = RunStartModel(client: spy)
        await s.load()
        #expect(s.guiProfileId == first.id)
        s.desktopId = "desk-a"
        await s.validateOnly()
        #expect(s.summary?.contains("GUI 配置 r\(first.revision)") == true)
        #expect(spy.count("unit.run") == 0)
        #expect(await h.executor.executed == 0)

        s.allowedActions = []
        await s.start()
        #expect(s.fieldErrors["actions"] != nil)
        s.allowedActions = ["click", "type"]

        async let one: Void = s.start()
        async let two: Void = s.start()
        _ = await (one, two)
        let runId = try #require(s.startedRunId)
        #expect(spy.count("unit.run") == 1, "a second click while starting sends nothing")
        // A started page starts no second Run until prepareNew.
        await s.start()
        #expect(spy.count("unit.run") == 1)
        #expect(s.startedRunId == runId)

        p.newProfile()
        p.name = "Later default"
        await p.saveProfile()
        await p.refresh()
        await p.setDefault(try #require(p.profiles.first { $0.name == "Later default" }))
        let d = RunDetailModel(client: spy, runId: runId, clock: FastClock(), pollMs: 5)
        await d.follow()
        #expect(d.bindingSummary.first { $0.0 == "GUI 配置" }?.1 == "\(first.id) r\(first.revision)")
        let run = try await h.client.runtime("run.show", .obj([("runId", .string(runId))]), requestId: nil)
        #expect(run["unit"]?["guiProfileId"]?.stringValue == first.id)
        #expect(run["origin"]?.stringValue == "gui_explorer" && run["lifetime"]?.stringValue == "platform_durable")
        #expect(h.form.submissions == 1, "one start, one run")
    }

    // UI-006 (W06): success with its evidence; events deduplicated.
    @Test func ui006_runDetailSuccess() async throws {
        let h = try await Harness()
        _ = try await configure(h.client)
        let s = RunStartModel(client: h.client)
        await s.load()
        s.desktopId = "desk-a"
        await s.start()
        let d = RunDetailModel(client: h.client, runId: try #require(s.startedRunId), clock: FastClock(), pollMs: 5)
        await d.follow()
        #expect(d.state == "succeeded")
        #expect(d.stateText.hasPrefix("成功"))
        #expect(d.verification.status == "matched")
        #expect(d.verification.observationId != nil)
        #expect(d.confirmedActions == 3)
        #expect(d.modelAttempts == 3 && d.stepCount == 3)
        #expect(d.latestReceipt?.deliveryText.contains("不代表任务成功") == true)
        #expect(d.events.contains { $0.type == "unit.verification" } && d.events.last?.type == "run.ended")
        let count = d.events.count
        await d.refresh()
        await d.refresh()
        #expect(d.events.count == count)
        #expect(Set(d.events.map(\.sequence)).count == count)
        #expect(d.events.map(\.sequence) == d.events.map(\.sequence).sorted())
        #expect(!d.canStop)
        #expect(!Harness.strings(in: d).contains { $0.contains(canary) })
    }

    // UI-006 (W06 stop): accepted is "stop requested", not "stopped".
    @Test func ui006_stopAcceptedIsNotStopped() async throws {
        let h = try await Harness()
        _ = try await configure(h.client)
        await h.executor.set(mode: .hang)
        let s = RunStartModel(client: h.client)
        await s.load()
        s.desktopId = "desk-a"
        await s.start()
        let d = RunDetailModel(client: h.client, runId: try #require(s.startedRunId), clock: FastClock(), pollMs: 5)
        try await waitUntil("the input to be in flight") { await h.executor.isHanging }
        await d.stop()
        #expect(d.stopPhase == .requested)
        #expect(d.state == "cancelling")
        #expect(d.stateText.contains("停止请求已收到"))
        #expect(d.stateText != "已停止")
        await h.executor.set(mode: .confirm)
        await h.executor.release()
        await d.follow()
        #expect(d.state == "cancelled")
        #expect(d.stopPhase == .stopped)
        #expect(d.stateText == "已停止")
        #expect(await h.executor.executed == 1, "no input after the stop")
    }

    // UI-006 (W07): an unknown outcome ends the Run as unknown; the input
    // is never resent and nothing resumes it.
    @Test func ui006_unknownOutcomeAttention() async throws {
        let h = try await Harness()
        _ = try await configure(h.client)
        await h.executor.set(mode: .unknown)
        let s = RunStartModel(client: h.client)
        await s.load()
        s.desktopId = "desk-a"
        await s.start()
        let runId = try #require(s.startedRunId)
        let d = RunDetailModel(client: h.client, runId: runId, clock: FastClock(), pollMs: 5)
        await d.follow()
        // It needs attention as soon as an input's outcome is unknown, even
        // before the Runtime ended the Run.
        #expect(d.needsAttention)
        try await waitUntil("the Run to end") { await d.refresh(); return d.isTerminal }
        #expect(d.state == "unknown")
        #expect(d.needsAttention)
        #expect(d.stateText.contains("有一项输入结果尚未确认"))
        #expect(!d.canStop)

        let a = AttentionModel(client: h.client, runId: runId, clock: FastClock())
        await a.refreshEvidence()
        #expect(a.branch == .unknownAction)
        #expect(a.headline == "有一项输入结果尚未确认")
        #expect(a.explanation.contains("不会自动重发"))
        #expect(a.canCreateNewRun, "the Runtime ended the Run; a new one may start")
        await a.refreshEvidence()
        #expect(await h.executor.executed == 1, "reading evidence never resends the input")
    }

    // W07 while the Run is still running with an unknown input in it:
    // stopping is the only control.
    @Test func ui006_needsUserWaitsUntilStopped() async throws {
        let h = try await Harness()
        _ = try await configure(h.client)
        h.upstream.callUser = true
        let s = RunStartModel(client: h.client)
        await s.load()
        s.desktopId = "desk-a"
        await s.start()
        let runId = try #require(s.startedRunId)
        let a = AttentionModel(client: h.client, runId: runId, clock: FastClock())
        await a.detail.follow()
        await a.refreshEvidence()
        #expect(a.branch == .needsUser("model_requested_user"))
        #expect(a.detail.canStop)
        await a.requestStop()
        #expect(a.detail.state == "cancelled")
        #expect(a.branch == .resolved("cancelled"))
        #expect(await h.executor.executed == 0)
    }

    // USG-004: attempts vs inputs; unreported usage is unknown, not 0;
    // money is labelled an estimate.
    @Test func usg004_usageUnknownIsNotZero() async throws {
        let h = try await Harness()
        _ = try await configure(h.client)
        h.upstream.usageReported = false
        let s = RunStartModel(client: h.client)
        await s.load()
        s.desktopId = "desk-a"
        await s.start()
        let d = RunDetailModel(client: h.client, runId: try #require(s.startedRunId), clock: FastClock(), pollMs: 5)
        await d.follow()

        let u = UsageModel(client: h.client, from: Date(timeIntervalSinceNow: -3600), to: Date(timeIntervalSinceNow: 3600))
        await u.refresh()
        #expect(u.problem == nil)
        #expect(u.attempts == 3)
        #expect(u.missingUsage == 3)
        // Real inputs are a separate count from model attempts: the
        // Runtime's receipts of this caller's unit Runs.
        #expect(u.confirmedActions == 3)
        #expect(u.coverageText == "0/3 次尝试报告了用量")
        #expect(u.tokenText.total == "未知 / 未报告")
        #expect(u.costText.contains("总额未知"))
        #expect(u.billNote.contains("不是上游账单"))
        #expect(Format.tokens(.int(0)) == "0 / 明确报告")
        #expect(Format.tokens(.null) == "未知 / 未报告")
    }

    // The pages reach the service in process only; no socket of its own.
    @Test func inProcessClientPassesServiceErrorsThrough() async throws {
        let h = try await Harness()
        let c = InProcessContractClient(router: h.router, guiCapabilities: { .obj([]) })
        let list = try await c.send("ai.connections.list")
        #expect(list["items"] != nil)
        do {
            _ = try await c.send("ai.connections.get", .obj([("connectionId", .string("nope"))]))
            Issue.record("expected NOT_FOUND")
        } catch let e as ContractError {
            #expect(e.code == .notFound)
        }
        // runtime.capabilities is the Runtime's own method now.
        do {
            _ = try await c.send("runtime.capabilities")
            Issue.record("expected UNSUPPORTED_COMMAND")
        } catch let e as ContractError {
            #expect(e.code == .unsupportedCommand)
        }
    }

    // Every page instantiates and lays out once in an NSHostingView.
    @Test func renderSmoke() async throws {
        let h = try await Harness()
        let c = h.client
        var views: [AnyView] = [
            AnyView(ConnectionsView(model: ConnectionsModel(client: c))),
            AnyView(ConnectionEditorView(model: ConnectionEditorModel(client: c, mode: .create))),
            AnyView(ProfilesView(model: ProfilesModel(client: c))),
            AnyView(CapabilityTestView(model: CapabilityTestModel(client: c))),
            AnyView(RunStartView(model: RunStartModel(client: c))),
            AnyView(RunDetailView(model: RunDetailModel(client: c, runId: "run-none"))),
            AnyView(AttentionView(model: AttentionModel(client: c, runId: "run-none"))),
            AnyView(UsageView(model: UsageModel(client: c))),
        ]
        let settings = AISettingsModel(client: c)
        let nav = ShellNavigation(section: .settings)
        let entries = SettingsPage.allCases.compactMap { settings.view(for: $0, navigation: nav) }
        #expect(entries.count == AISettingsModel.entries.count)
        #expect(settings.view(for: .general, navigation: nav) == nil)
        views += entries
        // T27 / D32: the AI/GUI pages have no sidebar or window of their own.
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/AgentDesktopAIUI")
        for file in try FileManager.default.contentsOfDirectory(atPath: sources.path) + (try FileManager.default.contentsOfDirectory(atPath: sources.appendingPathComponent("Pages").path).map { "Pages/" + $0 }) where file.hasSuffix(".swift") {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            #expect(!text.contains("NavigationSplitView"), "\(file) brings back a separate sidebar")
        }
        for v in views {
            let host = NSHostingView(rootView: v.frame(width: 1440, height: 1000))
            host.frame = NSRect(x: 0, y: 0, width: 1440, height: 1000)
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.width > 0)
        }
    }
}
