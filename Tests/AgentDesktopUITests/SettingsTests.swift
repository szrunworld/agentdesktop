import AgentDesktopProtocol
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AgentDesktopUI

// Lane UI-D (U6 设置). Component level only: the pages over the Mock
// Runtime, whose ai.* answers are checked against the contract on every
// call. Real Runtime, real window and interaction are page acceptance
// (02 §2.2) and not done here.

@MainActor
private func settled(_ what: String, _ check: () -> Bool) async throws {
    for _ in 0..<400 {
        if check() { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    Issue.record("timed out waiting for \(what)")
}

private func code(_ body: () async throws -> Void) async -> String? {
    do { try await body(); return nil } catch let e as RuntimeError { return e.code } catch { return "other" }
}

private func freshDefaults() -> UserDefaults {
    let name = "agentdesktop-ui-d-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

/// Every String reachable from a value's stored properties.
private func strings(in value: Any, depth: Int = 0) -> [String] {
    guard depth < 6 else { return [] }
    if let s = value as? String { return [s] }
    if let v = value as? JSONValue { return [v.encoded()] }
    return Mirror(reflecting: value).children.flatMap { strings(in: $0.value, depth: depth + 1) }
}

@MainActor
@Suite("Settings (U6)", .serialized)
struct SettingsTests {
    // MARK: Mock lane

    @Test func everyAIMethodAnswersWithinContract() async throws {
        let m = MockRuntime()
        m.seedSettingsSample()
        m.setAIOperationReads(0)
        let conn = try await m.call("ai.connections.create", .obj([
            ("name", .string("测试连接")), ("protocol", .string("openai_chat")), ("baseUrl", .string("https://api.example.invalid/v1")),
            ("timeoutMs", .int(30000)), ("credential", .obj([("apiKey", .string("sk-synthetic-test"))])),
        ]))
        let cid = conn["connectionId"]!
        #expect(!conn.encoded().contains("sk-synthetic-test"))
        let mp = try await m.call("ai.modelProfiles.create", .obj([
            ("name", .string("m")), ("connectionId", cid), ("connectionRevision", .int(1)), ("modelId", .string("m")),
            ("requestOptions", .obj([])), ("maxOutputTokens", .int(256)),
        ]))
        let gp = try await m.call("ai.profiles.create", .obj([
            ("name", .string("g")), ("modelProfileId", mp["modelProfileId"]!), ("modelProfileRevision", .int(1)),
            ("adapterId", .string("uitars_v1")), ("adapterVersion", .string("1.0.0")), ("promptVersion", .string("p")),
            ("parserVersion", .string("q")), ("coordinateProtocol", .string("normalized_1000")),
            ("limits", MockRuntime.ceilingLimits), ("allowedFallbackProfileRefs", .array([])),
        ]))
        let gid = gp["guiProfileId"]!
        let calls: [(String, JSONValue)] = [
            ("ai.connections.list", .obj([("includeDisabled", .bool(true))])),
            ("ai.connections.get", .obj([("connectionId", cid)])),
            ("ai.connections.update", .obj([("connectionId", cid), ("expectedRevision", .int(1)), ("patch", .obj([("timeoutMs", .int(20000))]))])),
            ("ai.credentials.rotate", .obj([("connectionId", cid), ("expectedRevision", .int(2)), ("credential", .obj([("apiKey", .string("sk-synthetic-2"))]))])),
            ("ai.models.refresh", .obj([("connectionId", cid), ("expectedRevision", .int(3))])),
            ("ai.models.list", .obj([("connectionId", cid)])),
            ("ai.modelProfiles.list", .obj([])),
            ("ai.modelProfiles.get", .obj([("modelProfileId", mp["modelProfileId"]!)])),
            ("ai.modelProfiles.update", .obj([("modelProfileId", mp["modelProfileId"]!), ("expectedRevision", .int(1)), ("patch", .obj([("name", .string("m2"))]))])),
            ("ai.profiles.list", .obj([])),
            ("ai.profiles.get", .obj([("guiProfileId", gid)])),
            ("ai.profiles.update", .obj([("guiProfileId", gid), ("expectedRevision", .int(1)), ("patch", .obj([("name", .string("g2"))]))])),
            ("ai.profiles.default.get", .obj([])),
            ("ai.profiles.setDefault", .obj([("guiProfileId", gid), ("expectedDefaultRevision", .int(2)), ("expectedProfileRevision", .int(2))])),
            ("ai.tests.start", .obj([("guiProfileId", gid), ("expectedRevision", .int(2)), ("fixtureId", .string("synthetic_gui_v1"))])),
            ("ai.usage.summary", .obj([("from", .string("2026-10-01T00:00:00+08:00")), ("to", .string("2026-10-08T00:00:00+08:00"))])),
            ("ai.profiles.disable", .obj([("guiProfileId", gid), ("expectedRevision", .int(2))])),
            ("ai.profiles.delete", .obj([("guiProfileId", gid), ("expectedRevision", .int(3))])),
            ("ai.modelProfiles.disable", .obj([("modelProfileId", mp["modelProfileId"]!), ("expectedRevision", .int(2))])),
            ("ai.modelProfiles.delete", .obj([("modelProfileId", mp["modelProfileId"]!), ("expectedRevision", .int(3))])),
            ("ai.connections.disable", .obj([("connectionId", cid), ("expectedRevision", .int(3))])),
            ("ai.connections.delete", .obj([("connectionId", cid), ("expectedRevision", .int(4))])),
        ]
        var seen: Set<String> = ["ai.connections.create", "ai.modelProfiles.create", "ai.profiles.create"]
        var opId: JSONValue?
        for (method, params) in calls {
            let r = try await m.call(method, params)
            seen.insert(method)
            if method == "ai.tests.start" { opId = r["operationId"] }
        }
        let op = try await m.call("ai.operations.get", .obj([("operationId", opId!)]))
        #expect(op["state"]?.stringValue == "succeeded")
        #expect(op["result"]?["performedDesktopInput"] == .bool(false))
        _ = try await m.call("ai.operations.cancel", .obj([("operationId", opId!)]))
        seen.formUnion(["ai.operations.get", "ai.operations.cancel"])
        #expect(seen == Set(MockRuntime.settingsLaneMethods))
        #expect(m.contractViolations.isEmpty, "\(m.contractViolations)")
        #expect(m.aiCredentialsWritten >= 2)
    }

    @Test func staleRevisionsAndReferencesAreRefusedInRuntimeTerms() async throws {
        let m = MockRuntime()
        m.seedSettingsSample()
        let conns = try await m.call("ai.connections.list", .obj([("includeDisabled", .bool(true))]))["items"]!.arrayValue!
        let local = conns[0]["connectionId"]!
        do {
            _ = try await m.call("ai.connections.disable", .obj([("connectionId", local), ("expectedRevision", .int(1))]))
            Issue.record("expected conflict")
        } catch let e as RuntimeError {
            #expect(e.code == "conflict")
            #expect(e.details?["currentRevision"]?.intValue == 3)
            #expect(e.details?["serviceCode"]?.stringValue == "CONFIG_CONFLICT")
        }
        do {
            _ = try await m.call("ai.connections.delete", .obj([("connectionId", local), ("expectedRevision", .int(3))]))
            Issue.record("expected in_use")
        } catch let e as RuntimeError {
            #expect(e.code == "conflict")
            #expect(e.details?["reason"]?.stringValue == "in_use")
        }
    }

    // MARK: P23 / P24 connections

    @Test func listShowsModelEvidenceAndNoSecret() async throws {
        let m = MockRuntime()
        m.seedSettingsSample()
        let model = SettingsConnectionsModel(runtime: m)
        await model.refresh()
        #expect(model.connections.map(\.name) == ["本地 GUI 连接", "自定义兼容服务"])
        let local = model.connections[0]
        #expect(model.model(for: local)?.modelId == "gui-model-v1")
        #expect(AIEvidence.status(model.model(for: local), connectionRevision: local.revision).text == "图像 / GUI 已验证")
        #expect(AIEvidence.status(model.model(for: model.connections[1]), connectionRevision: 1).text == "尚未测试")
        #expect(model.connections.allSatisfy { $0.credentialSet })
    }

    @Test func createSendsTheKeyOnceAndKeepsItNowhere() async throws {
        let m = MockRuntime()
        let key = "sk-synthetic-ui-d-canary"
        let editor = SettingsConnectionEditorModel(runtime: m, mode: .create)
        editor.name = "本机模型"
        editor.baseUrl = "http://127.0.0.1:8000/v1"
        editor.secretInput = key
        editor.modelId = "gui-model-v1"
        let ok = await editor.save()
        #expect(ok)
        #expect(editor.secretInput.isEmpty)
        #expect(editor.credentialSet)
        #expect(editor.mode != .create)
        #expect(!strings(in: editor).contains { $0.contains(key) })
        #expect(m.aiCredentialsWritten == 1)
        let mps = try await m.call("ai.modelProfiles.list", .obj([]))["items"]!.arrayValue!
        #expect(mps.first?["modelId"]?.stringValue == "gui-model-v1")
        // A second click saves the same connection; it does not create another.
        _ = await editor.save()
        let count = try await m.call("ai.connections.list", .obj([]))["items"]!.arrayValue!.count
        #expect(count == 1)
    }

    @Test func badEndpointIsRefusedBeforeAnyCallAndTheKeyIsCleared() async throws {
        let m = MockRuntime()
        let editor = SettingsConnectionEditorModel(runtime: m, mode: .create)
        editor.name = "远程"
        editor.baseUrl = "http://203.0.113.5/v1"
        editor.secretInput = "sk-synthetic"
        #expect(await editor.save() == false)
        #expect(editor.fieldErrors["baseUrl"] != nil)
        #expect(editor.secretInput.isEmpty)
        #expect(!m.callLog.contains("ai.connections.create"))
    }

    @Test func editConflictKeepsTheDraftAndShowsTheServerRevision() async throws {
        let m = MockRuntime()
        let id = m.addAIConnection(name: "A", baseUrl: "https://a.example.invalid/v1")
        let editor = SettingsConnectionEditorModel(runtime: m, mode: .edit(id))
        await editor.load()
        #expect(editor.revision == 1)
        editor.timeoutMs = 12000
        m.touchAIConnection(id, name: "B")
        #expect(await editor.save() == false)
        #expect(editor.failure?.isConflict == true)
        #expect(editor.failure?.currentRevision == 2)
        #expect(editor.timeoutMs == 12000)
        await editor.reloadKeepingDraft()
        #expect(editor.revision == 2)
        #expect(editor.name == "B")
        #expect(editor.timeoutMs == 12000)
        #expect(await editor.save())
        #expect(editor.revision == 3)
    }

    @Test func rotateWritesANewCredentialWithTheRevision() async throws {
        let m = MockRuntime()
        let id = m.addAIConnection(name: "A", baseUrl: "https://a.example.invalid/v1")
        let editor = SettingsConnectionEditorModel(runtime: m, mode: .edit(id))
        await editor.load()
        await editor.rotate()
        #expect(editor.fieldErrors["apiKey"] != nil)
        editor.secretInput = "sk-synthetic-rotated"
        await editor.rotate()
        #expect(editor.secretInput.isEmpty)
        #expect(editor.revision == 2)
        #expect(m.aiCredentialsWritten == 2)
        #expect(!strings(in: editor).contains { $0.contains("sk-synthetic-rotated") })
    }

    @Test func modelRefreshPollsTheOperation() async throws {
        let m = MockRuntime()
        m.setAIOperationReads(2)
        let id = m.addAIConnection(name: "A", baseUrl: "https://a.example.invalid/v1")
        let editor = SettingsConnectionEditorModel(runtime: m, mode: .edit(id), clock: FastClock())
        await editor.load()
        await editor.refreshModels()
        #expect(editor.models == ["gui-model-v1", "vision-model-demo"])
        #expect(m.callLog.filter { $0 == "ai.operations.get" }.count == 3)
    }

    @Test func disableAndDeleteWaitForConfirmationAndCarryTheRevision() async throws {
        let m = MockRuntime()
        m.seedSettingsSample()
        let store = ShellStore(runtime: m, clock: StillClock())
        await store.start()
        store.stop()
        let models = SettingsModels(store: store, preferences: SettingsPreferences(defaults: freshDefaults()))
        await models.connections.refresh()
        let local = models.connections.connections[0]
        // Asking only prepares the dialog; nothing is sent until confirmed.
        let c = SettingsConfirmation(action: .deleteConnection, id: local.id, name: local.name)
        #expect(c.confirmTitle == "删除")
        #expect(!m.callLog.contains("ai.connections.delete"))
        await models.connections.delete(local)
        #expect(models.connections.failure?.problem.title == "仍在被使用")
        await models.connections.disable(local)
        #expect(models.connections.failure == nil)
        #expect(models.connections.connections.first { $0.id == local.id }?.enabled == false)
        #expect(m.contractViolations.isEmpty)
    }

    // MARK: P25 profiles

    @Test func profileSaveMakesAModelProfileAndANewRevision() async throws {
        let m = MockRuntime()
        m.seedSettingsSample()
        let model = SettingsProfilesModel(runtime: m, gui: nil)
        await model.refresh()
        #expect(model.selected?.name == "默认 GUI 配置")
        #expect(model.selected?.revision == 7)
        #expect(model.adapters == ["uitars_v1"])
        model.modelId = "gui-model-v2"
        await model.save()
        #expect(model.failure == nil)
        #expect(model.selected?.revision == 8)
        #expect(model.modelProfiles.contains { $0.modelId == "gui-model-v2" })
        // A new profile on the disabled connection is refused locally.
        model.newProfile()
        model.connectionId = model.connections.first { !$0.enabled }?.id
        model.modelId = "x"
        await model.save()
        #expect(model.fieldErrors["connection"] != nil)
    }

    @Test func setDefaultUsesBothRevisions() async throws {
        let m = MockRuntime()
        m.seedSettingsSample()
        let model = SettingsProfilesModel(runtime: m, gui: .obj([("features", .obj([("fixtureAdapterEnabled", .bool(true))]))]))
        await model.refresh()
        #expect(model.adapters.contains("fixture_json_v1"))
        model.newProfile()
        model.name = "第二个"
        model.modelId = "gui-model-v1"
        await model.save()
        let second = try #require(model.profiles.first { $0.name == "第二个" })
        let before = model.defaultRevision
        await model.setDefault(second)
        #expect(model.defaultId == second.id)
        #expect(model.defaultRevision == before + 1)
        await model.disable(second)
        #expect(model.defaultId == nil)
    }

    // MARK: P26 capability test

    @Test func capabilityTestPollsUntilTheOperationEnds() async throws {
        let m = MockRuntime()
        m.seedSettingsSample()
        m.setAIOperationReads(2)
        let model = SettingsCapabilityTestModel(runtime: m, clock: FastClock(), pollMs: 1)
        await model.load()
        #expect(model.profile?.name == "默认 GUI 配置")
        await model.start()
        #expect(model.phase == .finished("succeeded"))
        #expect(model.levels.allSatisfy { $0.status == .passed })
        #expect(model.performedDesktopInput == false)
        #expect(model.summaryBadge?.text == "全部通过")
        #expect(m.contractViolations.isEmpty)
    }

    @Test func aFailedLevelSkipsTheRest() async throws {
        let m = MockRuntime()
        m.seedSettingsSample()
        m.setAIOperationReads(0)
        m.failAITests(at: "image_input")
        let model = SettingsCapabilityTestModel(runtime: m, clock: FastClock(), pollMs: 1)
        await model.load()
        await model.start()
        #expect(model.levels.map(\.status) == [.passed, .passed, .failed, .skipped])
        #expect(model.summaryBadge?.text == "部分未通过")
    }

    @Test func cancelEndsOnlyWhenTheOperationSaysSo() async throws {
        let m = MockRuntime()
        m.seedSettingsSample()
        m.setAIOperationReads(1000)
        let model = SettingsCapabilityTestModel(runtime: m, clock: FastClock(), pollMs: 1)
        await model.load()
        let run = Task { await model.start() }
        try await settled("running") { model.phase == .running }
        await model.cancel()
        #expect(model.phase == .finished("cancelled"))
        await run.value
        #expect(model.levels.allSatisfy { $0.status == .pending })
    }

    @Test func aConnectionsTestPicksAProfileOnThatConnectionFromAFreshRead() async throws {
        let m = MockRuntime()
        m.seedSettingsSample()
        let other = m.addAIConnection(name: "第三个", baseUrl: "https://c.example.invalid/v1")
        let mp = m.addAIModelProfile(connectionId: other, modelId: "third-model")
        let gid = m.addAIGuiProfile(name: "第三个配置", modelProfileId: mp)
        let model = SettingsCapabilityTestModel(runtime: m, clock: FastClock(), pollMs: 1)
        await model.load()
        #expect(model.profile?.name == "默认 GUI 配置")
        model.pendingConnectionId = other
        await model.load()
        #expect(model.guiProfileId == gid)
        // A connection no GUI profile uses selects nothing and says why.
        let bare = m.addAIConnection(name: "空", baseUrl: "https://d.example.invalid/v1")
        model.pendingConnectionId = bare
        await model.load()
        #expect(model.guiProfileId == nil)
        #expect(model.selectionNote != nil)
        #expect(!model.canStart)
    }

    @Test func profilesMadeAfterTheFirstVisitAreTestable() async throws {
        let m = MockRuntime()
        m.seedSettingsSample()
        let model = SettingsCapabilityTestModel(runtime: m, clock: FastClock(), pollMs: 1)
        await model.load()
        let mp = m.addAIModelProfile(connectionId: "conn_001", modelId: "late-model")
        let late = m.addAIGuiProfile(name: "后来的配置", modelProfileId: mp)
        model.guiProfileId = late
        await model.load()
        #expect(model.profile?.name == "后来的配置")
        #expect(model.canStart)
    }

    @Test func aLostStatusReadCanBeResumed() async throws {
        let m = MockRuntime()
        m.seedSettingsSample()
        m.setAIOperationReads(1)
        m.failNext("ai.operations.get", code: "internal_error")
        let model = SettingsCapabilityTestModel(runtime: m, clock: FastClock(), pollMs: 1)
        await model.load()
        await model.start()
        #expect(model.phase == .lost)
        #expect(model.summaryBadge?.text == "状态未知")
        await model.resume()
        #expect(model.phase == .finished("succeeded"))
        #expect(model.failure == nil)
    }

    @Test func aFailedCancelAfterLostReadCanBeResumed() async throws {
        let m = MockRuntime()
        m.seedSettingsSample()
        m.setAIOperationReads(1)
        m.failNext("ai.operations.get", code: "internal_error")
        let model = SettingsCapabilityTestModel(runtime: m, clock: FastClock(), pollMs: 1)
        await model.load()
        await model.start()
        #expect(model.phase == .lost)
        m.failNext("ai.operations.cancel", code: "connection_lost")
        await model.cancel()
        #expect(model.phase == .lost)
        #expect(model.failure != nil)
        await model.resume()
        #expect(model.phase == .finished("succeeded"))
    }

    @Test func reportedDesktopInputIsShownAsAnError() {
        #expect(SettingsCapabilityTestPage.inputText(false) == "0 次")
        #expect(SettingsCapabilityTestPage.inputText(true).contains("异常"))
        #expect(!SettingsCapabilityTestPage.inputText(nil).hasPrefix("0"))
    }

    // MARK: P30 usage

    @Test func unreportedUsageStaysUnknown() async throws {
        let m = MockRuntime()
        m.setAIUsage(attempts: 3, confirmedActions: 1, attemptsMissingUsage: 3, totalTokens: nil)
        let model = SettingsUsageModel(runtime: m)
        await model.refresh()
        #expect(model.attempts == 3)
        #expect(model.tokenText == "未知")
        #expect(model.costText.contains("费用未知"))
        #expect(model.costText == "费用未知，不按 ¥0 显示")
        m.setAIUsage(attempts: 4, confirmedActions: 2, attemptsMissingUsage: 1, totalTokens: 2108)
        await model.refresh()
        #expect(model.tokenText == 2108.formatted(.number))
        #expect(model.tokenNote.contains("3/4"))
    }

    // MARK: P21 / P22 / P02

    @Test func preferencesSaveOnlyOnRequestAndPersist() {
        let d = freshDefaults()
        let p = SettingsPreferences(defaults: d)
        #expect(p.saved.defaultDesktopSize == .standard)
        p.draft.defaultDesktopSize = SettingsDesktopSize.choices[2]
        p.draft.showAgentCursor = false
        #expect(p.isDirty)
        #expect(SettingsPreferences(defaults: d).saved.showAgentCursor)
        p.save()
        #expect(!p.isDirty)
        let again = SettingsPreferences(defaults: d)
        #expect(again.saved.defaultDesktopSize.label == "1920 × 1080")
        #expect(again.saved.showAgentCursor == false)
    }

    @Test func permissionsComeFromCapabilitiesAndNothingIsRequested() async throws {
        let m = MockRuntime()
        m.screenRecording = "granted"
        m.accessibility = "denied"
        let store = ShellStore(runtime: m, clock: StillClock())
        await store.start()
        store.stop()
        var opened: [SettingsPermission] = []
        let model = SettingsPermissionsModel(runtime: m, capabilities: store.capabilities)
        #expect(model.state(.screenRecording) == "granted")
        #expect(model.state(.accessibility) == "denied")
        #expect(!model.allGranted)
        _ = SettingsPermissionsPage(model: model, connected: true, open: { opened.append($0) })
        #expect(opened.isEmpty)
        m.accessibility = "granted"
        await model.recheck()
        #expect(model.allGranted)
        #expect(SettingsPermission.accessibility.systemSettingsURL.absoluteString.contains("Privacy_Accessibility"))
    }

    @Test func permissionsUnknownWithoutCapabilities() {
        let model = SettingsPermissionsModel(runtime: MockRuntime(), capabilities: nil)
        #expect(model.states == nil)
        #expect(model.state(.screenRecording) == "unknown")
        #expect(!model.allGranted)
    }

    @Test func aiEntriesFollowRuntimeCapabilities() async throws {
        let m = MockRuntime()
        let store = ShellStore(runtime: m, clock: StillClock())
        await store.start()
        store.stop()
        #expect(store.offers("ai.connections.list"))
        let models = SettingsModels(store: store, preferences: SettingsPreferences(defaults: freshDefaults()))
        #expect(models.offers("ai.usage.summary"))
        let bare = SettingsModels(store: ShellStore(runtime: m, clock: StillClock()),
                                  preferences: SettingsPreferences(defaults: freshDefaults()))
        #expect(!bare.offers("ai.connections.list"))
        await bare.refreshCapabilities()
        #expect(bare.offers("ai.connections.list"))
    }

    @Test func failureWordsForServiceCodes() {
        let inUse = SettingsFailure(RuntimeError("conflict", "x", phase: .handler,
                                                 details: .obj([("reason", .string("in_use")), ("serviceCode", .string("RESOURCE_IN_USE"))])))
        #expect(inUse.problem.title == "仍在被使用")
        #expect(!inUse.isConflict)
        let stale = SettingsFailure(RuntimeError("conflict", "x", phase: .handler,
                                                 details: .obj([("currentRevision", .int(4)), ("serviceCode", .string("CONFIG_CONFLICT"))])))
        #expect(stale.isConflict)
        #expect(stale.extra.first?.contains("r4") == true)
    }
}

/// Off-screen renders of the Settings pages at 1440 × 1000, beside
/// docs/design/v2/P02, P21–P26, P30. With AGENTDESKTOP_UI_SNAPSHOTS=<dir>
/// they are written there (docs/acceptance/ui-d for the PR).
@MainActor
@Suite("Settings renders", .serialized)
struct SettingsRenderTests {
    static let outDir: URL = {
        if let d = ProcessInfo.processInfo.environment["AGENTDESKTOP_UI_SNAPSHOTS"], !d.isEmpty {
            return URL(fileURLWithPath: d, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("agentdesktop-ui-d-\(getpid())", isDirectory: true)
    }()

    func write<V: View>(_ name: String, _ view: V) throws {
        let png = try #require(SnapshotRenderer.png(view), "render \(name)")
        let rep = try #require(NSBitmapImageRep(data: png))
        #expect(rep.pixelsWide == 1440 && rep.pixelsHigh == 1000)
        try FileManager.default.createDirectory(at: Self.outDir, withIntermediateDirectories: true)
        try png.write(to: Self.outDir.appendingPathComponent(name + ".png"))
    }

    func frame<V: View>(_ store: ShellStore, @ViewBuilder _ page: () -> V) -> some View {
        MainFrame(selection: .constant(.settings), runtime: StatusText("本机服务就绪", .running), stopAll: {},
                  desktopNames: [], counts: [:], statusLeft: "样例数据", statusRight: "Mock Runtime", isSample: true, page: page)
    }

    func setup(_ page: SettingsPage, accessibility: String = "granted") async -> (MockRuntime, ShellStore, ShellNavigation, SettingsModels) {
        let m = MockRuntime()
        m.seedSettingsSample()
        m.accessibility = accessibility
        m.setAIOperationReads(0)
        let store = ShellStore(runtime: m, clock: StillClock())
        await store.start()
        store.stop()
        let nav = ShellNavigation(section: .settings, settingsPage: page)
        let models = SettingsModels(store: store, preferences: SettingsPreferences(defaults: freshDefaults()), clock: FastClock())
        return (m, store, nav, models)
    }

    func view(_ store: ShellStore, _ nav: ShellNavigation, _ models: SettingsModels) -> some View {
        frame(store) {
            SettingsPageView(store: store, navigation: nav, models: models, openSystemSettings: { _ in }, content: { _ in nil })
        }
    }

    @Test func renders() async throws {
        var (_, store, nav, models) = await setup(.general)
        try write("P21-general", view(store, nav, models))

        (_, store, nav, models) = await setup(.permissions, accessibility: "denied")
        try write("P22-permissions-missing", view(store, nav, models))

        let (_, s2, _, m2) = await setup(.permissions, accessibility: "denied")
        try write("P02-first-use", frame(s2) {
            SettingsFirstUseView(model: m2.permissions, open: { _ in }, onContinue: {}, onSkip: {})
        })

        (_, store, nav, models) = await setup(.aiConnections)
        await models.connections.refresh()
        try write("P23-ai-connections", view(store, nav, models))

        let drawer = SettingsConnectionEditorModel(runtime: store.runtime, mode: .create)
        drawer.baseUrl = "http://127.0.0.1:8000/v1"
        drawer.modelId = "gui-model-v1"
        try write("P24-add-connection", ZStack {
            view(store, nav, models)
            SettingsConnectionDrawer(model: drawer, close: {}, saved: {})
        })

        (_, store, nav, models) = await setup(.guiProfiles)
        await models.profiles.refresh()
        try write("P25-gui-profiles", view(store, nav, models))

        (_, store, nav, models) = await setup(.capabilityTest)
        await models.test.load()
        await models.test.start()
        try write("P26-capability-test", view(store, nav, models))

        (_, store, nav, models) = await setup(.usage)
        await models.usage.refresh()
        try write("P30-usage", view(store, nav, models))

        (_, store, nav, models) = await setup(.verification)
        try write("U9-verification-not-enabled", view(store, nav, models))

        let delete = SettingsConfirmation(action: .deleteConnection, id: "conn_001", name: "本地 GUI 连接")
        try write("P23-confirm-delete", ZStack {
            frame(store) { Color.clear }
            SettingsModal {
                ConfirmationDialog(title: delete.title, message: delete.message, consequences: delete.consequences,
                                   preserved: delete.preserved, confirmTitle: delete.confirmTitle, destructive: true,
                                   cancel: {}, confirm: {})
            }
        })
    }
}
