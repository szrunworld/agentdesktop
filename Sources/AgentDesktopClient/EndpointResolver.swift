import AgentDesktopProtocol
import Foundation

/// Where the Runtime listens, and why this path was chosen.
public struct Endpoint: Equatable, Sendable {
    public enum Source: String, Sendable {
        /// `--endpoint` on the command line.
        case option
        /// `AGENTDESKTOP_ENDPOINT`, for a side instance under test.
        case environment
        /// The installed product's own endpoint.
        case product
    }

    public var path: String
    public var source: Source

    public init(path: String, source: Source) {
        self.path = path
        self.source = source
    }
}

public enum EndpointResolver {
    public static let environmentKey = "AGENTDESKTOP_ENDPOINT"

    /// `~/Library/Application Support/AgentDesktop/runtime.sock`, beside the
    /// engine's control.sock. The host's Runtime server creates it.
    public static func productEndpoint(home: String) -> String {
        home + "/Library/Application Support/AgentDesktop/runtime.sock"
    }

    public static func resolve(option: String?, environment: [String: String]) -> Endpoint {
        func expand(_ p: String) -> String { (p as NSString).expandingTildeInPath }
        if let option { return Endpoint(path: expand(option), source: .option) }
        if let env = environment[environmentKey], !env.isEmpty {
            return Endpoint(path: expand(env), source: .environment)
        }
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        return Endpoint(path: productEndpoint(home: home), source: .product)
    }

    /// What is at `path` before connecting: nil when it is a socket owned by
    /// this user, otherwise the reason not to connect. A socket of another
    /// user is refused even when it would accept us.
    public static func inspect(_ path: String) -> RuntimeError? {
        var st = stat()
        if lstat(path, &st) != 0 {
            let reason = errno == ENOENT ? "nothing is listening: \(path) does not exist"
                                         : "cannot read \(path): \(String(cString: strerror(errno)))"
            return .runtimeOffline(reason, endpoint: path)
        }
        if (st.st_mode & S_IFMT) != S_IFSOCK {
            return .runtimeOffline("\(path) is not a socket", endpoint: path)
        }
        if st.st_uid != getuid() {
            return RuntimeError("permission_denied", "\(path) belongs to uid \(st.st_uid), not this user",
                                phase: .connect, notSent: true, details: .obj([("endpoint", .string(path))]))
        }
        return nil
    }
}
