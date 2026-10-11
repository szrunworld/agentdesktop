import AgentDesktopClient
import AgentDesktopProtocol
import CryptoKit
import Foundation

extension CLI {
    /// One Runtime request from a command line. A write is recorded with
    /// its requestId before it is sent; its outcome comes back from the
    /// Runtime's ledger, so repeating the same command line with the same
    /// --request-id never runs it twice.
    func perform(_ call: RuntimeCall, _ out: ResultWriter, endpoint: Endpoint, attach: ExecContext? = nil) -> Int32 {
        var params = call.params
        if let file = call.textFile {
            // Read here so the text never sits in argv or the logs.
            guard let data = try? readFile(file), let text = String(data: data, encoding: .utf8), !text.isEmpty else {
                let e = RuntimeError.invalidArgument("cannot read UTF-8 text from \(file)")
                out.failure(requestId: nil, e)
                return ExitStatus.of(e)
            }
            if let action = params["action"] { params = params.setting("action", action.setting("text", .string(text))) }
        }
        return withClient(out, endpoint: endpoint) { client in
            _ = try client.handshake()
            if let attach, call.context.runId != nil {
                _ = try client.call(RuntimeRequest(.runAttach, params: .obj([("runId", .string(attach.runId)),
                                                                             ("token", .string(attach.token))])))
            }
            var request = RuntimeRequest(call.method, requestId: call.requestId ?? RuntimeRequest.newId(), params: params)
            request.context = call.context
            if call.mutation {
                recordRequest(request.requestId, request.method, endpoint.path)
                if out.format == .text { stderr("request \(request.requestId)") }
            }
            var data: JSONValue
            do {
                data = try client.call(request)
            } catch var e as RuntimeError {
                // Sent but unanswered: for a write, whether it ran is unknown.
                if call.mutation, e.code == "connection_lost" {
                    e = RuntimeError("request_acceptance_unknown",
                                     "\(e.message); look it up with: agentdesktop request show \(request.requestId)",
                                     phase: .transport, details: .obj([("requestId", .string(request.requestId))]))
                }
                out.failure(requestId: request.requestId, e)
                return ExitStatus.of(e)
            }
            if let target = call.artifactOutput {
                guard let id = (data["image"]?["artifactId"] ?? data["artifactId"])?.stringValue else {
                    let e = RuntimeError("execution_failed", "the observation has no screenshot to export", phase: .local)
                    out.failure(requestId: request.requestId, e)
                    return ExitStatus.of(e)
                }
                do {
                    let bytes = try Self.fetchArtifact(id, client)
                    try writeFile(bytes, target)
                } catch let e as RuntimeError {
                    out.failure(requestId: request.requestId, e)
                    return ExitStatus.of(e)
                } catch {
                    let e = RuntimeError("execution_failed", "cannot write \(target): \(error.localizedDescription)", phase: .local)
                    out.failure(requestId: request.requestId, e)
                    return ExitStatus.of(e)
                }
                data = data.setting("savedTo", .string(target))
            }
            let shown = data
            out.success(requestId: request.requestId, data: shown) { Self.callText(call.method, shown) }
            return ExitStatus.ok
        }
    }

    /// The whole artifact, chunk by chunk; the digest must match what the
    /// Runtime reported, or nothing is written.
    static func fetchArtifact(_ id: String, _ client: RuntimeClient) throws -> Data {
        let info = try client.call(RuntimeRequest(.artifactShow, params: .obj([("artifactId", .string(id))])))
        var bytes = Data()
        while true {
            let chunk = try client.call(RuntimeRequest(.artifactRead, params: .obj([("artifactId", .string(id)),
                                                                                   ("offset", .int(bytes.count))])))
            guard let b64 = chunk["dataBase64"]?.stringValue, let part = Data(base64Encoded: b64) else {
                throw RuntimeError("execution_failed", "artifact \(id) came back unreadable", phase: .local)
            }
            bytes.append(part)
            if chunk["eof"]?.boolValue ?? true || part.isEmpty { break }
        }
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard sha == info["sha256"]?.stringValue else {
            throw RuntimeError("execution_failed", "artifact \(id) changed while it was read", phase: .local)
        }
        return bytes
    }

    static func runText(_ d: JSONValue) -> String {
        func s(_ v: JSONValue?) -> String { v?.stringValue ?? "-" }
        var line = "\(s(d["runId"]))  \(s(d["kind"]))  \(s(d["phase"]))"
            + (d["outcome"]?.stringValue.map { "/\($0)" } ?? "") + "  quiescence \(s(d["quiescence"]))"
            + "  \(s(d["ownership"]))/\(s(d["lifetime"]))  origin \(s(d["origin"]))"
            + "  desktop \(s(d["desktopId"]))  session \(s(d["sessionId"]))"
        if let r = d["closingReason"]?.stringValue { line += "  reason \(r)" }
        if let u = d["unknownActions"]?.intValue, u > 0 { line += "  unknown actions \(u)" }
        line += "\nreceipts \((d["receipts"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: ", "))"
        return line
    }

