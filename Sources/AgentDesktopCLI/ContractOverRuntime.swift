import AgentDesktopClient
import AgentDesktopContracts
import AgentDesktopProtocol
import Foundation

/// The `rpc`, `ai` and `gui` groups still compose ai/1 requests (their
/// files and flags are written that way), but nothing listens for ai/1 any
/// more (A2): this sends each one to the Runtime's single endpoint as the
/// runtime/1 call it stands for and turns the answer back into the ai/1
/// response those commands print. PR2b-2 retires the ai/1 shapes from the
/// CLI altogether.
public enum ContractOverRuntime {
    public static func exchange(_ frame: Data, path: String) -> FrameReader.Result {
        let body = frame.last == 0x0A ? frame.dropLast() : frame
        guard let req = try? StrictJSON.parse(Data(body)),
              let aiRequestId = req["requestId"]?.stringValue, let command = req["command"]?.stringValue else {
            return .frame(Envelope.failure(requestId: nil, error: ContractError(.validationError, "not an ai/1 request")).encodedData())
        }
        // The idempotency key is the requestId on runtime/1.
        let requestId = req["context"]?["idempotencyKey"]?.stringValue ?? aiRequestId
        var request = RuntimeRequest(requestId: requestId, method: command, params: req["params"] ?? .obj([]))
        request.deadline = req["context"]?["deadlineAt"]?.stringValue
        let client = SocketRuntimeClient(endpoint: Endpoint(path: path, source: .option),
                                         info: ClientInfo(name: "agentdesktop-cli", version: CLI.clientInfo.version), timeout: 120)
        defer { client.close() }
        let reply: JSONValue
        do {
            _ = try client.handshake()
            if command == "runtime.capabilities" {
                // ai/1's capabilities is the `gui` section of the one
                // runtime.capabilities answer.
                let all = try client.call(RuntimeRequest(.capabilities))
                guard let gui = all["gui"] else {
                    throw RuntimeError("capability_missing", "the AI/GUI service is not running in this Runtime", phase: .handler)
                }
                reply = Envelope.success(requestId: aiRequestId, result: gui)
            } else {
                reply = Envelope.success(requestId: aiRequestId, result: try client.call(request))
            }
        } catch let e as RuntimeError where e.code == "runtime_offline" || e.phase == .connect {
            return .ioError(ECONNREFUSED)
        } catch let e as RuntimeError {
            reply = Envelope.failure(requestId: aiRequestId, error: contractError(e))
        } catch {
            return .ioError(EIO)
        }
        return .frame(reply.encodedData())
    }

    /// runtime/1 → ai/1, using the code the service answered with when the
    /// error came from it.
    static func contractError(_ e: RuntimeError) -> ContractError {
        let original = e.details?["aiCode"]?.stringValue.flatMap(ErrorCode.init(rawValue:))
        let code: ErrorCode = original ?? {
            switch e.code {
            case "invalid_argument", "schema_invalid": return .validationError
            case "not_found": return .notFound
            case "permission_denied", "ownership_escalation_denied": return .forbidden
            case "capability_missing", "version_mismatch": return .unsupportedCommand
            case "conflict": return .configConflict
            case "idempotency_conflict": return .idempotencyConflict
            case "deadline_exceeded": return .deadlineExceeded
            case "control_busy": return .desktopBusy
            case "stale_observation": return .staleObservation
            default: return .internalError
            }
        }()
        // ai/1 details carry only these keys.
        let allowed = ["retryAfterMs", "currentRevision", "resourceId", "operationId", "runId", "reasonCode", "fieldErrors"]
        let kept = (e.details?.objectMembers ?? []).filter { allowed.contains($0.key) }
        return ContractError(code, e.message, retryable: e.retryable, details: kept.isEmpty ? nil : .object(kept))
    }
}
