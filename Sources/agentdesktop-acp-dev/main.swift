// Development entry for the ACP server (docs/acp/03-lanes.md, lane S).
// Not bundled: the shipped command is `agentdesktop acp`, wired into the
// one CLI by the coordinator (plan step P1-01).
//
//   agentdesktop-acp-dev --endpoint PATH     stdio ⇄ server ⇄ runtime/1 at PATH (a side instance)
//   AGENTDESKTOP_ENDPOINT=PATH agentdesktop-acp-dev
//   agentdesktop-acp-dev --demo              stdio ⇄ server ⇄ built-in scripted port (no Runtime)
//
// Every socket inside the product directory (~/Library/Application Support/
// AgentDesktop/: control.sock, runtime.sock, ai.sock, …, symlinks resolved)
// is refused unless --allow-product-endpoint is given. No GUI
// input happens here: the server only talks to ACPRuntimePort.
import AgentDesktopACP
// AgentDesktopClient is a dependency of AgentDesktopACP; the dev target
// imports it for `Endpoint` (interface request: list it in Package.swift).
import AgentDesktopClient
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("agentdesktop-acp-dev: \(message)\n".utf8))
    exit(2)
}

let usage = """
usage: agentdesktop-acp-dev [--demo | --endpoint PATH [--allow-product-endpoint]] [--state-dir DIR]
  --demo                     built-in scripted port; sessions in a temporary directory
  --endpoint PATH            Runtime socket of a side instance (else AGENTDESKTOP_ENDPOINT)
  --allow-product-endpoint   permit the installed product's own endpoint
  --state-dir DIR            where ACP sessions and the submission log live
                             (default: beside a side-instance endpoint, <dir>/acp)
"""

var demo = false
var endpointOption: String?
var allowProduct = false
var stateDir: String?
var rest = Array(CommandLine.arguments.dropFirst())
while !rest.isEmpty {
    let a = rest.removeFirst()
    switch a {
    case "-h", "--help": print(usage); exit(0)
    case "--demo": demo = true
    case "--allow-product-endpoint": allowProduct = true
    case "--endpoint", "--state-dir":
        guard !rest.isEmpty, !rest[0].isEmpty else { fail("\(a) needs a path") }
        if a == "--endpoint" { endpointOption = rest.removeFirst() } else { stateDir = rest.removeFirst() }
    default: fail("unknown argument \(a)\n\(usage)")
    }
}
if demo, endpointOption != nil { fail("--demo and --endpoint exclude each other") }

let home = ProcessInfo.processInfo.environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
let runtime: any ACPRuntimePort
let projector: any ACPEventProjector
let store: ACPFileSessionStore

if demo {
    runtime = ACPAgentServerDemoPort()
    projector = ACPAgentServerDemoProjector()
    // One directory per user, so a reconnecting editor can load its sessions.
    let dir = stateDir ?? (FileManager.default.temporaryDirectory.path + "/agentdesktop-acp-dev-demo-\(getuid())")
    store = ACPFileSessionStore(directory: URL(fileURLWithPath: dir).appendingPathComponent("sessions", isDirectory: true))
} else {
    let endpoint = EndpointResolver.resolve(option: endpointOption, environment: ProcessInfo.processInfo.environment)
    // Any socket inside the product directory is the product (control.sock
    // after A2, runtime.sock, ai.sock, …), after resolving symlinks.
    // Checked against both the HOME the process was given and the account's
    // real home (tilde expansion uses the latter), and against both the
    // path as typed and as resolved.
    let guards = Set([home, NSHomeDirectory()]).map { ACPAgentServerEndpointGuard(home: $0) }
    let typed = [endpointOption, ProcessInfo.processInfo.environment[EndpointResolver.environmentKey]]
        .compactMap { $0 }.filter { !$0.isEmpty }
    let isProduct = guards.contains { g in ([endpoint.path] + typed).contains { g.isProductPath($0) } }
    if isProduct, !allowProduct {
        fail("refusing \(endpoint.path): it is inside the product directory \(guards[0].productDirectory); use a side instance (--endpoint / AGENTDESKTOP_ENDPOINT), or pass --allow-product-endpoint")
    }
    if let problem = EndpointResolver.inspect(endpoint.path) { fail("\(endpoint.path): \(problem.message)") }
    let state: String
    if let stateDir {
        state = stateDir
    } else if isProduct {
        state = home + "/Library/Application Support/AgentDesktop/acp"
    } else {
        state = (endpoint.path as NSString).deletingLastPathComponent + "/acp"
    }
    let log: ACPSubmissionLog
    do { log = try ACPSubmissionLog(path: state + "/submissions.json") } catch {
        fail("cannot open the submission log under \(state): \(error)")
    }
    projector = ACPProjector()
    runtime = ACPBridgeRuntimePort(makeClient: ACPBridgeConfiguration.socketFactory(endpoint: endpoint), log: log)
    store = ACPFileSessionStore(directory: URL(fileURLWithPath: state).appendingPathComponent("sessions", isDirectory: true))
}

let connection = ACPStdioConnection.standardIO()
let server = ACPAgentServer(connection: connection, runtime: runtime, projector: projector, store: store)
await server.run()
exit(0)