    static func appendRequestLog(_ requestId: String, _ method: String, _ endpoint: String) {
        let dir = NSHomeDirectory() + "/Library/Application Support/AgentDesktop/cli"
        let path = dir + "/requests.jsonl"
        let line = JSONValue.obj([("requestId", .string(requestId)), ("method", .string(method)),
                                  ("endpoint", .string(endpoint)), ("at", .string(Timestamp.string(Date())))]).encoded() + "\n"
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
            guard fd >= 0 else { return }
            defer { close(fd) }
            _ = line.withCString { write(fd, $0, strlen($0)) }
        } catch {}
    }

    static func callText(_ method: RuntimeMethod, _ d: JSONValue) -> String {
        func s(_ v: JSONValue?) -> String { v?.stringValue ?? "-" }
        func i(_ v: JSONValue?) -> String { v?.intValue.map(String.init) ?? "-" }
        func frame(_ f: JSONValue?) -> String {
            guard let f else { return "-" }
            func n(_ k: String) -> String { f[k]?.doubleValue.map { String(Int($0)) } ?? "?" }
            return "\(n("x")),\(n("y")) \(n("width"))x\(n("height"))"
        }
        switch method {
        case .desktopCreate, .windowBind, .windowUnbind:
            var lines = ["\(s(d["desktopId"]))  \(s(d["name"]))  \(s(d["state"]))  screen \(frame(d["screen"]?["frame"]))"
                + (d["screen"]?["hiDPI"]?.boolValue == true ? " @2x" : "")]
            if let b = d["binding"], !b.isNull {
                lines.append("target  \(s(b["appName"])) pid \(i(b["process"]?["pid"])) window \(i(b["windowId"])) generation \(i(b["generation"]))")
            } else {
                lines.append("target  none")
            }
            return lines.joined(separator: "\n")
        case .desktopDestroy:
            return "destroyed \(s(d["desktopId"]))"
        case .appLaunch:
            let rows = (d["windows"]?.arrayValue ?? []).map { [i($0["windowId"]), s($0["appName"]), frame($0["frame"]), s($0["title"])] }
            return "launched pid \(i(d["process"]?["pid"])) on \(s(d["desktopId"]))"
                + (rows.isEmpty ? "" : "\n" + TextTable.render(["WINDOW", "APP", "FRAME", "TITLE"], rows))
        case .sessionOpen, .sessionShow, .sessionClose:
            return "\(s(d["sessionId"]))  \(s(d["state"]))  desktop \(s(d["desktopId"]))"
        case .observe:
            var lines = ["snapshot \(s(d["snapshotId"]))  desktop \(s(d["desktopId"]))  at \(s(d["capturedAt"]))"]
            if let img = d["image"], !img.isNull {
                lines.append("image    \(s(d["savedTo"]) != "-" ? s(d["savedTo"]) : s(img["artifactId"]))  \(i(img["width"]))x\(i(img["height"])) px, scale \(img["transform"]?["scale"]?.doubleValue.map { String($0) } ?? "?")")
            }
            if let t = d["target"], !t.isNull {
                lines.append("target   \(s(t["title"])) pid \(i(t["process"]?["pid"])) window \(i(t["windowId"])) at \(frame(t["windowFrame"]))")
            } else {
                lines.append("target   none (bind a window to read elements)")
            }
            let rows = (d["elements"]?.arrayValue ?? []).map { e -> [String] in
                [s(e["id"]), s(e["role"]), e["label"]?.stringValue ?? "", e["value"]?.stringValue ?? "", frame(e["frame"])]
            }
            if !rows.isEmpty { lines.append(TextTable.render(["ELEMENT", "ROLE", "LABEL", "VALUE", "FRAME"], rows)) }
            return lines.joined(separator: "\n")
        case .act:
            var line = "\(s(d["delivery"]))/\(s(d["execution"]))  route \(s(d["route"]))  receipt \(s(d["receiptId"]))  run \(s(d["runId"]))"
            // The session it ran in: with --desktop alone it may be one the
            // Runtime just opened, which the caller closes (session close)
            // before desktop destroy (Codex P2 on #276).
            if let sid = d["sessionId"]?.stringValue { line += "  session \(sid)" }
            if let p = d["target"]?["point"], !p.isNull {
                line += "  at \(p["x"]?.doubleValue.map { String(Int($0)) } ?? "?"),\(p["y"]?.doubleValue.map { String(Int($0)) } ?? "?")"
            }
            return line
        case .wait:
            return "satisfied  snapshot \(s(d["snapshotId"]))" + ((d["matches"]?.arrayValue ?? []).isEmpty ? "" : "\n" +
                TextTable.render(["ELEMENT", "ROLE", "LABEL", "FRAME"], (d["matches"]?.arrayValue ?? []).map {
                    [s($0["id"]), s($0["role"]), $0["label"]?.stringValue ?? "", frame($0["frame"])] }))
        case .runShow:
            return runText(d)
        case .runList:
            let rows = (d["runs"]?.arrayValue ?? []).map { r -> [String] in
                [s(r["runId"]), s(r["origin"]), s(r["lifetime"]), s(r["phase"]) + (r["outcome"]?.stringValue.map { "/\($0)" } ?? ""),
                 s(r["quiescence"]), s(r["desktopId"]), s(r["createdAt"])]
            }
            let table = rows.isEmpty ? "no runs" : TextTable.render(["RUN", "ORIGIN", "LIFETIME", "PHASE", "QUIESCENCE", "DESKTOP", "CREATED"], rows)
            return table + (d["next"]?.stringValue.map { "\nmore: --cursor '\($0)'" } ?? "")
        case .stopAll:
            let pending = (d["pending"]?.arrayValue ?? []).compactMap(\.stringValue)
            return "input \(s(d["admission"]))  stopped \(d["runs"]?.arrayValue?.count ?? 0) run(s)"
                + (pending.isEmpty ? "" : "  still stopping: \(pending.joined(separator: ", "))")
        case .enableInput:
            return "input \(s(d["admission"])); stopped Runs are not resumed"
        case .requestShow:
            var line = "\(s(d["requestId"]))  \(s(d["method"]))  \(s(d["state"]))  accepted \(s(d["acceptedAt"]))"
            if let f = d["finishedAt"]?.stringValue { line += "  finished \(f)" }
            if let e = d["outcome"]?["error"] { line += "\nerror \(s(e["code"])): \(s(e["message"]))" }
            return line
        default:
            return d.encoded()
        }
    }
}
