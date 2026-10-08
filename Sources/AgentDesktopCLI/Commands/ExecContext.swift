import AgentDesktopContracts
import AgentDesktopProtocol
import Foundation

/// What `session exec` hands its child: the endpoint, Session and Run, and
/// the token that lets the child's own connections act in that Run. Kept
/// in an owner-only file named by AGENTDESKTOP_CONTEXT, never in argv,
/// output or logs.
struct ExecContext: Equatable {
    static let environmentKey = "AGENTDESKTOP_CONTEXT"

    var endpoint: String
    var desktopId: String
    var sessionId: String
    var runId: String
    var token: String

    var json: JSONValue {
        .obj([("endpoint", .string(endpoint)), ("desktopId", .string(desktopId)), ("sessionId", .string(sessionId)),
              ("runId", .string(runId)), ("token", .string(token))])
    }

    /// Write the file owner-only; its path.
    func write(directory: String) throws -> String {
        let path = directory + "/agentdesktop-context-\(runId).json"
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RuntimeError("internal_error", "cannot create \(path): \(String(cString: strerror(errno)))", phase: .local) }
        defer { close(fd) }
        let data = json.encoded()
        guard data.withCString({ Darwin.write(fd, $0, strlen($0)) }) == data.utf8.count else {
            throw RuntimeError("internal_error", "cannot write \(path)", phase: .local)
        }
        return path
    }

    /// Read the context named by the environment, refusing a file another
    /// user owns or others can read.
    static func load(environment: [String: String]) throws -> ExecContext? {
        guard let path = environment[environmentKey], !path.isEmpty else { return nil }
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            throw RuntimeError.invalidArgument("\(environmentKey) names \(path), which is not a file")
        }
        guard st.st_uid == getuid(), st.st_mode & 0o077 == 0 else {
            throw RuntimeError("permission_denied", "\(path) must be this user's and not readable by others", phase: .local, notSent: true)
        }
        guard let v = try? StrictJSON.parse(Data(contentsOf: URL(fileURLWithPath: path))),
              let e = v["endpoint"]?.stringValue, let d = v["desktopId"]?.stringValue, let s = v["sessionId"]?.stringValue,
              let r = v["runId"]?.stringValue, let t = v["token"]?.stringValue
        else { throw RuntimeError.invalidArgument("\(path) is not a session exec context") }
        return ExecContext(endpoint: e, desktopId: d, sessionId: s, runId: r, token: t)
    }
}
