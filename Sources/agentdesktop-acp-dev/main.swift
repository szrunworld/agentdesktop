// Development entry for the ACP server (docs/acp/03-lanes.md, lane S).
// Not bundled: the shipped command is `agentdesktop acp`, wired into the
// one CLI by the coordinator (plan step P1-01).
//
//   agentdesktop-acp-dev --endpoint PATH     stdio ⇄ server ⇄ runtime/1 at PATH (a side instance)
//   AGENTDESKTOP_ENDPOINT=PATH agentdesktop-acp-dev
//   agentdesktop-acp-dev --demo              stdio ⇄ server ⇄ built-in scripted port (no Runtime)
//   agentdesktop-acp-dev pair --endpoint PATH   pair this program with the Runtime (A4), once
//   agentdesktop-acp-dev request-window …       ask the user for the window unit.run works in (#246)
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
       agentdesktop-acp-dev pair --desktops ID,… [--endpoint PATH [--allow-product-endpoint]] [--name NAME] [--apps ID,…] [--duration 8h] [--wait-timeout SECONDS]
       agentdesktop-acp-dev request-window --desktop ID --bundle-id APP [--window-id N] [--endpoint PATH [--allow-product-endpoint]] [--duration 8h]
  --demo                     built-in scripted port; sessions in a temporary directory
  --endpoint PATH            Runtime socket of a side instance (else AGENTDESKTOP_ENDPOINT)
  --allow-product-endpoint   permit the installed product's own endpoint
  --state-dir DIR            where ACP sessions and the submission log live
                             (default: beside a side-instance endpoint, <dir>/acp)
  pair                       ask to pair as this program; confirm in the Agent Desktop window.
                             The credential goes to the keychain (profile "acp"; AGENTDESKTOP_KEYCHAIN
                             for a test copy's keychain file), where serving reads it
  --desktops ID,…            required: the Desktops the bridge may use, created beforehand in the
                             Agent Desktop main window (explicit ids; `created` is refused)
  --name NAME                name shown in the confirmation window (default ACP)
  --apps ID,…                bundle ids whose windows the bridge may later ask for (default none)
  --duration 1h|8h|7d        how long the grant lasts, up to 7d (default: the Runtime's, 1h)
  --wait-timeout SECONDS     how long to wait for the answer (default 180)
  request-window             as the paired bridge, ask for observe and act on one window of APP on
                             the Desktop (hub.windows.request; confirm in the Agent Desktop window),
                             then check it is the window bound there. Never retried
  --desktop ID               the Desktop (one of the paired --desktops)
  --bundle-id APP            the app of the window bound on that Desktop
  --window-id N              that window, when the app has several (else its frontmost)
"""

var pairing = false
var demo = false
var endpointOption: String?
var allowProduct = false
var stateDir: String?
var pairName = "ACP"
var pairApps: [String] = []
var pairDesktops: [String]?
var pairDuration: Int?
var pairTimeout = 180.0
var requestingWindow = false
var windowDesktop: String?
var windowBundle: String?
var windowId: Int?
var rest = Array(CommandLine.arguments.dropFirst())
if rest.first == "pair" { pairing = true; rest.removeFirst() }
else if rest.first == "request-window" { requestingWindow = true; rest.removeFirst() }
// Options that belong to some modes only; the others refuse them.
let modeName = pairing ? "to pair" : requestingWindow ? "to request-window" : "when serving"
let allowed: Set<String> = pairing ? ["--desktops", "--name", "--apps", "--duration", "--wait-timeout"]
    : requestingWindow ? ["--desktop", "--bundle-id", "--window-id", "--duration"]
    : ["--demo", "--state-dir"]
let modal: Set<String> = ["--demo", "--state-dir", "--desktops", "--name", "--apps", "--duration", "--wait-timeout",
                          "--desktop", "--bundle-id", "--window-id"]
while !rest.isEmpty {
    let a = rest.removeFirst()
    if modal.contains(a), !allowed.contains(a) {
        fail("\(a) does not apply \(modeName)\n\(usage)")
    }
    switch a {
    case "-h", "--help": print(usage); exit(0)
    case "--demo": demo = true
    case "--allow-product-endpoint": allowProduct = true
    case "--endpoint", "--state-dir":
        guard !rest.isEmpty, !rest[0].isEmpty else { fail("\(a) needs a path") }
        if a == "--endpoint" { endpointOption = rest.removeFirst() } else { stateDir = rest.removeFirst() }
    case "--desktops", "--name", "--apps", "--duration", "--wait-timeout", "--desktop", "--bundle-id", "--window-id":
        guard !rest.isEmpty, !rest[0].isEmpty else { fail("\(a) needs a value") }
        let v = rest.removeFirst()
        switch a {
        case "--name": pairName = v
        case "--desktop":
            guard let ids = ACPPairing.desktopIds(v), ids.count == 1 else { fail("--desktop needs one Desktop id, got \(v)") }
            windowDesktop = ids[0]
        case "--bundle-id": windowBundle = v
        case "--window-id":
            guard let n = Int(v), n > 0, n <= Int(UInt32.max) else { fail("--window-id needs a window number, got \(v)") }
            windowId = n
        case "--desktops":
            guard let ids = ACPPairing.desktopIds(v) else {
                fail("--desktops needs Desktop ids from the Agent Desktop main window, comma separated (not `created`), got \(v)")
            }
            pairDesktops = ids
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
    guard let pairDesktops else { fail("pair needs --desktops: the Desktop ids the bridge may use, created in the Agent Desktop main window") }
    let (endpoint, _) = resolveEndpoint()
    let credentials: KeychainCredentialStore
    do { credentials = try KeychainCredentialStore(keychainPath: keychainPath) } catch { fail("\(error)") }
    let client = ACPPairing.unpairedClient(endpoint: endpoint)
    defer { client.close() }
    do {
        let outcome = try ACPPairing.pair(client: client, store: credentials, endpoint: endpoint.path, name: pairName,
                                          grant: ACPPairing.grant(desktops: pairDesktops, apps: pairApps, durationSeconds: pairDuration), timeout: pairTimeout) {
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

if requestingWindow {
    guard let windowDesktop, let windowBundle else { fail("request-window needs --desktop and --bundle-id\n\(usage)") }
    let (endpoint, _) = resolveEndpoint()
    let stored: ClientCredential?
    do { stored = try KeychainCredentialStore(keychainPath: keychainPath).load(endpoint: endpoint.path, profile: ACPPairing.profile) } catch {
        fail("cannot read the bridge's credential: \(error)")
    }
    guard let credential = stored else { fail("not paired with \(endpoint.path); run `agentdesktop-acp-dev pair --endpoint \(endpoint.path) --desktops …` first") }
    let client = ACPWindowRequest.client(endpoint: endpoint, credential: credential)
    defer { client.close() }
    do {
        let outcome = try ACPWindowRequest.request(client: client, desktopId: windowDesktop, bundleId: windowBundle,
                                                   windowId: windowId, durationSeconds: pairDuration) {
            FileHandle.standardError.write(Data("agentdesktop-acp-dev: \($0)\n".utf8))
        }
        switch outcome {
        case let .granted(id, expiresAt):
            print("window grant \(id) for the window bound on \(windowDesktop)\(expiresAt.map { ", until \($0)" } ?? "")")
            exit(0)
        case let .notTheBoundWindow(id):
            fail("window grant \(id) was approved, but it is not for the window bound on \(windowDesktop) (or nothing is bound there); unit.run will refuse it. Withdraw it in the Agent Desktop window, bind the intended window, and ask again with --window-id")
        }
    } catch {
        fail("window request failed: \(error)")
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
