import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopUI

/// A Runtime that advertises fewer methods than it has: the page must go by
/// runtime.capabilities, not by what it expects to exist.
final class NarrowCapabilitiesRuntime: RuntimePort, @unchecked Sendable {
    let inner: MockRuntime
    let hidden: Set<String>
    var isSample: Bool { inner.isSample }

    init(_ inner: MockRuntime, hiding: Set<String>) {
        self.inner = inner
        self.hidden = hiding
    }

    func call(_ method: String, _ params: JSONValue, context: RequestContext) async throws -> JSONValue {
        let r = try await inner.call(method, params, context: context)
        guard method == "runtime.capabilities", let iface = r["interface"], let methods = iface["methods"]?.arrayValue else { return r }
        return r.setting("interface", iface.setting("methods", .array(methods.filter { !hidden.contains($0["method"]?.stringValue ?? "") })))
    }

    func subscribe(after: Int?) async throws -> AsyncThrowingStream<JSONValue, Error> { try await inner.subscribe(after: after) }
}

// U4 Agents (lane UI-C): component-level checks against the mock Runtime.
// Page acceptance (real Runtime, real window) is not part of these.
@MainActor
@Suite("Agents page (U4)", .serialized)
struct AgentsTests {
    static let now = Date(timeIntervalSince1970: 1_791_446_400 + 60)

    func loaded(_ m: RuntimePort) async -> (ShellStore, AgentsModel) {
        let store = ShellStore(runtime: m, clock: StillClock(), allowSubscription: false)
        await store.start()
        store.stop()
        let model = AgentsModel(store: store, now: { Self.now })
        await model.load()
        return (store, model)
    }

    @Test func theLaneMethodsAreOfferedAndAnswerWithinTheContract() async throws {
        let m = MockRuntime.agentsSample()
        let (store, model) = await loaded(m)
        for method in MockRuntime.agentsLaneMethods {
            #expect(RuntimeCatalog.implemented.contains(method), "\(method) is not in the implemented catalog")
            #expect(store.offers(method), "\(method) not advertised")
        }
        // The window never decides a pairing: approve and deny are not even modeled.
        #expect(!store.offers("hub.pairing.approve") && !store.offers("hub.pairing.deny"))
        #expect(model.clients.count == 2 && model.connections.filter { $0["role"]?.stringValue == "paired" }.count == 3)
        #expect(model.windowGrants.count == 3 && model.grants.count == 2)
        // (open() loads in its own Task; the test sets the selection and waits itself.)
        model.clientId = "app:mock-001"
        await model.loadDetail("app:mock-001")
        #expect(model.detailProblem == nil, "\(String(describing: model.detailProblem))")
        #expect(model.detail?["connections"]?.arrayValue?.count == 2)
        #expect(m.contractViolations.isEmpty, "\(m.contractViolations)")
    }

    @Test func registrationConnectionAndGrantAreThreeSeparateStates() async throws {
        // HB-UI-01: an app whose grant was revoked may still be registered;
        // a connected app is not therefore allowed anything.
        let m = MockRuntime.agentsSample()
        let (_, model) = await loaded(m)
        let id = "app:mock-002"
        let client = try #require(model.client(id))
        #expect(AgentsText.clientState(client).text == "登记有效")
        #expect(AgentsText.connection(model.connections(of: id).count).text == "在线 · 1 条连接")
        #expect(AgentsText.grantState(model.grant(of: id), now: Self.now).text == "授权有效")
        // Expiry is read from the Runtime's timestamp, not guessed.
        #expect(AgentsText.grantState(model.grant(of: id), now: Self.now.addingTimeInterval(7200)).text == "授权已到期")
        // The code identity level is shown as the Runtime gives it.
        #expect(AgentsText.codeIdentity(client["codeIdentity"]).text.hasPrefix("same_user"))
        #expect(AgentsText.codeIdentity(model.client("app:mock-001")?["codeIdentity"]).text.hasPrefix("verified"))
    }

