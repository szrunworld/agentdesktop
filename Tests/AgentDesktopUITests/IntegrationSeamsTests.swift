import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopUI

// The shared seams joined after the UI lanes landed (docs/plan/11
// §集成): navigation into GUI Explorer, the default-size preference on
// the creation form, and requestIds on the pages' creates.

private func freshDefaults() -> UserDefaults {
    let name = "agentdesktop-integration-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

@MainActor
@Suite("UI integration seams")
struct IntegrationSeamsTests {
    @Test func navigationReachesExplorerFromRunsAndDesktops() {
        let nav = ShellNavigation()
        nav.showExplorerRun("run_7")
        #expect(nav.section == .explorer && nav.explorerRunId == "run_7" && nav.explorerDesktopId == nil)
        nav.startExplorer(desktopId: "desk_2")
        #expect(nav.section == .explorer && nav.explorerDesktopId == "desk_2" && nav.explorerRunId == nil)
        nav.back()
        #expect(nav.explorerDesktopId == nil)
        nav.showExplorerRun("run_8")
        nav.open(.explorer)
        #expect(nav.explorerRunId == nil, "choosing the entry shows the history")
    }

    // P21's default size reaches desktop.create even with the size field
    // folded away; the standard size leaves the Runtime's default alone.
    @Test func defaultDesktopSizePreferenceReachesTheCreationForm() async throws {
        let defaults = freshDefaults()
        let prefs = SettingsPreferences(defaults: defaults)
        prefs.draft.defaultDesktopSize = SettingsDesktopSize.choices[2]
        prefs.save()
        let m = MockRuntime()
        let flow = CreateDesktopFlow(runtime: m, defaults: defaults)
        #expect(flow.width == 1920 && flow.height == 1080 && flow.sizeFromPreference)
        flow.name = "按偏好"
        await flow.submit()
        let id = try #require(flow.desktopId)
        let d = try await m.call("desktop.show", .obj([("desktopId", .string(id))]))
        let frame = d["screen"]?["frame"]
        #expect(frame?["width"]?.intValue == 1920 && frame?["height"]?.intValue == 1080)

        let plain = CreateDesktopFlow(runtime: m, defaults: freshDefaults())
        #expect(plain.width == 1280 && !plain.sizeFromPreference)
    }

    // A create whose answer was lost is sent again under the same
    // requestId (the Runtime's idempotency key), never as a second create.
    @Test func createRetriesReuseTheirRequestId() async throws {
        let m = MockRuntime()
        m.failNext("ai.connections.create", code: "deadline_exceeded")
        let editor = SettingsConnectionEditorModel(runtime: m, mode: .create)
        editor.name = "本机模型"
        editor.baseUrl = "http://127.0.0.1:8000/v1"
        editor.secretInput = "sk-synthetic-integration"
        #expect(await editor.save() == false)
        editor.secretInput = "sk-synthetic-integration"
        #expect(await editor.save())
        let ids = m.requestIds.filter { $0.method == "ai.connections.create" }.map(\.id)
        #expect(ids.count == 2 && ids[0] == ids[1], "\(ids)")
        // Settled: the next create (a new draft) gets a new id.
        let count = try await m.call("ai.connections.list", .obj([]))["items"]!.arrayValue!.count
        #expect(count == 1)
    }

    // A port that knows no requestId still serves the call.
    @Test func portsWithoutALedgerIgnoreTheRequestId() async throws {
        final class Plain: RuntimePort, @unchecked Sendable {
            let isSample = true
            var seen: [String] = []
            func call(_ method: String, _ params: JSONValue, context: RequestContext) async throws -> JSONValue {
                seen.append(method); return .obj([])
            }
            func subscribe(after: Int?) async throws -> AsyncThrowingStream<JSONValue, Error> { throw RuntimeError.capabilityMissing("no") }
        }
        let p = Plain()
        _ = try await p.call("runtime.status", .obj([]), requestId: "ui_fixed")
        #expect(p.seen == ["runtime.status"])
    }
}
