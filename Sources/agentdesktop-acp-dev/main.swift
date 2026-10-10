// Development entry for the ACP server (docs/acp/03-lanes.md, lane S).
// Not bundled: the shipped command is `agentdesktop acp`, wired into the
// one CLI by the coordinator (plan step P1-01).
//
//   agentdesktop-acp-dev --endpoint PATH     stdio ⇄ server ⇄ runtime/1 at PATH (a side instance)
//   AGENTDESKTOP_ENDPOINT=PATH agentdesktop-acp-dev
//   agentdesktop-acp-dev --demo              stdio ⇄ server ⇄ built-in scripted port (no Runtime)
//   agentdesktop-acp-dev pair --endpoint PATH   pair this program with the Runtime (A4), once
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
       agentdesktop-acp-dev pair [--endpoint PATH [--allow-product-endpoint]] [--name NAME] [--apps ID,…] [--duration 8h] [--wait-timeout SECONDS]
  --demo                     built-in scripted port; sessions in a temporary directory
  --endpoint PATH            Runtime socket of a side instance (else AGENTDESKTOP_ENDPOINT)
  --allow-product-endpoint   permit the installed product's own endpoint
  --state-dir DIR            where ACP sessions and the submission log live
                             (default: beside a side-instance endpoint, <dir>/acp)
  pair                       ask to pair as this program; confirm in the Agent Desktop window.
                             The credential goes to the keychain (profile "acp"; AGENTDESKTOP_KEYCHAIN
                             for a test copy's keychain file), where serving reads it
  --name NAME                name shown in the confirmation window (default ACP)
  --apps ID,…                bundle ids a task may launch (default none)
  --duration 1h|8h|7d        how long the grant lasts, up to 7d (default: the Runtime's, 1h)
  --wait-timeout SECONDS     how long to wait for the answer (default 180)
"""

var pairing = false
var demo = false
var endpointOption: String?
var allowProduct = false
var stateDir: String?
var pairName = "ACP"
var pairApps: [String] = []
var pairDuration: Int?
var pairTimeout = 180.0
var rest = Array(CommandLine.arguments.dropFirst())
if rest.first == "pair" { pairing = true; rest.removeFirst() }
// Options that belong to one mode only; the other mode refuses them.
let serveOnly: Set<String> = ["--demo", "--state-dir"]
let pairOnly: Set<String> = ["--name", "--apps", "--duration", "--wait-timeout"]
while !rest.isEmpty {
    let a = rest.removeFirst()
    if (pairing && serveOnly.contains(a)) || (!pairing && pairOnly.contains(a)) {
        fail("\(a) does not apply \(pairing ? "to pair" : "when serving")\n\(usage)")
    }
    switch a {
    case "-h", "--help": print(usage); exit(0)
    case "--demo": demo = true
    case "--allow-product-endpoint": allowProduct = true
    case "--endpoint", "--state-dir":
        guard !rest.isEmpty, !rest[0].isEmpty else { fail("\(a) needs a path") }
        if a == "--endpoint" { endpointOption = rest.removeFirst() } else { stateDir = rest.removeFirst() }
    case "--name", "--apps", "--duration", "--wait-timeout":
        guard !rest.isEmpty, !rest[0].isEmpty else { fail("\(a) needs a value") }
        let v = rest.removeFirst()
        switch a {
        case "--name": pairName = v
        case "--apps": pairApps = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        case "--duration":
            guard let s = ACPPairing.durationSeconds(v) else { fail("--duration needs 1h, 8h, 7d or the like (1s to 7d), got \(v)") }
            pairDuration = s
        default:
            guard let t = Double(v), t > 0 else { fail("--wait-timeout needs a positive number of seconds") }
            pairTimeout = t
        }
    default: fail("unknown argument \(a)\n\(usage)")
    }
}
if demo, endpointOption != nil { fail("--demo and --endpoint exclude each other") }

let home = ProcessInfo.processInfo.environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
let keychainPath = ProcessInfo.processInfo.environment["AGENTDESKTOP_KEYCHAIN"].flatMap { $0.isEmpty ? nil : $0 }

/// The Runtime endpoint to use, refusing the product's own unless allowed;
/// and whether it is the product's.
func resolveEndpoint() -> (Endpoint, isProduct: Bool) {
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
    return (endpoint, isProduct)
}

if pairing {
    let (endpoint, _) = resolveEndpoint()
    let credentials: KeychainCredentialStore
    do { credentials = try KeychainCredentialStore(keychainPath: keychainPath) } catch { fail("\(error)") }
    let client = ACPPairing.unpairedClient(endpoint: endpoint)
    defer { client.close() }
    do {
        let outcome = try ACPPairing.pair(client: client, store: credentials, endpoint: endpoint.path, name: pairName,
                                          grant: ACPPairing.grant(apps: pairApps, durationSeconds: pairDuration), timeout: pairTimeout) {
            FileHandle.standardError.write(Data("agentdesktop-acp-dev: \($0)\n".utf8))
        }
        switch outcome {
        case .paired(let clientId, _):
            print("paired as \(clientId); credential kept in the keychain (profile \(ACPPairing.profile))")
            exit(0)
        case .refused(let id, let state): fail("pairing \(id) was \(state)")
        case .timedOut(let id): fail("the user has not answered pairing \(id) yet")
        }
    } catch {
        fail("pairing failed: \(error)")
    }
}

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
    let (endpoint, isProduct) = resolveEndpoint()
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
    // A4: the bridge speaks as the paired client of profile "acp", kept in the
    // keychain (AGENTDESKTOP_KEYCHAIN for a test copy's keychain file) by
    // `agentdesktop-acp-dev pair`, i.e. by this same program.
    let credential = (try? KeychainCredentialStore(keychainPath: keychainPath).load(endpoint: endpoint.path, profile: ACPPairing.profile)) ?? nil
    if credential == nil {
        FileHandle.standardError.write(Data("agentdesktop-acp: not paired with \(endpoint.path); run `agentdesktop-acp-dev pair --endpoint \(endpoint.path)` first\n".utf8))
    }
    runtime = ACPBridgeRuntimePort(makeClient: ACPBridgeConfiguration.socketFactory(endpoint: endpoint, credential: credential), log: log)
    store = ACPFileSessionStore(directory: URL(fileURLWithPath: state).appendingPathComponent("sessions", isDirectory: true))
}

let connection = ACPStdioConnection.standardIO()
let server = ACPAgentServer(connection: connection, runtime: runtime, projector: projector, store: store)
await server.run()
exit(0)
