import Foundation
import Testing
@testable import AgentDesktopRuntime
import AgentDesktopProtocol

// A7: examples/neutral-agent against a real RuntimeServer on a temporary
// socket (no product socket, no real windows). Read-only: handshake, pair
// (approved by the scripted owner), list Desktops, disconnect, reconnect.

@Test(.enabled(if: which("python3") != nil)) func neutralAgentPairsListsAndReconnects() async throws {
    try await onPlainThread {
        let h = try MCPHarness()
        // One Desktop to show; the example's grant names it.
        let desktop = try #require(h.tool("desktop_create", [("name", .string("neutral"))]).0?["desktopId"]?.stringValue)
        let approver = AutoApprover(h.service)
        defer { approver.stop() }
        let cred = h.dir + "/neutral.credential.json"
        let endpoint = h.dir + "/runtime.sock"
        let args = ["neutral_agent.py", "--endpoint", endpoint, "--credential-file", cred, "--list-only",
                    "--capabilities", "observe", "--desktops", desktop, "--poll", "0.05", "--pair-timeout", "30"]
        let (code, out) = try runLive(which("python3")!, args, in: "examples/neutral-agent", endpoint: endpoint)
        #expect(code == 0, "\(out)")
        for step in ["[handshake]", "[pair.start]", "[pair.approved]", "[connect]", "[desktops]", "[disconnect]", "[reconnect]"] {
            #expect(out.contains(step), "\(step) missing:\n\(out)")
        }
        #expect(out.contains(desktop), "\(out)")
        #expect(out.contains("\"sameClient\": true"), "\(out)")
        #expect(approver.approved == 1)
        let mode = try FileManager.default.attributesOfItem(atPath: cred)[.posixPermissions] as? Int
        #expect(mode == 0o600)

        // Again with the saved credential: no new pairing.
        let (again, out2) = try runLive(which("python3")!, args + ["--no-pair"], in: "examples/neutral-agent", endpoint: endpoint)
        #expect(again == 0, "\(out2)")
        #expect(out2.contains("[credential]") && !out2.contains("[pair.start]"), "\(out2)")
        #expect(approver.approved == 1)

        // Unpaired with --no-pair and no file: pairing_required, exit 3, nothing else asked.
        let (refused, out3) = try runLive(which("python3")!, ["neutral_agent.py", "--endpoint", endpoint, "--credential-file",
                                                              h.dir + "/none.json", "--no-pair"],
                                          in: "examples/neutral-agent", endpoint: endpoint)
        #expect(refused == 3, "\(out3)")
        #expect(out3.contains("pairing_required"), "\(out3)")
        #expect(h.platform.lock.withLock { h.platform.performed.isEmpty })
    }
}