    @Test func removingAnAppIsAcceptedAndSaysWhatStillRuns() async throws {
        // HB-UI-04 and "已受理, not 已生效": the answer lists the Runtime's
        // facts; Runs stop with quiescence pending; the app is not killed.
        let m = MockRuntime.agentsSample()
        let (store, model) = await loaded(m)
        let id = "app:mock-001"
        #expect(model.activeRuns(of: id) == 1)
        let text = AgentsConfirmationText.make(.revokeClient(id), model: model)
        #expect(text.consequences.contains { $0.contains("1 个未结束的平台运行进入停止流程") })
        #expect(text.preserved.contains { $0.contains("Hub 不结束它的进程") })
        await model.revokeClient(id)
        let r = try #require(model.lastResult)
        #expect(r.accepted && r.title.hasPrefix("已受理"))
        #expect(!r.title.contains("已生效") && !r.facts.joined().contains("已生效"))
        #expect(r.facts.contains { $0.contains("revoked") })
        #expect(r.facts.contains("1 个平台运行停止中（等待执行端确认静止）"))
        #expect(r.facts.contains { $0.contains("Hub 不终止它的进程") })
        #expect(model.client(id)?["state"]?.stringValue == "revoked")
        #expect(model.connections(of: id).isEmpty)
        #expect(model.windowGrants.filter { $0["clientId"]?.stringValue == id }.allSatisfy { $0["state"]?.stringValue == "revoked" })
        #expect(store.runs.first { $0["clientId"]?.stringValue == id }?["phase"]?.stringValue == "stopping")
        #expect(m.contractViolations.isEmpty, "\(m.contractViolations)")
    }

