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
    let (code, out) = try runLive(which("node")!, ["--test", "test/client.test.ts"],
                                  in: "sdks/typescript", endpoint: h.dir + "/runtime.sock")
    #expect(code == 0, "\(out)")
    #expect(out.contains("LIVE-OK"), "\(out)")
    #expect(h.platform.performed.count == 1)
}
