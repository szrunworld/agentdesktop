import AgentDesktopClient
import AgentDesktopProtocol
import Foundation

extension CLI {
    func version(_ out: ResultWriter) -> Int32 {
        let build = bundleResources.map(BuildInfo.load(resourcesDirectory:)) ?? .unknown
        var b: [(String, JSONValue)] = [("source", .string(build.source))]
        if let at = build.builtAt { b.append(("builtAt", .string(at))) }
        let data = JSONValue.obj([
            ("product", .string(RuntimeAPI.product)),
            ("cliVersion", .string(RuntimeAPI.productVersion)),
            ("apiVersions", .array(RuntimeAPI.supportedVersions.map(JSONValue.string))),
            ("platform", Platform.current.json),
            ("build", .obj(b)),
            ("executable", .string(executablePath)),
        ])
        out.success(requestId: nil, data: data) {
            "agentdesktop \(RuntimeAPI.productVersion) (\(RuntimeAPI.supportedVersions.joined(separator: ", ")); build \(build.source))"
        }
        return ExitStatus.ok
    }

    /// Start the installed product only when no Runtime answers, then wait
    /// for its handshake. The CLI never serves the Runtime itself.
    func runtimeStart(_ out: ResultWriter, endpoint: Endpoint, waitTimeout: Double) -> Int32 {
        func answered(_ id: RuntimeIdentity, started: Bool) -> Int32 {
            out.success(requestId: nil, data: .obj([("started", .bool(started)), ("identity", id.json)])) {
                (started ? "started " : "already running: ")
                    + "\(id.product) \(id.productVersion), pid \(id.pid), instance \(id.instanceId)\nendpoint \(id.endpoint)"
            }
            return ExitStatus.ok
        }
        func probe() throws -> RuntimeIdentity {
            let c = client(endpoint)
            defer { c.close() }
            return try c.handshake()
        }
        do {
            return answered(try probe(), started: false)
        } catch let e as RuntimeError where e.code == "runtime_offline" {
            guard endpoint.source == .product else {
                let refusal = RuntimeError.invalidArgument(
                    "runtime start starts the installed product's Runtime only; \(endpoint.path) (from \(endpoint.source.rawValue)) must be started by whoever owns it")
                out.failure(requestId: nil, refusal)
                return ExitStatus.of(refusal)
            }
        } catch let e as RuntimeError {
            out.failure(requestId: nil, e)
            return ExitStatus.of(e)
        } catch {
            return ExitStatus.unclassified
        }

        if let failure = launchProduct(appPath) {
            let e = RuntimeError.runtimeOffline("cannot start \(appPath ?? RuntimeAPI.bundleID): \(failure)", endpoint: endpoint.path)
            out.failure(requestId: nil, e)
            return ExitStatus.of(e)
        }
        let until = now().addingTimeInterval(waitTimeout)
        var last = RuntimeError.runtimeOffline("not answering yet", endpoint: endpoint.path)
        repeat {
            do {
                return answered(try probe(), started: true)
            } catch let e as RuntimeError {
                guard e.code == "runtime_offline" else {
                    out.failure(requestId: nil, e)
                    return ExitStatus.of(e)
                }
                last = e
            } catch {
                return ExitStatus.unclassified
            }
            sleep(0.2)
        } while now() < until
        let e = RuntimeError("wait_timeout", "the product was launched but its Runtime did not answer within \(TextTable.duration(waitTimeout)) (\(last.message))",
                             phase: .local, details: .obj([("endpoint", .string(endpoint.path))]))
        out.failure(requestId: nil, e)
        return ExitStatus.of(e)
    }
}