    @Test func narrowingNeverWidensOrExtends() async throws {
        let m = MockRuntime.agentsSample()
        let (_, model) = await loaded(m)
        let id = "app:mock-002"
        let g = try #require(model.grant(of: id))
        let caps = Set(GrantNarrowing.strings(g["capabilities"]))
        let desks = Set(GrantNarrowing.strings(g["desktops"]))
        let apps = Set(GrantNarrowing.strings(g["apps"]))
        // Nothing changed: no call.
        #expect(GrantNarrowing.params(clientId: id, grant: g, keepCapabilities: caps, keepDesktops: desks, keepApps: apps,
                                      period: nil, now: Self.now) == nil)
        // Something never granted cannot be kept.
        #expect(GrantNarrowing.params(clientId: id, grant: g, keepCapabilities: caps.union(["desktop.manage"]), keepDesktops: desks,
                                      keepApps: apps, period: nil, now: Self.now) == nil)
        // A longer period does not extend: durationSeconds is capped by what is left.
        let p = try #require(GrantNarrowing.params(clientId: id, grant: g, keepCapabilities: ["observe", "run"], keepDesktops: desks,
                                                   keepApps: apps, period: 604_800, now: Self.now))
        let left = try #require(GrantNarrowing.remaining(g, now: Self.now))
        #expect(p["durationSeconds"]?.intValue == left)
        #expect(GrantNarrowing.strings(p["capabilities"]) == ["observe", "run"])
        #expect(RuntimeContract.shared.validate(p, "hub_grants_set_params").isEmpty)
        #expect(GrantNarrowing.removed(grant: g, params: p, now: Self.now) == ["去掉能力：操作 act"])
        // Only a shorter period counts as a change.
        let shorter = try #require(GrantNarrowing.params(clientId: id, grant: g, keepCapabilities: caps, keepDesktops: desks,
                                                         keepApps: apps, period: 60, now: Self.now))
        #expect(shorter["durationSeconds"]?.intValue == 60)
        // A revoked or ended grant cannot be narrowed (set would bring it back).
        #expect(GrantNarrowing.params(clientId: id, grant: g.setting("state", .string("revoked")), keepCapabilities: [],
                                      keepDesktops: [], keepApps: [], period: nil, now: Self.now) == nil)
        #expect(GrantNarrowing.params(clientId: id, grant: g, keepCapabilities: [], keepDesktops: [], keepApps: [], period: nil,
                                      now: Self.now.addingTimeInterval(7200)) == nil)

        await model.narrowGrant(id, params: p)
        let r = try #require(model.lastResult)
        #expect(r.accepted && r.title.hasPrefix("已受理"), "\(r)")
        #expect(GrantNarrowing.strings(model.grant(of: id)?["capabilities"]) == ["observe", "run"])
        #expect(model.grant(of: id)?["revision"]?.intValue == 2)
        #expect(m.contractViolations.isEmpty, "\(m.contractViolations)")
    }

    @Test func narrowingEndsWindowGrantsOutsideTheNewScope() async throws {
        let m = MockRuntime.agentsSample()
        let (_, model) = await loaded(m)
        let id = "app:mock-001"
        let g = try #require(model.grant(of: id))
        let p = try #require(GrantNarrowing.params(clientId: id, grant: g, keepCapabilities: Set(GrantNarrowing.strings(g["capabilities"])),
                                                   keepDesktops: Set(GrantNarrowing.strings(g["desktops"])), keepApps: [],
                                                   period: nil, now: Self.now))
        await model.narrowGrant(id, params: p)
        let active = model.windowGrants.filter { $0["clientId"]?.stringValue == id && $0["state"]?.stringValue == "active" }
        #expect(active.isEmpty)
        #expect(model.windowGrants.contains { $0["endedReason"]?.stringValue == "app_removed" })
        #expect(model.connections(of: id).isEmpty, "a narrowed app's connections are cut")
    }

    @Test func windowGrantsShowThreePermissionsAndRevokeOneByOne() async throws {
        let m = MockRuntime.agentsSample()
        let (_, model) = await loaded(m)
        let id = "app:mock-001"
        let list = model.windowGrants(of: id)
        #expect(list.count == 3)
        #expect(list.map { GrantNarrowing.strings($0["permissions"]) } == [["observe", "act"], ["observe", "act", "persist"], ["observe"]])
        #expect(AgentsText.endedReason(list[2]["endedReason"]?.stringValue ?? "") == "窗口已关闭")
        model.showEndedWindowGrants = false
        #expect(model.windowGrants(of: id).count == 2)
        let wg = try #require(list[0]["windowGrantId"]?.stringValue)
        await model.revokeWindowGrant(wg)
        #expect(model.lastResult?.accepted == true)
        #expect(model.windowGrants.first { $0["windowGrantId"]?.stringValue == wg }?["state"]?.stringValue == "revoked")
        // The others stay as they were.
        #expect(model.windowGrants.first { $0["windowGrantId"]?.stringValue == list[1]["windowGrantId"]?.stringValue }?["state"]?.stringValue == "active")
        // A second revoke is refused by the Runtime, and the page shows that.
        await model.revokeWindowGrant(wg)
        #expect(model.lastResult?.problem?.code == "conflict")
        #expect(m.contractViolations.isEmpty, "\(m.contractViolations)")
    }

    @Test func pairingIsOnlyShownAndCheckedNeverDecided() async throws {
        let m = MockRuntime.agentsSample()
        let pid = m.addPairing(agentName: "Draft Agent", capabilities: ["observe", "act"], desktops: ["desk_001"])
        let (_, model) = await loaded(m)
        await model.checkPairing(pid)
        #expect(model.pairingChecks[pid]?["state"]?.stringValue == "requested")
        #expect(AgentsText.pairingState("requested").text == "等待你在确认窗口中处理")
        m.decidePairing(pid, state: "approved", clientId: "app:mock-009")
        await model.checkPairing(pid)
        #expect(model.pairingChecks[pid]?["state"]?.stringValue == "approved")
        #expect(model.pairingChecks[pid]?["credential"] == nil)
        // Even if a credential came back, the page would not keep it.
        let leaked = JSONValue.obj([("pairingId", .string(pid)), ("state", .string("approved")),
                                    ("credential", .obj([("clientId", .string("app:x")), ("token", .string("adt1_secret"))]))])
        #expect(AgentsModel.withoutSecrets(leaked)["credential"] == nil)
        #expect(!m.callLog.contains("hub.pairing.approve") && !m.callLog.contains("hub.pairing.deny") && !m.callLog.contains("hub.pairing.start"))
        await model.checkPairing("pair_999")
        #expect(model.pairingCheckProblems["pair_999"]?.code == "not_found")
        #expect(m.contractViolations.isEmpty, "\(m.contractViolations)")
    }

    @Test func offlineKeepsTheCacheAndAllowsNoChange() async throws {
        // HB-UI-02 and HB-UI-03: last data stays with its time, nothing can
        // be changed, and nothing sample-like replaces it.
        let m = MockRuntime.agentsSample()
        let (store, model) = await loaded(m)
        let synced = try #require(model.syncedAt)
        m.offline = true
        await store.refreshStatus()
        #expect(!model.connected)
        for method in ["hub.clients.revoke", "hub.grants.set", "hub.grants.revoke", "hub.windows.revoke"] {
            #expect(!model.canChange(method))
        }
        let before = m.callLog.count
        await model.revokeClient("app:mock-001")
        #expect(m.callLog.count == before, "no call goes out while disconnected")
        await model.load()
        #expect(model.clients.count == 2 && model.syncedAt == synced)
        if case .disconnected = model.state {} else { Issue.record("not disconnected: \(model.state)") }
    }

    @Test func aFailedListKeepsTheLastAnswerAndNoSample() async throws {
        let m = MockRuntime.agentsSample()
        let (_, model) = await loaded(m)
        m.failNext("hub.clients.list", code: "internal_error")
        await model.load()
        guard case let .failed(p) = model.state else { Issue.record("not failed: \(model.state)"); return }
        #expect(p.code == "internal_error")
        #expect(model.clients.compactMap { $0["clientId"]?.stringValue } == ["app:mock-001", "app:mock-002"])
    }

    @Test func actionsFollowRuntimeCapabilities() async throws {
        let m = MockRuntime.agentsSample()
        let port = NarrowCapabilitiesRuntime(m, hiding: ["hub.clients.revoke", "hub.windows.list", "hub.pairing.status"])
        let (_, model) = await loaded(port)
        #expect(!model.canChange("hub.clients.revoke"))
        #expect(model.canChange("hub.grants.revoke"))
        #expect(model.partProblems["hub.windows.list"]?.code == "capability_missing")
        #expect(model.windowGrants.isEmpty, "a list the Runtime does not offer is not read")
        await model.revokeClient("app:mock-001")
        #expect(!m.callLog.contains("hub.clients.revoke"))
        await model.checkPairing("pair_001")
        #expect(model.pairingCheckProblems["pair_001"]?.code == "capability_missing")
        // Without hub.clients.list the page says so instead of showing anything.
        let (_, none) = await loaded(NarrowCapabilitiesRuntime(MockRuntime.agentsSample(), hiding: ["hub.clients.list"]))
        guard case let .failed(p) = none.state else { Issue.record("not failed: \(none.state)"); return }
        #expect(p.code == "capability_missing")
    }

    @Test func connectExamplesBindTheDesktopAndAreValid() {
        // UC22: the CLI example names the chosen desktopId.
        let cli = AgentsConnectExamples.cli(desktopId: "desk_002")
        #expect(cli.contains("--desktops desk_002") && cli.contains("--desktop desk_002") && cli.contains("desktop show desk_002"))
        #expect(!cli.contains("<desktopId>"))
        // UC23: the MCP configuration is one valid JSON value; so is the ACP one.
        #expect(CodeBox.isValidJSON(AgentsConnectExamples.mcpConfig()))
        #expect(CodeBox.isValidJSON(AgentsConnectExamples.acpConfig()))
        #expect(AgentsConnectExamples.mcpPair(desktopId: "desk_002").contains("--profile mcp") && AgentsConnectExamples.mcpPair(desktopId: "desk_002").contains("--desktops desk_002"))
        #expect(AgentsConnectExamples.acpPair(desktopId: "desk_002").contains("--desktops desk_002"))
        // An id outside the contract's pattern never reaches a shell line.
        #expect(AgentsConnectExamples.safe("d; rm -rf ~") == "<desktopId>")
        #expect(AgentsConnectExamples.safe(nil) == "<desktopId>")
        // No credential in any example.
        for s in [cli, AgentsConnectExamples.mcpConfig(), AgentsConnectExamples.acpConfig()] {
            #expect(!s.contains("adt1_") && !s.lowercased().contains("token"))
        }
    }

    @Test func theConnectionCheckReadsOnly() async throws {
        // UC24: the check has a visible result. UC25: it calls nothing that
        // changes state, so it cannot take over a controller.
        let m = MockRuntime.agentsSample()
        let (store, model) = await loaded(m)
        let desk = try #require(store.desktops.first?["desktopId"]?.stringValue)
        m.addClient(name: "Probe", capabilities: ["observe"], apps: [])
        let before = m.callLog.count
        await model.checkConnection(desktopId: desk)
        let check = try #require(model.check)
        #expect(check.problem == nil && check.desktop?["desktopId"]?.stringValue == desk)
        let called = Array(m.callLog.dropFirst(before))
        #expect(!called.isEmpty)
        for method in called {
            #expect(RuntimeCatalog.spec(method)?.mutation == false, "\(method) changes state")
        }
        #expect(!called.contains("run.start") && !called.contains { $0.hasPrefix("desktop.takeover") })
        // Grants that name "created" only are not counted as naming this Desktop.
        #expect(check.clients.allSatisfy { $0.clientId != "app:mock-003" })
    }

    @Test func aRefusedChangeIsShownAsNotAccepted() async throws {
        let m = MockRuntime.agentsSample()
        let (_, model) = await loaded(m)
        m.failNext("hub.grants.revoke", code: "audit_unavailable")
        await model.revokeGrant("app:mock-002")
        let r = try #require(model.lastResult)
        #expect(!r.accepted && r.problem?.code == "audit_unavailable" && !r.title.contains("已受理"))
        #expect(model.grant(of: "app:mock-002")?["state"]?.stringValue == "active")
    }
}
