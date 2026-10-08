import AgentDesktopClient
import AgentDesktopProtocol
import Foundation

extension CLI {
    /// `agents pair`: as an unpaired app, ask to pair, show the short code
    /// for the owner to compare, and wait on the same connection (only it
    /// can collect the credential) until the owner answers.
    func agentsPair(name: String, publisher: String?, grant: JSONValue, outFile: String, timeout: Double,
                    _ out: ResultWriter, endpoint: Endpoint) -> Int32 {
        let client = SocketRuntimeClient(endpoint: endpoint, info: CLI.clientInfo, timeout: 10, credential: nil)
        defer { client.close() }
        do {
            _ = try client.handshake()
            var params: [(String, JSONValue)] = [("agentName", .string(name)), ("requested", grant)]
            if let publisher { params.insert(("publisher", .string(publisher)), at: 1) }
            let started = try client.call(RuntimeRequest(.pairingStart, params: .obj(params)))
            let pairingId = started["pairingId"]?.stringValue ?? ""
            stderr("pairing \(pairingId): code \(started["shortCode"]?.stringValue ?? "?") — approve it in AgentDesktop (agentdesktop agents approve \(pairingId) …)")
            let deadline = now().addingTimeInterval(timeout)
            while true {
                if interrupted() { return 130 }
                let status = try client.call(RuntimeRequest(.pairingStatus, params: .obj([("pairingId", .string(pairingId))])))
                switch status["state"]?.stringValue {
                case "approved":
                    guard let c = status["credential"], let id = c["clientId"]?.stringValue, let token = c["token"]?.stringValue else {
                        throw RuntimeError("execution_failed", "approved, but the credential was already collected", phase: .handler)
                    }
                    try ClientCredential(clientId: id, token: token).save(to: outFile)
                    let shown = JSONValue.obj([("clientId", .string(id)), ("credentialFile", .string(outFile)),
                                               ("grant", status["grant"] ?? .null)])
                    out.success(requestId: nil, data: shown) { "paired as \(id); credential saved to \(outFile)" }
                    return ExitStatus.ok
                case "denied", "expired":
                    let e = RuntimeError("permission_denied", "pairing \(pairingId) was \(status["state"]?.stringValue ?? "")",
                                         phase: .handler, details: .obj([("pairingId", .string(pairingId))]))
                    out.failure(requestId: nil, e)
                    return ExitStatus.of(e)
                default:
                    if now() >= deadline {
                        let e = RuntimeError("wait_timeout", "the owner has not answered pairing \(pairingId) yet", phase: .local)
                        out.failure(requestId: nil, e)
                        return ExitStatus.of(e)
                    }
                    sleep(1)
                }
            }
        } catch let e as RuntimeError {
            out.failure(requestId: nil, e)
            return ExitStatus.of(e)
        } catch {
            stderr("agentdesktop: \(error)")
            return ExitStatus.unclassified
        }
    }
}
