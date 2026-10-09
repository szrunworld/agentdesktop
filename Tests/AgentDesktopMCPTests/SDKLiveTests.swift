import Foundation
import Testing
@testable import AgentDesktopRuntime
import AgentDesktopProtocol

// The Python and TypeScript SDKs against a real RuntimeServer: the same
// Runtime, the same ledger and snapshot rules as the CLI and MCP.

func onPlainThread(_ body: @escaping @Sendable () throws -> Void) async throws {
    try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
        Thread { do { try body(); k.resume() } catch { k.resume(throwing: error) } }.start()
    }
}

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

func runLive(_ tool: String, _ args: [String], in dir: String, endpoint: String, extra: [String: String] = [:],
             limit: TimeInterval = liveRunLimit) throws -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.currentDirectoryURL = repoRoot.appendingPathComponent(dir)
    var env = ProcessInfo.processInfo.environment
    env["AGENTDESKTOP_SDK_LIVE_ENDPOINT"] = endpoint
    env.removeValue(forKey: "AGENTDESKTOP_CONTEXT")
    for (k, v) in extra { env[k] = v }
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

@Test(.enabled(if: which("python3") != nil)) func pythonSDKLive() async throws {
    // Waits on a subprocess for seconds: off the cooperative pool.
    try await onPlainThread {
        let h = try MCPHarness()
        let approver = AutoApprover(h.service)
        defer { approver.stop() }
        let (code, out) = try runLive(which("python3")!, ["-m", "unittest", "tests.test_client.LiveTests", "-v"],
                                      in: "sdks/python", endpoint: h.dir + "/runtime.sock")
        #expect(code == 0, "\(out)")
        #expect(out.contains("LIVE-OK"), "\(out)")
        #expect(h.platform.performed.count == 1, "the retried click with the same requestId was not sent again")
    }
}

@Test(.enabled(if: which("node") != nil)) func typescriptSDKLive() async throws {
    // Waits on a subprocess for seconds: off the cooperative pool.
    try await onPlainThread {
        let h = try MCPHarness()
        let approver = AutoApprover(h.service)
        defer { approver.stop() }
        let (code, out) = try runLive(which("node")!, ["--test", "--test-timeout=90000", "test/client.test.ts"],
                                      in: "sdks/typescript", endpoint: h.dir + "/runtime.sock")
        #expect(code == 0, "\(out)")
        #expect(out.contains("LIVE-OK"), "\(out)")
        #expect(h.platform.performed.count == 1)
    }
}

/// Approves every pairing: the user's window, scripted (A4-SEC-03 tests).
final class ApproveAll: TrustedConfirmer, @unchecked Sendable {
    func confirm(_ request: ConfirmationRequest) -> ConfirmationDecision { .approved(digest: request.digest) }
}

/// A node on PATH signed by its publisher (Team ID) with the hardened
/// runtime, like the official builds; Homebrew's is ad-hoc signed.
let signedNode: String? = {
    let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        + ["/usr/local/bin", "/opt/homebrew/bin"]
    for d in dirs {
        let p = d + "/node"
        guard FileManager.default.isExecutableFile(atPath: p) else { continue }
        let cs = Process()
        cs.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        cs.arguments = ["-dv", p]
        let pipe = Pipe()
        cs.standardError = pipe
        cs.standardOutput = pipe
        guard (try? cs.run()) != nil else { continue }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        cs.waitUntilExit()
        if !text.contains("TeamIdentifier=not set"), text.contains("TeamIdentifier="), text.contains("(runtime)") { return p }
    }
    return nil
}()

/// A4-SEC-03 #4 with the real kernel and Security framework: Node (signed by
/// its publisher, hardened runtime) pairs; the very same credential, shown by
/// a Python process, is refused; Node can still use it.
@Test(.enabled(if: signedNode != nil && which("python3") != nil))
func aCredentialPairedFromNodeIsRefusedFromPython() async throws {
    // Waits on a subprocess for seconds: off the cooperative pool.
    try await onPlainThread {
        let h = try MCPHarness()
        h.service.confirmer = ApproveAll()
        let endpoint = h.dir + "/runtime.sock"
        let pair = """
        import { RuntimeClient } from "./src/index.ts";
        const c = await new RuntimeClient(process.env.EP, 10000, {}).pair("node-agent", ["observe"], { timeoutMs: 20000, pollMs: 100 });
        console.log(JSON.stringify(c));
        """
        let (pc, pout) = try runLive(signedNode!, ["--input-type=module", "-e", pair], in: "sdks/typescript", endpoint: endpoint,
                                     extra: ["EP": endpoint])
        #expect(pc == 0, "\(pout)")
        let line = try #require(pout.split(separator: "\n").last.map(String.init))
        let cred = try StrictJSON.parse(Data(line.utf8))
        let clientId = try #require(cred["clientId"]?.stringValue)
        let level = h.service.hub.client(clientId)?.codeIdentity["level"]?.stringValue
        try #require(level == "shared_interpreter" || level == "verified",
                     "this node is not team-signed with hardened runtime: \(h.service.hub.client(clientId)?.codeIdentity.encoded() ?? "?") \(pout)")
        let py = """
        import json, os, sys
        sys.path.insert(0, ".")
        from agentdesktop_client import RuntimeClient, RuntimeError_
        try:
            with RuntimeClient(os.environ["EP"], env={}, credential=json.loads(os.environ["CRED"])) as c:
                print("ACCEPTED", c.identity["principal"]["clientId"])
        except RuntimeError_ as e:
            print("REFUSED", e.code, e.details.get("reason"))
        """
        let (_, out) = try runLive(which("python3")!, ["-c", py], in: "sdks/python", endpoint: endpoint,
                                   extra: ["EP": endpoint, "CRED": line])
        #expect(out.contains("REFUSED permission_denied code_identity_mismatch"), "\(out)")
        let again = """
        import { RuntimeClient } from "./src/index.ts";
        const c = new RuntimeClient(process.env.EP, 10000, {}, JSON.parse(process.env.CRED));
        console.log("ACCEPTED", (await c.handshake()).principal.codeIdentityLevel);
        c.close();
        """
        let (_, nout) = try runLive(signedNode!, ["--input-type=module", "-e", again], in: "sdks/typescript", endpoint: endpoint,
                                    extra: ["EP": endpoint, "CRED": line])
        #expect(nout.contains("ACCEPTED shared_interpreter") || nout.contains("ACCEPTED verified"), "\(nout)")
    }
}
