import AgentDesktopProtocol
import Foundation

/// Output format chosen with --format.
enum OutputFormat: String {
    case text, json, jsonl
}

/// One parsed command line. Parsing never connects anywhere: a bad
/// argument is refused before any client exists.
struct RuntimeInvocation: Equatable {
    enum Command: Equatable {
        case help(topic: [String])
        case version
        case runtimeStart(waitTimeout: Double)
        case runtimeStatus
        case runtimeCapabilities
        case doctor
        case desktopList
        case desktopShow(id: String)
        case appList(includeBackground: Bool)
        case windowList(pid: Int32?, bundleId: String?, includeOffscreen: Bool)
        /// Any other Runtime method, already mapped to its params.
        case call(RuntimeCall)
        /// run events, optionally following new events until the Run ends.
        case runEvents(runId: String, after: Int, follow: Bool)
        /// events.subscribe: pushed events of one Run, or of every Run.
        case eventsWatch(runId: String?, after: Int?)
        /// run wait: observe until the Run ends (ended implies quiescent).
        case runWait(runId: String, timeout: Double)
        /// run cancel, optionally waiting for quiescence.
        case runCancel(runId: String, requestId: String?, wait: Bool, timeout: Double)
        /// mcp: serve MCP on stdio.
        case mcp(profile: String?)
        /// This CLI pairs: start, wait for the user to confirm in the Agent
        /// Desktop window, keep the credential in the keychain.
        case agentsPair(name: String, publisher: String?, grant: JSONValue, profile: String?, timeout: Double)
        /// session exec: own a Run while a child program acts in it.
        case sessionExec(desktopId: String?, sessionId: String?, argv: [String])
    }

    var command: Command
    var format: OutputFormat = .text
    var endpoint: String?
}

/// One Runtime request a command line maps to.
struct RuntimeCall: Equatable {
    var method: RuntimeMethod
    var params: JSONValue = .obj([])
    var context = RequestContext()
    /// A write: goes through the ledger, carries a requestId the CLI
    /// records before sending.
    var mutation = false
    /// --request-id; generated when absent.
    var requestId: String?
    /// observe --image-output / artifact get --out: save the artifact here,
    /// read by id through artifact.read.
    var artifactOutput: String?
    /// --text-file: read into action.text just before sending.
    var textFile: String?
    /// Target may come from AGENTDESKTOP_CONTEXT (session exec).
    var usesContext = false
}

/// The command table. A command is listed here only once it is implemented.
enum CommandRouter {
    struct Spec {
        let words: [String]
        let summary: String
        /// Option name → takes a value.
        let options: [String: Bool]
        let positionals: [String]
        let build: (_ options: [String: String], _ positionals: [String]) throws -> RuntimeInvocation.Command
    }

    static let globalOptions: [String: Bool] = ["--format": true, "--endpoint": true]

    /// Command groups of the AI/GUI contract v1 (DEV-SPEC §13), served by
    /// ContractCLI with its own flags (--json, --socket) and exit codes.
    static let contractGroups: Set<String> = ["rpc", "ai", "gui"]

