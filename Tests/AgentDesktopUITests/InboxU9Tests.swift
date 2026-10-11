import AgentDesktopProtocol
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AgentDesktopUI

private final class ScopeChangingRuntime: RuntimePort, @unchecked Sendable {
    let inner: MockRuntime
    var isSample: Bool { true }
    var changeOn: String?
    var change: (@Sendable () async -> Void)?
    init(_ inner: MockRuntime) { self.inner = inner }
    func call(_ method: String, _ params: JSONValue, context: RequestContext) async throws -> JSONValue {
        let result = try await inner.call(method, params, context: context)
        if method == changeOn { await change?() }
        return result
    }
    func subscribe(after: Int?) async throws -> AsyncThrowingStream<JSONValue, Error> {
        try await inner.subscribe(after: after)
    }
}

/// U9: Inbox (Hub W06), 核实 (W07), 诊断导出 (W08) over the mock, whose
/// answers are checked against the runtime/1 schemas on every call.
@MainActor
@Suite("Inbox, 核实, 诊断 (U9)", .serialized)
struct InboxU9Tests {
    /// The sample plus the Inbox sample on 文本编辑 (desk_002): run_004
    /// ended unknown with action req_008, run_005 waiting for a person.
    func scenario() async -> (MockRuntime, ShellStore, unknown: String, question: String) {
        let m = MockRuntime.sample()
        let (u, q) = m.addInboxSample(desktopId: "desk_002")
        let store = ShellStore(runtime: m, clock: StillClock(), allowSubscription: false)
        await store.start()
        store.stop()
        return (m, store, u, q)
    }

    func unknownItemId(_ m: MockRuntime, run: String) async throws -> String {
        let list = try await m.call("inbox.list", .obj([("kind", .string("unknown_reference")), ("runId", .string(run))]))
        return try #require(list["items"]?.arrayValue?.first?["inboxId"]?.stringValue)
    }

    @Test func listShowsBothKindsOpenAndFilters() async throws {
        let (m, store, u, q) = await scenario()
        #expect(store.offers("inbox.list") && store.offers("run.reconcile") && store.offers("diagnostics.export"))
        let loader = InboxListLoader(runtime: m)
        await loader.reload()
        #expect(loader.state == .loaded)
        let kinds = Set(loader.items.compactMap { $0["kind"]?.stringValue })
        #expect(kinds == ["unknown_reference", "question"])
        // The sample's run_003 has an unknown action too, still running.
        #expect(loader.items.contains { $0["runId"]?.stringValue == u })
        #expect(loader.items.contains { $0["runId"]?.stringValue == q })
        // inbox.list leaves the reconciliations to inbox.show.
        #expect(loader.items.allSatisfy { $0["reconciliations"] == nil })

        await loader.apply(.init(state: "open", kind: "question"))
        #expect(loader.items.count == 1 && loader.items[0]["question"]?["reason"]?.stringValue == "login_required")
        await loader.apply(.init(state: "resolved"))
        #expect(loader.state == .empty)
        #expect(m.contractViolations.isEmpty)
    }

    @Test func draftNeedsAVerdictAndKeepsTheLimits() {
        #expect(ReconcileDraft().problem == "请选择核实结论。")
        #expect(ReconcileDraft(verdict: "executed").problem == nil)
        #expect(ReconcileDraft(verdict: "executed", note: String(repeating: "字", count: 1025)).problem != nil)
        #expect(ReconcileDraft(verdict: "executed", evidence: (1...9).map { "ref:\($0)" }.joined(separator: "\n")).problem != nil)
        #expect(ReconcileDraft(verdict: "executed", evidence: String(repeating: "x", count: 257)).problem != nil)
        #expect(ReconcileDraft(verdict: "executed", evidence: " a \n\n b ").evidenceRefs == ["a", "b"])
    }

