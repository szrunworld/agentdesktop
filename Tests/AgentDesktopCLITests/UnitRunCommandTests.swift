import AgentDesktopClient
import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopCLI

// A6: `agentdesktop unit run` replaces `gui run/status/cancel/events`. The
// Run is Delegated, so the command stays on its control connection until
// the Run ends; reading and stopping a Run are the run commands.

private func unitRun(_ phase: String = "running", outcome: String? = nil) -> JSONValue {
    .obj([("runId", .string("run_u1")), ("kind", .string("unit")), ("desktopId", .string("d1")), ("phase", .string(phase)),
          ("outcome", outcome.map(JSONValue.string) ?? .null), ("quiescence", .string(phase == "ended" ? "confirmed" : "not_confirmed")),
          ("closingReason", .null), ("revision", .int(1))])
}

private let base = ["unit", "run", "--desktop", "d1", "--goal", "打开报告", "--expect-text", "完成", "--allowed-actions", "click,type"]

@Test func unitRunOptionsAreCheckedBeforeAnyConnection() {
    let cases: [[String]] = [
        ["unit", "run", "--desktop", "d1", "--expect-text", "x", "--allowed-actions", "click"],                         // no goal
        ["unit", "run", "--desktop", "d1", "--goal", "g", "--goal-file", "f", "--expect-text", "x", "--allowed-actions", "click"],
        ["unit", "run", "--desktop", "d1", "--goal", "g", "--allowed-actions", "click"],                                 // no predicate
        ["unit", "run", "--desktop", "d1", "--goal", "g", "--expect-text", "x", "--allowed-actions", "drag"],            // unknown action
        ["unit", "run", "--desktop", "d1", "--goal", "g", "--expect-text", "x", "--allowed-actions", "click", "--profile-id", "gp"],
        ["unit", "run", "--goal", "g", "--expect-text", "x", "--allowed-actions", "click"],                              // no desktop
    ]
    for args in cases {
        let h = Harness()
        #expect(h.cli.run(args) == 2, "\(args)")
        #expect(h.clients.isEmpty, "\(args) connected")
    }
}

@Test func unitRunStaysUntilTheRunEndsAndExitsByOutcome() throws {
    for (outcome, exit) in [("success", Int32(0)), ("failed", 7), ("unknown", 9)] {
        let h = Harness()
        var waits = 0
        h.answer = { r in
            switch r.method {
            case "unit.run": return unitRun()
            case "run.wait":
                waits += 1
                if waits < 3 { throw RuntimeError("wait_timeout", "still running", phase: .handler) }
                return unitRun("ended", outcome: outcome)
            default: throw RuntimeError("not_found", "unexpected \(r.method)", phase: .handler)
            }
        }
        #expect(h.run("unit", "run", "--desktop", "d1", "--goal", "打开报告", "--expect-text", "完成",
                      "--allowed-actions", "click,type", "--max-steps", "5", "--request-id", "unit-req-1", "--format", "json") == exit,
                "\(outcome): \(h.err)")
        // One connection, kept until the Run ended (a Delegated Run ends with it).
        #expect(h.clients.count == 1)
        #expect(h.requests == ["unit.run", "run.wait", "run.wait", "run.wait"])
        let start = try #require(h.clients.first?.calls.first)
        #expect(start.requestId == "unit-req-1")
        #expect(start.params["goal"]?["description"]?.stringValue == "打开报告")
        #expect(start.params["verification"]?["all"]?.arrayValue?.first?["text"]?.stringValue == "完成")
        #expect(start.params["limits"]?["maxSteps"]?.intValue == 5)
        #expect(start.params["origin"] == nil && start.params["lifetime"] == nil && start.params["ownership"] == nil)
        #expect(RuntimeContract.shared.validate(start.params, "unit_run_params").isEmpty)
        #expect(try h.json()["data"]?["outcome"]?.stringValue == outcome)
    }
}

@Test func ctrlCStopsTheUnitRunAndWaitsForItsEnd() {
    let h = Harness()
    var cancelled = false
    h.answer = { r in
        switch r.method {
        case "unit.run": return unitRun()
        case "run.cancel": cancelled = true; return .obj([])
        case "run.wait":
            if !cancelled { throw RuntimeError("wait_timeout", "still running", phase: .handler) }
            return unitRun("ended", outcome: "cancelled")
        default: throw RuntimeError("not_found", "unexpected", phase: .handler)
        }
    }
    var cli = h.cli
    var polls = 0
    cli.interrupted = { polls += 1; return polls > 1 }
    #expect(cli.run(base) == 130)
    #expect(h.requests.filter { $0 == "run.cancel" }.count == 1, "the stop is sent once")
    #expect(h.requests.last == "run.wait")
}

@Test func aRefusedUnitRunSaysWhy() {
    let h = Harness()
    h.answer = { _ in
        throw RuntimeError("unsupported_backend", "real GUI input is off here", phase: .handler, notSent: true,
                           details: .obj([("reason", .string("gui_execution_off"))]))
    }
    #expect(h.cli.run(base) != 0)
    #expect(h.err.joined().contains("unsupported_backend"))
    #expect(h.requests == ["unit.run"])
}

@Test func theGuiGroupIsGone() {
    let h = Harness()
    #expect(h.cli.run(["gui", "run", "--desktop", "d1"]) == 2)
    #expect(h.clients.isEmpty)
}

// Codex on ed056dc: a stop that is not accepted is never waited on; the
// command says so and leaves, which ends the Delegated Run (owner_lost).
@Test func aFailedStopIsReportedNotWaitedOn() {
    let h = Harness()
    var waits = 0
    h.answer = { r in
        switch r.method {
        case "unit.run": return unitRun()
        case "run.cancel": throw RuntimeError("audit_unavailable", "the request ledger is unavailable", phase: .handler)
        case "run.wait": waits += 1; throw RuntimeError("wait_timeout", "still running", phase: .handler)
        default: throw RuntimeError("not_found", "unexpected", phase: .handler)
        }
    }
    var cli = h.cli
    cli.interrupted = { true }
    let code = cli.run(base)
    #expect(code == 130)
    #expect(h.requests.filter { $0 == "run.cancel" }.count == 1)
    #expect(waits == 0, "no waiting on a stop that was refused")
    #expect(h.err.joined().contains("could not stop"))
}