    /// True when the first command word, after ContractCLI's own leading
    /// options, names a contract v1 group.
    static func isContractCommand(_ args: [String]) -> Bool {
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--json": i += 1
            case "--socket": i += 2
            default: return contractGroups.contains(args[i])
            }
        }
        return false
    }

    static let specs: [Spec] = [
        Spec(words: ["agents", "list"], summary: "paired apps, their grants, and open pairing requests (confirmed in the Agent Desktop window)",
             options: [:], positionals: []) { _, _ in .call(RuntimeCall(method: .clientsList)) },
        Spec(words: ["agents", "show"], summary: "one paired app: grant and open connections (confirmed in the Agent Desktop window)",
             options: [:], positionals: ["clientId"]) { _, p in
            .call(RuntimeCall(method: .clientsShow, params: .obj([("clientId", .string(p[0]))])))
        },
        Spec(words: ["agents", "approve"], summary: "approve another app's pairing request within what it asked for (confirmed in the Agent Desktop window)",
             options: grantOptions.merging(["--request-id": true]) { a, _ in a }, positionals: ["pairingId"]) { o, p in
            try write(.pairingApprove, .obj([("pairingId", .string(p[0])), ("grant", try grant(o))]), o)
        },
        Spec(words: ["agents", "deny"], summary: "deny a pairing request (confirmed in the Agent Desktop window)",
             options: ["--request-id": true], positionals: ["pairingId"]) { o, p in
            try write(.pairingDeny, .obj([("pairingId", .string(p[0]))]), o)
        },
        Spec(words: ["agents", "grant"], summary: "replace another app's grant; narrowing applies at once (confirmed in the Agent Desktop window)",
             options: grantOptions.merging(["--request-id": true]) { a, _ in a }, positionals: ["clientId"]) { o, p in
            var params = (try grant(o)).objectMembers ?? []
            params.insert((key: "clientId", value: .string(p[0])), at: 0)
            return try write(.grantsSet, .object(params), o)
        },
        Spec(words: ["agents", "revoke"], summary: "remove a paired app: its credential stops working and its Runs stop (confirmed in the Agent Desktop window)",
             options: ["--request-id": true], positionals: ["clientId"]) { o, p in
            try write(.clientsRevoke, .obj([("clientId", .string(p[0]))]), o)
        },
        Spec(words: ["agents", "connections"], summary: "open connections and who each one is (confirmed in the Agent Desktop window)",
             options: [:], positionals: []) { _, _ in .call(RuntimeCall(method: .connectionsList)) },
        Spec(words: ["agents", "pair"], summary: "pair this CLI (or an MCP host, --profile mcp): the user confirms in the Agent Desktop window; the credential goes to the keychain",
             options: grantOptions.merging(["--name": true, "--publisher": true, "--profile": true, "--wait-timeout": true]) { a, _ in a },
             positionals: []) { o, _ in
            guard let name = o["--name"] else { throw RuntimeError.invalidArgument("agents pair needs --name") }
            return .agentsPair(name: name, publisher: o["--publisher"], grant: try grant(o), profile: o["--profile"],
                               timeout: try o["--wait-timeout"].map { try duration($0, "--wait-timeout") } ?? 600)
        },
        Spec(words: ["windows", "request"],
             summary: "ask the user for one window (observe, act, persist); confirmed in the Agent Desktop window with Touch ID",
             options: ["--desktop": true, "--app": true, "--window": true, "--allow": true, "--duration": true, "--request-id": true],
             positionals: []) { o, _ in
            let allow = (o["--allow"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !allow.isEmpty else { throw RuntimeError.invalidArgument("--allow is required (observe, act, persist)") }
            var p: [(String, JSONValue)] = [("desktopId", .string(try required(o, "--desktop"))),
                                            ("bundleId", .string(try required(o, "--app")))]
            if let w = try positive(o, "--window", required: false) { p.append(("windowId", .int(w))) }
            p.append(("permissions", .array(allow.map(JSONValue.string))))
            if let seconds = try grantSeconds(o) { p.append(("durationSeconds", .int(seconds))) }
            return try write(.windowsRequest, .obj(p), o)
        },
        Spec(words: ["windows", "list"], summary: "this client's window grants (--all: also revoked and ended ones)",
             options: ["--all": false], positionals: []) { o, _ in
            .call(RuntimeCall(method: .windowsList, params: o["--all"] != nil ? .obj([("includeEnded", .bool(true))]) : .obj([])))
        },
        Spec(words: ["windows", "revoke"], summary: "give up one window grant (confirmed in the Agent Desktop window)",
             options: ["--request-id": true], positionals: ["windowGrantId"]) { o, p in
            try write(.windowsRevoke, .obj([("windowGrantId", .string(p[0]))]), o)
        },
        Spec(words: ["mcp"], summary: "serve the Runtime as MCP tools on stdio, as the paired app of --profile (default mcp)",
             options: ["--profile": true], positionals: []) { o, _ in .mcp(profile: o["--profile"]) },
        Spec(words: ["version"], summary: "CLI version, API version and build; no connection",
             options: [:], positionals: []) { _, _ in .version },
        Spec(words: ["runtime", "start"], summary: "start the installed Runtime if needed and wait for its handshake",
             options: ["--wait-timeout": true], positionals: []) { o, _ in
            .runtimeStart(waitTimeout: try o["--wait-timeout"].map { try duration($0, "--wait-timeout") } ?? 20)
        },
        Spec(words: ["runtime", "status"], summary: "identity and state of the running Runtime (never starts it)",
             options: [:], positionals: []) { _, _ in .runtimeStatus },
        Spec(words: ["runtime", "capabilities"], summary: "implemented methods and backend capabilities (never starts it)",
             options: [:], positionals: []) { _, _ in .runtimeCapabilities },
        Spec(words: ["doctor"], summary: "read-only checks of endpoint, version and permissions",
             options: [:], positionals: []) { _, _ in .doctor },
        Spec(words: ["desktop", "list"], summary: "Desktops this Runtime manages",
             options: [:], positionals: []) { _, _ in .desktopList },
        Spec(words: ["desktop", "show"], summary: "one Desktop by ID",
             options: [:], positionals: ["desktopId"]) { _, p in .desktopShow(id: p[0]) },
        Spec(words: ["app", "list"], summary: "running apps with their process identity",
             options: ["--all": false], positionals: []) { o, _ in .appList(includeBackground: o["--all"] != nil) },
        Spec(words: ["window", "list"], summary: "on-screen normal windows, front to back (--all: also off-screen)",
             options: ["--pid": true, "--bundle-id": true, "--all": false], positionals: []) { o, _ in
            if o["--pid"] != nil, o["--bundle-id"] != nil {
                throw RuntimeError.invalidArgument("--pid and --bundle-id name the target twice; give one")
            }
            var pid: Int32?
            if let s = o["--pid"] {
                guard let v = Int32(s), v > 0 else { throw RuntimeError.invalidArgument("--pid needs a positive integer, got \(s)") }
                pid = v
            }
            return .windowList(pid: pid, bundleId: o["--bundle-id"], includeOffscreen: o["--all"] != nil)
        },
        Spec(words: ["desktop", "create"],
             summary: "create a Desktop: its own virtual screen, or with --physical one of your displays (nothing created; windows stay put)",
             options: ["--name": true, "--size": true, "--physical": false, "--display": true, "--request-id": true], positionals: []) { o, _ in
            var p: [(String, JSONValue)] = []
            if let n = o["--name"] { p.append(("name", .string(n))) }
            if o["--physical"] != nil || o["--display"] != nil {
                guard o["--size"] == nil else { throw RuntimeError.invalidArgument("--physical takes the display's size; leave out --size") }
                var physical: [(String, JSONValue)] = []
                if let s = o["--display"] {
                    guard let id = Int(s), UInt32(exactly: id) != nil else { throw RuntimeError.invalidArgument("--display needs a display ID, got \(s)") }
                    physical.append(("displayId", .int(id)))
                }
                p.append(("physical", .obj(physical)))
                return try write(.desktopCreate, .obj(p), o)
            }
            if let size = o["--size"] {
                let parts = size.lowercased().split(separator: "x")
                guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else {
                    throw RuntimeError.invalidArgument("--size is WIDTHxHEIGHT in points, got \(size)")
                }
                p += [("width", .int(w)), ("height", .int(h))]
            }
            return try write(.desktopCreate, .obj(p), o)
        },
        Spec(words: ["desktop", "destroy"], summary: "destroy a Desktop that has no open session",
             options: ["--request-id": true], positionals: ["desktopId"]) { o, p in
            try write(.desktopDestroy, .obj([("desktopId", .string(p[0]))]), o)
        },
        Spec(words: ["app", "launch"], summary: "launch an app onto a Desktop",
             options: ["--desktop": true, "--bundle-id": true, "--path": true, "--new-instance": false, "--request-id": true],
             positionals: []) { o, _ in
            let d = try required(o, "--desktop")
            guard (o["--bundle-id"] == nil) != (o["--path"] == nil) else {
                throw RuntimeError.invalidArgument("give exactly one of --bundle-id and --path")
            }
            var p: [(String, JSONValue)] = [("desktopId", .string(d))]
            if let b = o["--bundle-id"] { p.append(("bundleId", .string(b))) }
            if let path = o["--path"] { p.append(("path", .string(path))) }
            if o["--new-instance"] != nil { p.append(("newInstance", .bool(true))) }
            return try write(.appLaunch, .obj(p), o)
        },
        Spec(words: ["window", "bind"], summary: "move a window onto a Desktop and make it the target",
             options: ["--desktop": true, "--pid": true, "--window": true, "--request-id": true], positionals: []) { o, _ in
            var p: [(String, JSONValue)] = [("desktopId", .string(try required(o, "--desktop"))),
                                            ("pid", .int(try positive(o, "--pid", required: true)!))]
            if let w = try positive(o, "--window", required: false) { p.append(("windowId", .int(w))) }
            return try write(.windowBind, .obj(p), o)
        },
        Spec(words: ["window", "unbind"], summary: "clear a Desktop's target window",
             options: ["--desktop": true, "--request-id": true], positionals: []) { o, _ in
            try write(.windowUnbind, .obj([("desktopId", .string(try required(o, "--desktop")))]), o)
        },
        Spec(words: ["session", "open"], summary: "open a calling context on a Desktop",
             options: ["--desktop": true, "--request-id": true], positionals: []) { o, _ in
            try write(.sessionOpen, .obj([("desktopId", .string(try required(o, "--desktop")))]), o)
        },
        Spec(words: ["session", "exec"], summary: "run a program that acts in its own Run: --desktop D | --session S -- PROGRAM ARGS…",
             options: [:], positionals: []) { _, _ in throw RuntimeError.invalidArgument("session exec needs -- before the program") },
        Spec(words: ["session", "show"], summary: "one Session",
             options: [:], positionals: ["sessionId"]) { _, p in
            .call(RuntimeCall(method: .sessionShow, params: .obj([("sessionId", .string(p[0]))])))
        },
        Spec(words: ["session", "close"], summary: "close a Session",
             options: ["--request-id": true], positionals: ["sessionId"]) { o, p in
            try write(.sessionClose, .obj([("sessionId", .string(p[0]))]), o)
        },
        Spec(words: ["observe"], summary: "screenshot and elements of a Desktop's target, as a new snapshot",
             options: ["--session": true, "--desktop": true, "--query": true, "--no-screenshot": false,
                       "--no-elements": false, "--image-output": true], positionals: []) { o, _ in
            var call = RuntimeCall(method: .observe)
            call.context = try contextTarget(o)
            call.usesContext = true
            var p: [(String, JSONValue)] = []
            if let q = o["--query"] { p.append(("query", .string(q))) }
            if o["--no-screenshot"] != nil {
                guard o["--image-output"] == nil else {
                    throw RuntimeError.invalidArgument("--image-output needs the screenshot; drop --no-screenshot")
                }
                p.append(("screenshot", .bool(false)))
            }
            if o["--no-elements"] != nil { p.append(("elements", .bool(false))) }
            call.params = .obj(p)
            call.artifactOutput = o["--image-output"]
            return .call(call)
        },
        Spec(words: ["artifact", "show"], summary: "size, type and digest of an artifact, by id",
             options: [:], positionals: ["artifactId"]) { _, p in
            .call(RuntimeCall(method: .artifactShow, params: .obj([("artifactId", .string(p[0]))])))
        },
        Spec(words: ["artifact", "get"], summary: "save an artifact (a screenshot) to a file, by id",
             options: ["--out": true], positionals: ["artifactId"]) { o, p in
            guard let out = o["--out"] else { throw RuntimeError.invalidArgument("artifact get needs --out <file>") }
            var call = RuntimeCall(method: .artifactShow, params: .obj([("artifactId", .string(p[0]))]))
            call.artifactOutput = out
            return .call(call)
        },
        Spec(words: ["request", "show"], summary: "the recorded outcome of an earlier write, by requestId",
             options: [:], positionals: ["requestId"]) { _, p in
            .call(RuntimeCall(method: .requestShow, params: .obj([("requestId", .string(p[0]))])))
        },
        Spec(words: ["act", "click"], summary: "click an element or image point of a snapshot",
             options: actOptions.merging(["--element": true, "--image-point": true, "--right": false, "--double": false]) { a, _ in a },
             positionals: []) { o, _ in
            var a: [(String, JSONValue)] = [("kind", .string("click"))]
            a.append(("target", try actTarget(o, required: true)!))
            if o["--right"] != nil { a.append(("button", .string("right"))) }
            if o["--double"] != nil { a.append(("count", .int(2))) }
            return try act(o, a)
        },
        Spec(words: ["act", "type"], summary: "type text into an element or the focused field",
             options: actOptions.merging(["--element": true, "--text": true, "--text-file": true]) { a, _ in a },
             positionals: []) { o, _ in
            guard (o["--text"] == nil) != (o["--text-file"] == nil) else {
                throw RuntimeError.invalidArgument("give exactly one of --text and --text-file")
            }
            var a: [(String, JSONValue)] = [("kind", .string("type"))]
            if let t = try actTarget(o, required: false) { a.append(("target", t)) }
            if let t = o["--text"] { a.append(("text", .string(t))) } else { a.append(("text", .string("\u{0}"))) }
            var cmd = try act(o, a)
            if case var .call(c) = cmd, let f = o["--text-file"] { c.textFile = f; cmd = .call(c) }
            return cmd
        },
        Spec(words: ["act", "key"], summary: "press a key, with modifiers",
             options: actOptions.merging(["--key": true, "--modifiers": true]) { a, _ in a }, positionals: []) { o, _ in
            var a: [(String, JSONValue)] = [("kind", .string("key")), ("key", .string(try required(o, "--key")))]
            if let m = o["--modifiers"] {
                a.append(("modifiers", .array(m.split(separator: ",").map { .string(String($0)) })))
            }
            return try act(o, a)
        },
        Spec(words: ["act", "scroll"], summary: "scroll at an element or image point",
             options: actOptions.merging(["--element": true, "--image-point": true, "--direction": true, "--amount": true]) { a, _ in a },
             positionals: []) { o, _ in
            var a: [(String, JSONValue)] = [("kind", .string("scroll")), ("direction", .string(try required(o, "--direction")))]
            if let t = try actTarget(o, required: false) { a.append(("target", t)) }
            if let n = try positive(o, "--amount", required: false) { a.append(("amount", .int(n))) }
            return try act(o, a)
        },
        Spec(words: ["wait"], summary: "wait on the Runtime for an element to appear or go away",
             options: ["--session": true, "--desktop": true, "--element-present": false, "--element-absent": false,
                       "--role": true, "--label": true, "--label-contains": true, "--wait-timeout": true], positionals: []) { o, _ in
            guard (o["--element-present"] == nil) != (o["--element-absent"] == nil) else {
                throw RuntimeError.invalidArgument("give exactly one of --element-present and --element-absent")
            }
            var cond: [(String, JSONValue)] = [("kind", .string(o["--element-present"] != nil ? "elementPresent" : "elementAbsent"))]
            if let r = o["--role"] { cond.append(("role", .string(r))) }
            if let l = o["--label"] { cond.append(("label", .string(l))) }
            if let l = o["--label-contains"] { cond.append(("labelContains", .string(l))) }
            let t = try o["--wait-timeout"].map { try duration($0, "--wait-timeout") } ?? 10
            guard t >= 0.1, t <= 60 else { throw RuntimeError.invalidArgument("--wait-timeout for wait is 100ms to 60s") }
            var call = RuntimeCall(method: .wait, params: .obj([("condition", .obj(cond)), ("timeoutMs", .int(Int(t * 1000)))]))
            call.context = try contextTarget(o)
            call.usesContext = true
            return .call(call)
        },
        Spec(words: ["run", "show"], summary: "one Run: state, quiescence and receipts",
             options: [:], positionals: ["runId"]) { _, p in
            .call(RuntimeCall(method: .runShow, params: .obj([("runId", .string(p[0]))])))
        },
        Spec(words: ["run", "events"], summary: "a Run's events after a cursor (--follow: until it ends)",
             options: ["--after": true, "--follow": false], positionals: ["runId"]) { o, p in
            let after = try o["--after"].map { s -> Int in
                guard let v = Int(s), v >= 0 else { throw RuntimeError.invalidArgument("--after needs a sequence number ≥ 0") }
                return v
            } ?? 0
            return .runEvents(runId: p[0], after: after, follow: o["--follow"] != nil)
        },
        Spec(words: ["events", "watch"], summary: "stream Run events as they happen (--run: one Run, until it ends); Ctrl-C stops only the watch",
             options: ["--run": true, "--after": true], positionals: []) { o, _ in
            let after = try o["--after"].map { s -> Int in
                guard let v = Int(s), v >= 0 else { throw RuntimeError.invalidArgument("--after needs a cursor (0 or more)") }
                return v
            }
            return .eventsWatch(runId: o["--run"], after: after)
        },
        Spec(words: ["run", "wait"], summary: "observe a Run until it ends and is quiescent; Ctrl-C stops only the wait",
             options: ["--wait-timeout": true], positionals: ["runId"]) { o, p in
            .runWait(runId: p[0], timeout: try o["--wait-timeout"].map { try duration($0, "--wait-timeout") } ?? 30)
        },
        Spec(words: ["run", "list"], summary: "Delegated and Durable Runs, newest first",
             options: ["--origin": true, "--phase": true, "--desktop": true, "--active": false, "--cursor": true, "--limit": true],
             positionals: []) { o, _ in
            var p: [(String, JSONValue)] = []
            if let v = o["--origin"] { p.append(("origin", .string(v))) }
            if let v = o["--phase"] { p.append(("phase", .string(v))) }
            if let v = o["--desktop"] { p.append(("desktopId", .string(v))) }
            if o["--active"] != nil { p.append(("active", .bool(true))) }
            if let v = o["--cursor"] { p.append(("cursor", .string(v))) }
            if let n = try positive(o, "--limit", required: false) { p.append(("limit", .int(min(n, 200)))) }
            return .call(RuntimeCall(method: .runList, params: .obj(p)))
        },
        Spec(words: ["runtime", "stop-all"], summary: "stop input for every Run, Delegated and Durable (owner)",
             options: ["--request-id": true], positionals: []) { o, _ in
            try write(.stopAll, .obj([("scope", .string("all_platform_runs"))]), o)
        },
        Spec(words: ["runtime", "enable-input"], summary: "allow new Runs again after stop-all; old Runs are not resumed",
             options: ["--request-id": true], positionals: []) { o, _ in
            try write(.enableInput, .obj([]), o)
        },
        Spec(words: ["run", "cancel"], summary: "cancel a Run (--wait: until no further input is possible)",
             options: ["--request-id": true, "--wait": false, "--wait-timeout": true], positionals: ["runId"]) { o, p in
            if let id = o["--request-id"], !RuntimeContract.shared.validate(.string(id), "Id").isEmpty {
                throw RuntimeError.invalidArgument("--request-id must be 1-128 of A-Z a-z 0-9 . _ : - and start with a letter or digit")
            }
            if o["--wait-timeout"] != nil, o["--wait"] == nil { throw RuntimeError.invalidArgument("--wait-timeout needs --wait") }
            return .runCancel(runId: p[0], requestId: o["--request-id"], wait: o["--wait"] != nil,
                              timeout: try o["--wait-timeout"].map { try duration($0, "--wait-timeout") } ?? 30)
        },
    ]

    static func parse(_ args: [String]) throws -> RuntimeInvocation {
        // session exec: options before `--`, the child's argv after it, untouched.
        if args.count >= 2, args[0] == "session", args[1] == "exec" {
            guard let sep = args.firstIndex(of: "--") else {
                if args.contains("--help") || args.contains("-h") { return RuntimeInvocation(command: .help(topic: ["session"])) }
                throw RuntimeError.invalidArgument("session exec needs -- before the program to run")
            }
            let argv = Array(args[(sep + 1)...])
            guard !argv.isEmpty else { throw RuntimeError.invalidArgument("session exec needs a program after --") }
            var inv = RuntimeInvocation(command: .help(topic: []))
            var desktop: String?, session: String?
            var i = 2
            while i < sep {
                let a = args[i]
                func value() throws -> String {
                    guard i + 1 < sep else { throw RuntimeError.invalidArgument("\(a) needs a value") }
                    i += 1
                    return args[i]
                }
                switch a {
                case "--desktop": guard desktop == nil else { throw RuntimeError.invalidArgument("--desktop is given twice") }; desktop = try value()
                case "--session": guard session == nil else { throw RuntimeError.invalidArgument("--session is given twice") }; session = try value()
                case "--endpoint": guard inv.endpoint == nil else { throw RuntimeError.invalidArgument("--endpoint is given twice") }; inv.endpoint = try value()
                case "--format":
                    let f = try value()
                    guard let fmt = OutputFormat(rawValue: f), fmt != .jsonl else { throw RuntimeError.invalidArgument("--format is text or json") }
                    inv.format = fmt
                default: throw RuntimeError.invalidArgument("unknown option \(a) for session exec")
                }
                i += 1
            }
            guard (desktop == nil) != (session == nil) else {
                throw RuntimeError.invalidArgument("give exactly one of --desktop and --session")
            }
            inv.command = .sessionExec(desktopId: desktop, sessionId: session, argv: argv)
            return inv
        }
        var words: [String] = []
        var options: [String: String] = [:]
        var help = false
        var i = 0
        // Command words come first; options may follow in any order.
        while i < args.count, !args[i].hasPrefix("-") {
            words.append(args[i])
            i += 1
        }
        if words.first == "help" { return RuntimeInvocation(command: .help(topic: Array(words.dropFirst()))) }

        let spec = specs.first { $0.words == Array(words.prefix($0.words.count)) }
        let allowed = globalOptions.merging(spec?.options ?? [:]) { a, _ in a }
        var positionals = spec.map { Array(words.dropFirst($0.words.count)) } ?? []
        while i < args.count {
            let a = args[i]
            i += 1
            if a == "--help" || a == "-h" { help = true; continue }
            if a == "--" { throw RuntimeError.invalidArgument("-- is not used by \(words.joined(separator: " "))") }
            guard a.hasPrefix("--") else {
                if spec == nil || a.hasPrefix("-") { throw RuntimeError.invalidArgument("unexpected argument \(a)") }
                positionals.append(a)
                continue
            }
            var name = a
            var inline: String?
            if let eq = a.firstIndex(of: "=") {
                name = String(a[..<eq])
                inline = String(a[a.index(after: eq)...])
            }
            guard let takesValue = allowed[name] else {
                throw RuntimeError.invalidArgument("unknown option \(name)\(spec.map { " for \($0.words.joined(separator: " "))" } ?? "")")
            }
            guard options[name] == nil else { throw RuntimeError.invalidArgument("\(name) is given twice") }
            if takesValue {
                if let inline {
                    options[name] = inline
                } else {
                    guard i < args.count, !args[i].hasPrefix("--") else {
                        throw RuntimeError.invalidArgument("\(name) needs a value")
                    }
                    options[name] = args[i]
                    i += 1
                }
            } else {
                guard inline == nil else { throw RuntimeError.invalidArgument("\(name) takes no value") }
                options[name] = ""
            }
        }
        if help || words.isEmpty { return RuntimeInvocation(command: .help(topic: words)) }
        guard let spec else {
            let subs = specs.filter { Array($0.words.prefix(words.count)) == words }.compactMap { $0.words.dropFirst(words.count).first }
            if !subs.isEmpty {
                throw RuntimeError.invalidArgument("\(words.joined(separator: " ")) needs a subcommand: \(subs.joined(separator: ", "))")
            }
            throw RuntimeError.invalidArgument("unknown command \(words.joined(separator: " ")); see agentdesktop help")
        }
        guard positionals.count == spec.positionals.count else {
            let want = spec.positionals.map { "<\($0)>" }.joined(separator: " ")
            throw RuntimeError.invalidArgument("\(spec.words.joined(separator: " ")) takes \(want.isEmpty ? "no arguments" : want)"
                + (positionals.count > spec.positionals.count ? "; unexpected \(positionals[spec.positionals.count])" : ""))
        }
        var invocation = RuntimeInvocation(command: try spec.build(options, positionals))
        if let f = options["--format"] {
            guard let format = OutputFormat(rawValue: f) else {
                throw RuntimeError.invalidArgument("--format is text, json or jsonl, not \(f)")
            }
            // Only event streams print JSONL.
            guard format != .jsonl || spec.words == ["run", "events"] || spec.words == ["events", "watch"] else {
                throw RuntimeError.invalidArgument("--format jsonl is only for event and log streams; use json")
            }
            invocation.format = format
        }
        if let e = options["--endpoint"] {
            guard !e.isEmpty else { throw RuntimeError.invalidArgument("--endpoint needs a path") }
            invocation.endpoint = e
        }
        return invocation
    }

    static func write(_ m: RuntimeMethod, _ params: JSONValue, _ o: [String: String]) throws -> RuntimeInvocation.Command {
        var call = RuntimeCall(method: m, params: params, mutation: true)
        if let id = o["--request-id"] {
            guard RuntimeContract.shared.validate(.string(id), "Id").isEmpty else {
                throw RuntimeError.invalidArgument("--request-id must be 1-128 of A-Z a-z 0-9 . _ : - and start with a letter or digit")
            }
            call.requestId = id
        }
        return .call(call)
    }

    static func required(_ o: [String: String], _ name: String) throws -> String {
        guard let v = o[name] else { throw RuntimeError.invalidArgument("\(name) is required") }
        return v
    }

    static let grantOptions: [String: Bool] = ["--capabilities": true, "--desktops": true, "--apps": true, "--duration": true]

    /// --capabilities a,b --desktops d1,created --apps com.x --duration 1h|8h|7d
    static func grant(_ o: [String: String]) throws -> JSONValue {
        func list(_ k: String) -> [JSONValue] {
            (o[k] ?? "").split(separator: ",").map { .string($0.trimmingCharacters(in: .whitespaces)) }.filter { $0 != .string("") }
        }
        guard o["--capabilities"] != nil else { throw RuntimeError.invalidArgument("--capabilities is required (observe, act, desktop.manage, run, unit.run)") }
        var m: [(String, JSONValue)] = [("capabilities", .array(list("--capabilities"))), ("desktops", .array(list("--desktops"))),
                                        ("apps", .array(list("--apps")))]
        if let seconds = try grantSeconds(o) { m.append(("durationSeconds", .int(seconds))) }
        return .obj(m)
    }

    /// --duration 1h|8h|7d|30m as seconds, if given.
    static func grantSeconds(_ o: [String: String]) throws -> Int? {
        guard let d = o["--duration"] else { return nil }
        let units: [(String, Double)] = [("d", 86400), ("h", 3600), ("m", 60), ("s", 1)]
        guard let (suffix, scale) = units.first(where: { d.hasSuffix($0.0) }), let v = Double(d.dropLast(suffix.count)), v > 0 else {
            throw RuntimeError.invalidArgument("--duration needs 1h, 8h, 7d or the like, got \(d)")
        }
        return Int(v * scale)
    }

    static func positive(_ o: [String: String], _ name: String, required: Bool) throws -> Int? {
        guard let s = o[name] else {
            if required { throw RuntimeError.invalidArgument("\(name) is required") }
            return nil
        }
        guard let v = Int(s), v > 0, v <= Int(UInt32.max) else {
            throw RuntimeError.invalidArgument("\(name) needs a positive integer, got \(s)")
        }
        return v
    }

    static let actOptions: [String: Bool] = ["--session": true, "--snapshot": true, "--request-id": true]

    static func act(_ o: [String: String], _ action: [(String, JSONValue)]) throws -> RuntimeInvocation.Command {
        guard case var .call(call) = try write(.act, .obj([("snapshotId", .string(try required(o, "--snapshot"))),
                                                          ("action", .obj(action))]), o) else { fatalError() }
        call.context = o["--session"].map { RequestContext(sessionId: $0) } ?? RequestContext()
        call.usesContext = true
        return .call(call)
    }

    /// --element or --image-point X,Y (pixels of the snapshot's image).
    static func actTarget(_ o: [String: String], required: Bool) throws -> JSONValue? {
        switch (o["--element"], o["--image-point"]) {
        case let (e?, nil): return .obj([("elementRef", .string(e))])
        case let (nil, p?):
            let parts = p.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 2, let x = parts[0], let y = parts[1], x >= 0, y >= 0 else {
                throw RuntimeError.invalidArgument("--image-point is X,Y in image pixels, got \(p)")
            }
            return .obj([("imagePoint", .obj([("x", .double(x)), ("y", .double(y))]))])
        case (.some, .some): throw RuntimeError.invalidArgument("--element and --image-point are exclusive")
        case (nil, nil):
            if required { throw RuntimeError.invalidArgument("give the target with --element or --image-point") }
            return nil
        }
    }

    /// Like `target`, but both may be absent: then AGENTDESKTOP_CONTEXT
    /// must supply the session.
    static func contextTarget(_ o: [String: String]) throws -> RequestContext {
        if o["--session"] == nil, o["--desktop"] == nil { return RequestContext() }
        return try target(o)
    }

    /// --session or --desktop, not both.
    static func target(_ o: [String: String]) throws -> RequestContext {
        switch (o["--session"], o["--desktop"]) {
        case let (s?, nil): return RequestContext(sessionId: s)
        case let (nil, d?): return RequestContext(desktopId: d)
        case (.some, .some): throw RuntimeError.invalidArgument("--session and --desktop name the target twice; give one")
        case (nil, nil): throw RuntimeError.invalidArgument("give the target with --session or --desktop")
        }
    }

    /// The format asked for, read leniently so a refused command line can
    /// still answer in JSON when the caller wanted JSON.
    static func requestedFormat(_ args: [String]) -> OutputFormat {
        for (i, a) in args.enumerated() {
            if a == "--format=json" || (a == "--format" && i + 1 < args.count && args[i + 1] == "json") { return .json }
        }
        return .text
    }

    /// "30s", "500ms", "2m" or plain seconds.
    static func duration(_ s: String, _ option: String) throws -> Double {
        let units: [(String, Double)] = [("ms", 0.001), ("s", 1), ("m", 60)]
        for (suffix, scale) in units where s.hasSuffix(suffix) {
            if let v = Double(s.dropLast(suffix.count)), v >= 0, v.isFinite { return v * scale }
        }
        if let v = Double(s), v >= 0, v.isFinite { return v }
        throw RuntimeError.invalidArgument("\(option) needs a duration like 30s, 500ms or 2m, got \(s)")
    }

    static func usage(topic: [String]) -> String {
        let matching = specs.filter { topic.isEmpty || Array($0.words.prefix(topic.count)) == topic }
        let shown = matching.isEmpty ? specs : matching
        var lines = ["usage: agentdesktop <command> [options] [--format text|json] [--endpoint PATH]", "", "commands:"]
        for s in shown {
            var left = s.words.joined(separator: " ")
            for p in s.positionals { left += " <\(p)>" }
            for (o, v) in s.options.sorted(by: { $0.key < $1.key }) { left += v ? " [\(o) V]" : " [\(o)]" }
            lines.append("  " + left.padding(toLength: max(left.count, 44), withPad: " ", startingAt: 0) + "  " + s.summary)
        }
        lines += [
            "",
            "--format json prints one JSON object on stdout; diagnostics go to stderr.",
            "AI/GUI service methods (runtime/1): agentdesktop rpc|ai|gui …; see agentdesktop ai --help.",
            "--endpoint (or AGENTDESKTOP_ENDPOINT) selects a Runtime other than the installed product's.",
            "Exit codes: 0 done, 2 arguments, 3 Runtime offline, 4 permission, 5 conflict,",
            "6 version/capability, 7 known failure, 8 wait timeout, 9 result unknown.",
        ]
        return lines.joined(separator: "\n")
    }
}
