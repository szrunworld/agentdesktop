import AgentDesktopContracts
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
    /// observe --image-output: copy the screenshot here.
    var imageOutput: String?
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
        Spec(words: ["desktop", "create"], summary: "create a Desktop (its own virtual screen)",
             options: ["--name": true, "--size": true, "--request-id": true], positionals: []) { o, _ in
            var p: [(String, JSONValue)] = []
            if let n = o["--name"] { p.append(("name", .string(n))) }
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
            call.context = try target(o)
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
            call.imageOutput = o["--image-output"]
            return .call(call)
        },
        Spec(words: ["request", "show"], summary: "the recorded outcome of an earlier write, by requestId",
             options: [:], positionals: ["requestId"]) { _, p in
            .call(RuntimeCall(method: .requestShow, params: .obj([("requestId", .string(p[0]))])))
        },
    ]

    static func parse(_ args: [String]) throws -> RuntimeInvocation {
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
            // No command of this build streams events or logs.
            guard format != .jsonl else {
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
            "AI/GUI (contract agentdesktop.ai/1): agentdesktop rpc|ai|gui …; see agentdesktop ai --help.",
            "--endpoint (or AGENTDESKTOP_ENDPOINT) selects a Runtime other than the installed product's.",
            "Exit codes: 0 done, 2 arguments, 3 Runtime offline, 4 permission, 5 conflict,",
            "6 version/capability, 7 known failure, 8 wait timeout, 9 result unknown.",
        ]
        return lines.joined(separator: "\n")
    }
}
