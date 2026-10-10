import AgentDesktopProtocol
import Foundation

extension RuntimeService {
    func bindingStatus(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        withDesktop(p["desktopId"], as: c, method: "desktop.bindingStatus") { d in
            func result(_ state: String, _ reason: String, binding: TargetBinding? = nil) -> JSONValue {
                var fields: [(String, JSONValue)] = [("desktopId", .string(d.desktopId)),
                    ("state", .string(state)), ("reason", .string(reason))]
                if let binding { fields += [("generation", .int(binding.generation)), ("binding", binding.json)] }
                return .obj(fields)
            }
            guard let b = d.binding else { return result("unbound", "no_binding") }
            guard mayKnowBinding(c, d, b) else { return result("needs_authorization", "window_grant_missing") }
            guard backend.processIdentity(b.process.pid) == b.process else {
                return result("invalid", "process_changed", binding: b)
            }
            do {
                _ = try exposedTarget(d, b, notSent: true)
                return result("valid", "valid", binding: b)
            } catch let error as RuntimeError {
                let reason = error.details?["reason"]?.stringValue ?? error.code
                let invalid = ["window_gone", "display_changed"].contains(reason)
                return result(invalid ? "invalid" : "blocked", reason, binding: b)
            }
        }
    }
}
