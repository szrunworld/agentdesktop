import Foundation
import Testing
@testable import AgentDesktopRuntime

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

/// How long one SDK's live run may take (#187): a Runtime change that makes
/// the run wait forever fails the test instead of holding CI.
let liveRunLimit: TimeInterval = 120

func runLive(_ tool: String, _ args: [String], in dir: String, endpoint: String,
             limit: TimeInterval = liveRunLimit) throws -> (Int32, String) {
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
    final class Collected: @unchecked Sendable { let lock = NSLock(); var data = Data(); var eof = false }
    let collected = Collected()
    out.fileHandleForReading.readabilityHandler = { h in
        let chunk = h.availableData
        collected.lock.withLock { if chunk.isEmpty { collected.eof = true } else { collected.data.append(chunk) } }
        if chunk.isEmpty { h.readabilityHandler = nil }
    }
    try p.run()
    let deadline = Date().addingTimeInterval(limit)
    while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
    var timedOut = false
    if p.isRunning {
        // Its own children first (node --test runs the file in a child that
        // holds the pipe), then itself; only this run's processes.
        timedOut = true
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-TERM", "-P", String(p.processIdentifier)]
        try? pkill.run()
        pkill.waitUntilExit()
        p.terminate()
        p.waitUntilExit()
    }
    // Never a blocking read to the end (b9 on 1eb1d6a): a grandchild that
    // outlives the run can hold the pipe open. Wait a little for the end of
    // the output, then take what has arrived.
    let drainUntil = Date().addingTimeInterval(5)
    while !collected.lock.withLock({ collected.eof }) && Date() < drainUntil { Thread.sleep(forTimeInterval: 0.05) }
    out.fileHandleForReading.readabilityHandler = nil
    let text = String(decoding: collected.lock.withLock { collected.data }, as: UTF8.self)
    if timedOut { return (-1, "timed out after \(Int(limit)) s (#187); output so far:\n" + text) }
    return (p.terminationStatus, text)
}

@Test(.enabled(if: which("python3") != nil)) func pythonSDKLive() throws {
    let h = try MCPHarness()
    let (code, out) = try runLive(which("python3")!, ["-m", "unittest", "tests.test_client.LiveTests", "-v"],
                                  in: "sdks/python", endpoint: h.dir + "/runtime.sock")
    #expect(code == 0, "\(out)")
    #expect(out.contains("LIVE-OK"), "\(out)")
    #expect(h.platform.performed.count == 1, "the retried click with the same requestId was not sent again")
}

@Test(.enabled(if: which("node") != nil)) func typescriptSDKLive() throws {
    let h = try MCPHarness()
    let (code, out) = try runLive(which("node")!, ["--test", "--test-timeout=90000", "test/client.test.ts"],
                                  in: "sdks/typescript", endpoint: h.dir + "/runtime.sock")
    #expect(code == 0, "\(out)")
    #expect(out.contains("LIVE-OK"), "\(out)")
    #expect(h.platform.performed.count == 1)
}
