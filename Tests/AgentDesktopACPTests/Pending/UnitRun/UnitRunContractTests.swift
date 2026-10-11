import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopACP

// Layer: Mock (no Runtime). Parameter and contract checks of ACP's unit.run
// adapter against the shapes frozen by #102. docs/acp/12-unit-run.md §三.1,
// §三.3. Passing here is not A6.

@Suite("UR · Mock · unit.run contract and parameters")
struct UnitRunContractTests {
    let contract = RuntimeContract.shared

    /// The frozen fixtures still mean what ACP relies on.
    @Test("[Mock] frozenFixturesKeepTheirMeaning") func frozenFixturesKeepTheirMeaning() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contracts/fixtures/runtime/v1")
        let names = ["unit-run-explore.valid", "unit-run-escalation-fields-reach-the-handler.valid", "unit-run-claims-client-id.invalid",
                     "unit-run-empty-verification.invalid", "unit-run-profile-without-revision.invalid", "run-unit.valid",
                     "run-unit-made-up-status.invalid"]
        for n in names {
            let f = try StrictJSON.parse(Data(contentsOf: dir.appendingPathComponent("\(n).json")))
            let def = try #require(f["def"]?.stringValue)
            let problems = contract.validate(f["instance"] ?? .null, def)
            #expect(problems.isEmpty == n.hasSuffix(".valid"), "\(n): \(problems)")
        }
        // methods.json: unit.run is a mutation returning Run, implemented
        // since A6 (it left the frozen catalog with the same shape).
        let methods = try StrictJSON.parse(RuntimeContract.embedded.methods)
        let entry = try #require(methods["methods"]?.arrayValue?.first { $0["method"]?.stringValue == "unit.run" })
        #expect(entry["status"]?.stringValue == "implemented")
        #expect(entry["mutation"]?.boolValue == true)
        #expect(entry["params"]?.stringValue == "unit_run_params")
        #expect(entry["result"]?.stringValue == "Run")
    }

    /// Q1 evidence: the Schema lets origin/lifetime/ownership through, so a
    /// refusal of them cannot be schema_invalid as long as #102 stands.
    @Test("[Mock] escalationFieldsAreAHandlerRefusalNotASchemaOne") func escalationFieldsAreAHandlerRefusalNotASchemaOne() throws {
        let base = try URTestScenario.load("ur-normal").input.urAdding("desktopId", .string("desk_A"))
        for (k, v) in [("lifetime", "platform_durable"), ("ownership", "platform"), ("origin", "gui_explorer")] {
            #expect(contract.validate(base.urAdding(k, .string(v)), "unit_run_params").isEmpty, "\(k) is a schema error")
        }
        #expect(!contract.validate(base.urAdding("clientId", .string("app:x")), "unit_run_params").isEmpty)
        #expect(contract.error("ownership_escalation_denied") != nil)
    }

    @Test("[Mock] scenarioInputsAreValidUnitRunParams") func scenarioInputsAreValidUnitRunParams() throws {
        for name in URTestScenario.flowNames + ["ur-precheck-refusals"] {
            let s = try URTestScenario.json(name)
            let params = (s["input"] ?? .null).urAdding("desktopId", s["desktopId"] ?? .null)
            #expect(contract.validate(params, "unit_run_params").isEmpty, "\(name)")
        }
    }

    /// Frozen-prefix events in the fixtures validate as PlatformRunEvent;
    /// unit.* ones are marked not frozen.
    @Test("[Mock] scenarioEventsUseTheFrozenCatalogue") func scenarioEventsUseTheFrozenCatalogue() throws {
        for name in URTestScenario.flowNames {
            let s = try URTestScenario.load(name)
            for (i, e) in (s.onAccept + s.onTrigger).enumerated() {
                let type = e["type"]?.stringValue ?? ""
                let ev = URTestRuntime.substitute(.obj([("runId", .string("run_ab000001")), ("sequence", .int(i + 1)),
                                                        ("at", .string(URTestRuntime.at(i))), ("type", .string(type)),
                                                        ("data", e["data"] ?? .null)]), runId: "run_ab000001")
                if type.hasPrefix("unit.") {
                    #expect(e["frozen"] == .bool(false), "\(name) \(type) should be marked not frozen")
                } else {
                    #expect(contract.validate(ev, "PlatformRunEvent").isEmpty, "\(name) \(type): \(contract.validate(ev, "PlatformRunEvent"))")
                }
            }
        }
    }

    @Test("[Mock] malformedFramesAreReportedAndPartialFramesWait")
    func malformedFramesAreReportedAndPartialFramesWait() {
        let bytes = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\nnot-json\n{\"partial\":".utf8)
        let parsed = URTestPipeEditor.decodeFrames(bytes)
        #expect(parsed.frames.count == 1)
        #expect(parsed.problems.count == 1)
        #expect(parsed.problems.first?.contains("frame 2: invalid JSON") == true)
        let completed = URTestPipeEditor.decodeFrames(bytes + Data("true}\n".utf8))
        #expect(completed.frames.count == 2)
        #expect(completed.problems.count == 1)
    }

    // MARK: Catalog

    @Test("[Mock] noUnitRunNoTask") func noUnitRunNoTask() {
        let c = ACPTaskCatalog()
        #expect(!URTestRuntime.withoutUnitRun.contains("unit.run"))
        #expect(c.entries(methods: URTestRuntime.withoutUnitRun, profiles: nil).isEmpty)
        #expect(c.entries(methods: URTestRuntime.withUnitRun, profiles: nil).map(\.task.taskType) == ["unit.run"])
    }

    @Test("[Mock] profilesBecomeTasksPinnedToTheirRevision") func profilesBecomeTasksPinnedToTheirRevision() throws {
        let c = ACPTaskCatalog()
        let profiles: [JSONValue] = [
            .obj([("guiProfileId", .string("gp_gui_v1")), ("name", .string("GUI v1")), ("state", .string("enabled")), ("revision", .int(3))]),
            .obj([("guiProfileId", .string("gp_off")), ("name", .string("Off")), ("state", .string("disabled")), ("revision", .int(1))]),
        ]
        let entries = c.entries(methods: URTestRuntime.withUnitRun.union(["ai.profiles.list"]), profiles: profiles)
        #expect(entries.map(\.task.taskType) == ["unit.run/gp_gui_v1"])
        let s = try URTestScenario.load("ur-normal")
        let sub = ACPSubmission(submissionKey: "k", acpSessionId: "s", taskType: "unit.run/gp_gui_v1", input: s.input, desktopId: "desk_A")
        let params = try c.params(for: entries[0], submission: sub).get()
        #expect(params["guiProfileId"] == .string("gp_gui_v1"))
        #expect(params["expectedProfileRevision"] == .int(3))
        #expect(contract.validate(params, "unit_run_params").isEmpty)
    }

    @Test("[Mock] bridgeBuildsValidParamsAndRefusesBadOnesLocally") func bridgeBuildsValidParamsAndRefusesBadOnesLocally() throws {
        let c = ACPTaskCatalog()
        let entry = c.entries(methods: URTestRuntime.withUnitRun, profiles: nil)[0]
        let input = try URTestScenario.load("ur-normal").input
        func params(_ i: JSONValue, desktop: String? = "desk_A") -> Result<JSONValue, ACPTaskCatalog.Refusal> {
            c.params(for: entry, submission: ACPSubmission(submissionKey: "k", acpSessionId: "s", taskType: "unit.run", input: i, desktopId: desktop))
        }
        let ok = try params(input).get()
        #expect(ok["desktopId"] == .string("desk_A"))
        #expect(contract.validate(ok, "unit_run_params").isEmpty)

        func code(_ r: Result<JSONValue, ACPTaskCatalog.Refusal>) -> String? {
            if case let .failure(.refused(c, _)) = r { return c }
            return nil
        }
        let emptyVerification = input.setting("verification", .obj([("all", .array([]))]))
        #expect(code(params(emptyVerification)) == "schema_invalid")
        #expect(code(params(input.setting("allowedActions", .array([.string("drag")])))) == "schema_invalid")
        #expect(code(params(input.setting("mode", .string("forever")))) == "schema_invalid")
        #expect(code(params(input.urAdding("guiProfileId", .string("gp_x")))) == "invalid_argument")
        #expect(code(params(input, desktop: nil)) == "invalid_argument")
        #expect(code(params(input.urAdding("desktopId", .string("desk_B")))) == "invalid_argument")
        #expect(code(params(.string("not an object"))) == "invalid_argument")
    }

    /// Escalation fields (ur-escalation.json): refused before anything is
    /// sent, with the contract's code.
    @Test("[Mock] escalationIsRefusedLocallyWithTheContractCode") func escalationIsRefusedLocallyWithTheContractCode() throws {
        let esc = try URTestScenario.json("ur-escalation")
        let c = ACPTaskCatalog()
        let entry = c.entries(methods: URTestRuntime.withUnitRun, profiles: nil)[0]
        for k in esc["cases"]?.arrayValue ?? [] {
            let field = k["field"]?.stringValue ?? ""
            let input = (esc["base"] ?? .null).urAdding(field, k["value"] ?? .null)
            let r = c.params(for: entry, submission: ACPSubmission(submissionKey: "k", acpSessionId: "s", taskType: "unit.run", input: input, desktopId: "desk_A"))
            guard case let .failure(.refused(code, _)) = r else { Issue.record("\(field) not refused"); continue }
            #expect(code == k["localCode"]?.stringValue, "\(field)")
        }
    }

    /// Gap UR-G2: the editor schema still advertises the fields the bridge
    /// will refuse (origin / lifetime / ownership), so the command hint
    /// shows them. Remove the known-issue wrapper when R strips them.
    @Test("[Mock] editorSchemaShouldNotAdvertiseForbiddenFields") func editorSchemaShouldNotAdvertiseForbiddenFields() throws {
        let task = ACPTaskCatalog().entries(methods: URTestRuntime.withUnitRun, profiles: nil)[0].task
        let props = Set((task.inputSchema["properties"]?.objectMembers ?? []).map(\.key))
        #expect(props.contains("desktopId"))
        #expect((task.inputSchema["required"]?.arrayValue ?? []).contains(.string("desktopId")))
        withKnownIssue("UR-G2: editor schema lists origin/lifetime/ownership") {
            #expect(props.isDisjoint(with: ACPTaskCatalog.forbiddenInputKeys))
            #expect(!(ACPCommandInput.hint(for: task.inputSchema) ?? "").contains("lifetime"))
        }
    }

    /// Gap UR-G3: the task claims free text, but a plain sentence cannot
    /// fill unit_run_params (no free-text mapping; f1 R6 declined, 40's F40).
    @Test("[Mock] freeTextCannotStartAUnitRunYet") func freeTextCannotStartAUnitRunYet() {
        let task = ACPTaskCatalog().entries(methods: URTestRuntime.withUnitRun, profiles: nil)[0].task
        #expect(task.allowFreeText)
        withKnownIssue("UR-G3: no free-text → goal.description mapping") {
            guard case .success = ACPCommandInput.input(argument: "打开关于窗口", schema: task.inputSchema) else {
                Issue.record("free text needs JSON")
                return
            }
        }
    }
}
