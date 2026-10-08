// Development entry for the ACP server (docs/acp/03-lanes.md, lane S).
// Not bundled: the shipped command is `agentdesktop acp`, wired into the
// one CLI by the coordinator once the server works (plan step P1-01).
//
//   agentdesktop-acp-dev            stdio + RuntimeClient port + projector (lanes T, R, E)
//   agentdesktop-acp-dev --demo     stdio + a built-in demo port and projector; sessions in a temp dir
//
// No real GUI input happens here in either mode: the demo port only
// produces scripted events.
import AgentDesktopACP
import Foundation

enum ACPAgentServerDevWiring {
    /// TODO(lane T): return the stdio connection, e.g.
    /// `ACPStdioConnection(input: .standardInput, output: .standardOutput)`,
    /// once lane T's type is on this branch.
    static func stdioConnection() -> (any ACPConnection)? { nil }

    /// TODO(lane R): return the RuntimeClient-backed `ACPRuntimePort`.
    static func runtimePort() -> (any ACPRuntimePort)? { nil }

    /// TODO(lane E): return the redacting projector.
    static func projector() -> (any ACPEventProjector)? { nil }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("agentdesktop-acp-dev: \(message)\n".utf8))
    exit(2)
}

let args = Array(CommandLine.arguments.dropFirst())
if args.contains("--help") || args.contains("-h") {
    print("usage: agentdesktop-acp-dev [--demo]")
    exit(0)
}
if let unknown = args.first(where: { $0 != "--demo" }) { fail("unknown argument \(unknown)") }
let demo = args.contains("--demo")

guard let connection = ACPAgentServerDevWiring.stdioConnection() else {
    fail("the stdio transport (lane T) is not on this build yet")
}

let runtime: any ACPRuntimePort
let projector: any ACPEventProjector
let store: ACPFileSessionStore
if demo {
    runtime = ACPAgentServerDemoPort()
    projector = ACPAgentServerDemoProjector()
    store = ACPFileSessionStore(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("agentdesktop-acp-dev-\(getpid())/sessions", isDirectory: true))
} else {
    guard let r = ACPAgentServerDevWiring.runtimePort(), let p = ACPAgentServerDevWiring.projector() else {
        fail("the Runtime port (lane R) and the projector (lane E) are not on this build yet; use --demo")
    }
    runtime = r
    projector = p
    store = ACPFileSessionStore()
}

let server = ACPAgentServer(connection: connection, runtime: runtime, projector: projector, store: store)
await server.run()
exit(0)
