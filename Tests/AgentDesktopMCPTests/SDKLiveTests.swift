import Foundation
import Testing
@testable import AgentDesktopRuntime
import AgentDesktopProtocol

// The Python and TypeScript SDKs against a real RuntimeServer: the same
// Runtime, the same ledger and snapshot rules as the CLI and MCP.

let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

func which(_ tool: String) -> String? {
    for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init) {
        let p = dir + "/" + tool
        if FileManager.default.isExecutableFile(atPath: p) { return p }
    }
    return nil
}

func runLive(_ tool: String, _ args: [String], in dir: String, endpoint: String) throws -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.currentDirectoryURL = repoRoot.appendingPathComponent(dir)
    var env = ProcessInfo.processInfo.environment
    env["AGENTDESKTOP_SDK_LIVE_ENDPOINT"] = endpoint
    env.removeValue(forKey: "AGENTDESKTOP_CONTEXT")
    p.environment = env
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// Plays the owner: approves every pairing the SDK under test asks for, with
/// exactly what it asked for, through runtime/1 on an in-process owner
/// connection (the same path as `agentdesktop agents approve`).
final class AutoApprover: @unchecked Sendable {
    private let stopped = NSLock()
    private var done = false
    private(set) var approved = 0

    init(_ service: RuntimeService) {
        let owner = ConnectionState(peerUID: getuid())
        let hs = JSONValue.obj([("apiVersion", .string(RuntimeAPI.version)), ("requestId", .string("hs_approver")),
                                ("method", .string("runtime.handshake")),
                                ("params", .obj([("apiVersions", .array([.string(RuntimeAPI.version)])),
                                                 ("client", .obj([("name", .string("approver")), ("version", .string("1"))]))]))])
        _ = service.respond(to: Data(hs.encoded().utf8), on: owner)
        Thread {
            while !self.isDone {
                for p in service.hub.pairings() where p.state == "requested" {
                    let req = JSONValue.obj([("apiVersion", .string(RuntimeAPI.version)), ("requestId", .string("approve_\(p.pairingId)")),
                                             ("method", .string("hub.pairing.approve")),
                                             ("params", .obj([("pairingId", .string(p.pairingId)), ("grant", p.requested)]))])
                    switch service.respond(to: Data(req.encoded().utf8), on: owner).result {
                    case .success: self.stopped.withLock { self.approved += 1 }
                    case let .failure(e): print("approver: \(e.code) \(e.message)")
                    }
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }.start()
    }

    private var isDone: Bool { stopped.withLock { done } }
    func stop() { stopped.withLock { done = true } }
}

@Test(.enabled(if: which("python3") != nil)) func pythonSDKLive() throws {
    let h = try MCPHarness()
    let approver = AutoApprover(h.service)
    defer { approver.stop() }
    let (code, out) = try runLive(which("python3")!, ["-m", "unittest", "tests.test_client.LiveTests", "-v"],
                                  in: "sdks/python", endpoint: h.dir + "/runtime.sock")
    #expect(code == 0, "\(out)")
    #expect(out.contains("LIVE-OK"), "\(out)")
    #expect(h.platform.performed.count == 1, "the retried click with the same requestId was not sent again")
}

@Test(.enabled(if: which("node") != nil)) func typescriptSDKLive() throws {
    let h = try MCPHarness()
    let approver = AutoApprover(h.service)
    defer { approver.stop() }
    let (code, out) = try runLive(which("node")!, ["--test", "test/client.test.ts"],
                                  in: "sdks/typescript", endpoint: h.dir + "/runtime.sock")
    #expect(code == 0, "\(out)")
    #expect(out.contains("LIVE-OK"), "\(out)")
    #expect(h.platform.performed.count == 1)
}