    // E2E-08 / HB-UI-06: a reconciliation is appended; the Run's outcome,
    // the receipt and the request stay unknown; nothing is sent again.
    @Test func reconcileOnlyAppends() async throws {
        let (m, _, u, _) = await scenario()
        let id = try await unknownItemId(m, run: u)
        let model = InboxItemModel(runtime: m, inboxId: id)
        await model.load()
        #expect(model.canReconcile)
        let action = try #require(model.item?["action"]?["requestId"]?.stringValue)

        model.draft = ReconcileDraft(verdict: "still_unknown", note: "应用里看不出来")
        await model.reconcile()
        #expect(model.problem == nil)
        #expect(model.item?["state"]?.stringValue == "open")
        #expect(model.item?["revision"]?.intValue == 1)
        #expect(model.draft == ReconcileDraft())

        model.draft = ReconcileDraft(verdict: "not_executed", source: "external_reference", evidence: "app-log:42")
        await model.reconcile()
        #expect(model.item?["state"]?.stringValue == "resolved")
        #expect(model.item?["resolution"]?["verdict"]?.stringValue == "not_executed")
        let recs = model.item?["reconciliations"]?.arrayValue ?? []
        #expect(recs.map { $0["verdict"]?.stringValue } == ["still_unknown", "not_executed"])
        #expect(recs[0]["note"]?.stringValue == "应用里看不出来")
        #expect(recs[1]["evidenceRefs"]?.arrayValue?.first?.stringValue == "app-log:42")
        #expect(!model.canReconcile)

        let run = try await m.call("run.show", .obj([("runId", .string(u))]))
        #expect(run["outcome"]?.stringValue == "unknown")
        let request = try await m.call("request.show", .obj([("requestId", .string(action))]))
        #expect(request["state"]?.stringValue == "unknown")
        #expect(!m.callLog.contains("act"))
        #expect(m.callLog.filter { $0 == "run.reconcile" }.count == 2)
        #expect(m.contractViolations.isEmpty)
    }

    @Test func notBeforeTheRunIsQuiet() async throws {
        let (m, _, _, _) = await scenario()
        // run_003 (sample) has an unknown action and is still running.
        let id = try await unknownItemId(m, run: "run_003")
        let model = InboxItemModel(runtime: m, inboxId: id)
        await model.load()
        #expect(!model.canReconcile)
        model.draft = ReconcileDraft(verdict: "executed")
        await model.reconcile()
        #expect(!m.callLog.contains("run.reconcile"))
    }

    // A write that lost to another one re-reads and leaves the decision to
    // the person: the draft stays, nothing is resubmitted.
    @Test func conflictReReadsAndDoesNotResubmit() async throws {
        let (m, _, u, _) = await scenario()
        let id = try await unknownItemId(m, run: u)
        let model = InboxItemModel(runtime: m, inboxId: id)
        await model.load()
        let action = try #require(model.item?["action"]?["requestId"]?.stringValue)
        _ = try await m.call("run.reconcile", .obj([("runId", .string(u)), ("actionRequestId", .string(action)),
                                                    ("verdict", .string("still_unknown")), ("expectedRevision", .int(0))]))
        model.draft = ReconcileDraft(verdict: "executed")
        await model.reconcile()
        #expect(model.conflictNote != nil)
        #expect(model.problem == nil)
        #expect(model.item?["revision"]?.intValue == 1)
        #expect(model.draft.verdict == "executed")
        #expect(m.callLog.filter { $0 == "run.reconcile" }.count == 2)
    }

    // HB-UI-05: stopping is two steps; accepted is 停止中 until the Run
    // has ended with its quiescence confirmed.
    @Test func stopWaitingRunIsTwoSteps() async throws {
        let (m, _, _, q) = await scenario()
        let model = InboxItemModel(runtime: m, inboxId: "inb_q_\(q)")
        await model.load()
        #expect(model.canStop)
        #expect(model.stopProgress == nil)
        await model.stopRun()
        #expect(model.problem == nil)
        #expect(model.stopAnswer?["phase"]?.stringValue == "stopping")
        #expect(model.stopProgress?.text == "停止中：等待输入静止")
        #expect(model.item?["resolution"]?["how"]?.stringValue == "run_cancelled")
        // The item says the stop was asked for, never that the Run stopped.
        #expect(InboxText.state(model.item!).text == "已请求停止")
        #expect(!model.canStop)

        m.confirmQuiescence(q)
        await model.load()
        #expect(model.stopProgress?.text == "已停止")
        #expect(m.callLog.filter { $0 == "inbox.resolve" }.count == 1)
        #expect(m.contractViolations.isEmpty)
    }

