import Foundation

/// Decides whether the dev entry may connect to a Runtime socket.
///
/// Every path inside the installed product's directory
/// (`~/Library/Application Support/AgentDesktop/`) counts as the product:
/// control.sock (the one endpoint after A2, docs/acp/04 C-19), runtime.sock,
/// ai.sock and anything else under it. Paths are compared after expanding
/// `~`, making them absolute, removing `.`/`..` and resolving symlinks
/// (of the path itself or of its deepest existing ancestor), and without
/// regard to case (the default APFS volume is case-insensitive). Tests and
/// side instances use sockets elsewhere, e.g. `/tmp/adt-*`.
public struct ACPAgentServerEndpointGuard: Sendable {
    public let home: String
    public let currentDirectory: String

    public init(home: String = NSHomeDirectory(),
                currentDirectory: String = FileManager.default.currentDirectoryPath) {
        self.home = home
        self.currentDirectory = currentDirectory
    }

    /// The product directory, unresolved.
    public var productDirectory: String { home + "/Library/Application Support/AgentDesktop" }

    /// True when `path` is, or lies inside, the product directory.
    public func isProductPath(_ path: String) -> Bool {
        let candidates = Set([Self.normalized(expand(path)), Self.resolved(expand(path))])
        let products = Set([Self.normalized(productDirectory), Self.resolved(productDirectory)])
        for c in candidates {
            for p in products where Self.isSameOrInside(c, p) { return true }
        }
        return false
    }

    public enum Verdict: Equatable, Sendable {
        case allowed
        case refusedProduct(String)
    }

    public func check(_ path: String, allowProduct: Bool) -> Verdict {
        if isProductPath(path), !allowProduct { return .refusedProduct(path) }
        return .allowed
    }

    // MARK: Paths

    private func expand(_ path: String) -> String {
        var p = path
        if p == "~" {
            p = home
        } else if p.hasPrefix("~/") {
            p = home + String(p.dropFirst(1))
        }
        if !p.hasPrefix("/") { p = currentDirectory + "/" + p }
        return p
    }

    /// Absolute, `.`/`..` removed, no trailing slash. No file system access.
    static func normalized(_ path: String) -> String {
        var out: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !out.isEmpty { out.removeLast() }
            default: out.append(part)
            }
        }
        return "/" + out.joined(separator: "/")
    }

    /// Symlinks resolved the way the kernel would: realpath of the path when
    /// it exists, else of its deepest existing ancestor (taken from the raw
    /// path, so `link/..` is resolved through the link) with the rest
    /// appended and normalized. A dangling symlink on the way is followed
    /// through its target (a socket that does not exist yet still counts
    /// where its link points).
    static func resolved(_ path: String, depth: Int = 0) -> String {
        var head = path
        var tail: [String] = []
        while true {
            if let r = realPath(head) {
                return normalized(([r] + tail.reversed()).joined(separator: "/"))
            }
            if depth < 32, let target = readLink(head) {
                let parent = (head as NSString).deletingLastPathComponent
                let absolute = target.hasPrefix("/") ? target : parent + "/" + target
                return resolved(([absolute] + tail.reversed()).joined(separator: "/"), depth: depth + 1)
            }
            guard head != "/", !head.isEmpty else { return normalized(path) }
            tail.append((head as NSString).lastPathComponent)
            head = (head as NSString).deletingLastPathComponent
            if head.isEmpty { head = "/" }
        }
    }

    private static func readLink(_ path: String) -> String? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let n = readlink(path, &buf, Int(PATH_MAX))
        guard n > 0 else { return nil }
        return String(decoding: buf[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func realPath(_ path: String) -> String? {
        guard let p = realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    static func isSameOrInside(_ path: String, _ dir: String) -> Bool {
        let a = path.lowercased(), d = dir.lowercased()
        return a == d || a.hasPrefix(d.hasSuffix("/") ? d : d + "/")
    }
}