    // HB-UI-07: a preview writes nothing; the export is read back whole and
    // the page lists what it never holds.
    @Test func diagnosticsPreviewThenExport() async throws {
        let (m, _, _, _) = await scenario()
        let model = DiagnosticsExportModel(runtime: m)
        model.chosen.remove("authorization")
        await model.runPreview()
        #expect(model.problem == nil)
        #expect(model.export == nil)
        #expect(!m.callLog.contains("artifact.read"))
        let names = model.preview?["sections"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        #expect(names == DiagnosticsExportModel.sections.filter { $0 != "authorization" })
        #expect(model.preview?["excluded"]?.arrayValue?.contains(.string("credentials and tokens")) == true)

        await model.runExport()
        let e = try #require(model.export)
        #expect(e.artifactId.hasPrefix("art_diag_"))
        #expect(!e.data.isEmpty)
        #expect(!String(decoding: e.data, as: UTF8.self).contains("adt1_"))
        #expect(m.contractViolations.isEmpty)

        model.chosen = []
        #expect(!model.canRun)
    }

    @Test func diagnosticsScopeChangesRequireANewPreviewAndDiscardOldBytes() async throws {
        let (m, _, _, _) = await scenario()
        let model = DiagnosticsExportModel(runtime: m)
        await model.runExport()
        #expect(!m.callLog.contains("diagnostics.export"))
        await model.runPreview()
        #expect(model.canExport)
        await model.runExport()
        #expect(model.export != nil)
        model.chosen.remove("authorization")
        #expect(model.preview == nil && model.export == nil && !model.canExport)
        await model.runPreview()
        await model.runExport()
        #expect(model.export != nil)
        m.failNext("diagnostics.export", code: "execution_failed")
        await model.runExport()
        #expect(model.export == nil && model.problem != nil)
        model.window = .week
        #expect(model.preview == nil && !model.canExport)
    }

    @Test func repliesFromAnOldScopeCannotRestorePreviewOrExport() async throws {
        let (m, _, _, _) = await scenario()
        let runtime = ScopeChangingRuntime(m)
        let model = DiagnosticsExportModel(runtime: runtime)
        runtime.changeOn = "diagnostics.export"
        runtime.change = { await MainActor.run { model.window = .week } }
        await model.runPreview()
        #expect(model.preview == nil && !model.canExport)
        runtime.changeOn = nil
        await model.runPreview()
        runtime.changeOn = "artifact.read"
        runtime.change = { await MainActor.run { _ = model.chosen.remove("authorization") } }
        await model.runExport()
        #expect(model.export == nil && model.preview == nil && !model.canExport)
    }

    @Test func reconciliationLimitsCountUnicodeScalars() {
        let emoji = "👍🏽"
        #expect(ReconcileDraft(verdict: "executed", note: String(repeating: emoji, count: 512)).problem == nil)
        #expect(ReconcileDraft(verdict: "executed", note: String(repeating: emoji, count: 513)).problem != nil)
        #expect(ReconcileDraft(verdict: "executed", evidence: String(repeating: emoji, count: 128)).problem == nil)
        #expect(ReconcileDraft(verdict: "executed", evidence: String(repeating: emoji, count: 129)).problem != nil)
    }

    @Test func emptyDefaultInboxKeepsItsFiltersVisible() async {
        let m = MockRuntime()
        let store = ShellStore(runtime: m, clock: StillClock(), allowSubscription: false)
        let loader = InboxListLoader(runtime: m)
        await loader.reload()
        let page = InboxPage(store: store, navigation: ShellNavigation(), loader: loader)
        guard case .loaded = page.pageState else { Issue.record("empty Inbox hides its filters"); return }
    }

    @Test func failedDetailRefreshRetainsCachedHistoryButDisablesWrites() async throws {
        let (m, _, run, _) = await scenario()
        let id = try await unknownItemId(m, run: run)
        let model = InboxItemModel(runtime: m, inboxId: id)
        await model.load()
        let cached = model.item
        model.draft = ReconcileDraft(verdict: "not_executed", note: "保留草稿")
        m.failNext("inbox.show", code: "runtime_offline")
        await model.load()
        #expect(model.item == cached && model.syncedAt != nil)
        #expect(!model.canReconcile && !model.canStop)
        #expect(model.draft.note == "保留草稿")
    }

    @Test func words() {
        #expect(InboxText.verdict("not_executed") == "未执行")
        #expect(InboxText.source("operator_attestation") == "本人确认")
        #expect(InboxText.state(.obj([("state", .string("open"))])).text == "待处理")
        #expect(InboxText.state(.obj([("state", .string("resolved")),
                                      ("resolution", .obj([("how", .string("reconciled")), ("verdict", .string("executed"))]))])).text
                == "已核实：已执行")
        #expect(InboxText.questionReason("login_required") == "需要登录")
        #expect(DiagnosticsExportModel.sections.allSatisfy { DiagnosticsExportModel.sectionName($0) != $0 })
    }

    // MARK: Renders (AGENTDESKTOP_UI_SNAPSHOTS=<dir> keeps the PNGs)

    func write<V: View>(_ name: String, _ view: V) throws {
        let png = try #require(SnapshotRenderer.png(view), "render \(name)")
        let rep = try #require(NSBitmapImageRep(data: png))
        #expect(rep.pixelsWide == 1440 && rep.pixelsHigh == 1000)
        try FileManager.default.createDirectory(at: RenderTests.outDir, withIntermediateDirectories: true)
        try png.write(to: RenderTests.outDir.appendingPathComponent(name + ".png"))
    }

    func frame<V: View>(_ store: ShellStore, _ section: MainSection, @ViewBuilder _ page: () -> V) -> some View {
        MainFrame(selection: .constant(section), runtime: StatusText("本机服务就绪", .running), stopAll: {},
                  desktopNames: store.desktops.map { d in
                      (id: d["desktopId"]!.stringValue!, name: d["name"]!.stringValue!,
                       active: store.activeRuns.contains { $0["desktopId"] == d["desktopId"] })
                  },
                  counts: [.desktops: store.desktops.count, .runs: store.activeRuns.count],
                  statusLeft: "\(store.desktops.count) 个 Desktop · \(store.activeRuns.count) 个运行进行中",
                  statusRight: "同步于 —", isSample: true, page: page)
    }

    @Test func renders() async throws {
        let (m, store, u, q) = await scenario()
        let nav = ShellNavigation(section: .inbox)
        let id = try await unknownItemId(m, run: u)

        let list = InboxListLoader(runtime: m)
        await list.reload()
        try write("W06-inbox", frame(store, .inbox) { InboxPage(store: store, navigation: nav, loader: list) })

        let item = InboxItemModel(runtime: m, inboxId: id)
        await item.load()
        item.draft = ReconcileDraft(verdict: "not_executed", note: "应用的发送记录里没有这一条", evidence: "app-log:42")
        try write("W06-inbox-unknown-detail", frame(store, .inbox) {
            ScrollView { InboxItemDetailView(store: store, navigation: nav, model: item).padding(ADLayout.contentPadding) }
        })

        await item.reconcile()
        try write("W07-reconciled-outcome-still-unknown", frame(store, .inbox) {
            ScrollView { InboxItemDetailView(store: store, navigation: nav, model: item).padding(ADLayout.contentPadding) }
        })

        let question = InboxItemModel(runtime: m, inboxId: "inb_q_\(q)")
        await question.load()
        await question.stopRun()
        try write("W06-question-stopping", frame(store, .inbox) {
            ScrollView { InboxItemDetailView(store: store, navigation: nav, model: question).padding(ADLayout.contentPadding) }
        })

        let diag = DiagnosticsExportModel(runtime: m)
        await diag.runPreview()
        try write("W08-diagnostics-preview", frame(store, .settings) {
            ScrollView { DiagnosticsExportPanel(model: diag, connected: true).padding(ADLayout.contentPadding) }
        })
        #expect(m.contractViolations.isEmpty)
    }
}
