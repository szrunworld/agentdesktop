import AgentDesktopProtocol
import Foundation
import Security

/// What the Runtime itself learned about the program at the other end of a
/// socket (A4 S2), from the kernel's audit token of that socket: never from
/// anything the client sends.
public struct CodeIdentity: Sendable, Equatable {
    public enum Level: String, Sendable {
        /// Team-signed, hardened runtime, valid: bound by its requirement.
        case verified
        /// As verified, but other code can run as it: an interpreter (python,
        /// node, …), an Electron app, or code signed to allow injection.
        /// Still bound to its requirement; every script it runs shares it.
        case sharedInterpreter = "shared_interpreter"
        /// Nothing verifiable (ad-hoc, self-signed, no hardened runtime):
        /// only "a process of this user".
        case sameUser = "same_user"
        /// Inside the host process (the window, the GUI ports).
        case inProcess = "in_process"
    }

    public var level: Level
    public var identifier: String?
    public var teamId: String?
    public var hardenedRuntime = false
    /// The designated requirement a later connection must satisfy; set only
    /// for verified and shared-interpreter code.
    public var requirement: String?

    public init(level: Level, identifier: String? = nil, teamId: String? = nil, hardenedRuntime: Bool = false,
                requirement: String? = nil) {
        self.level = level
        self.identifier = identifier
        self.teamId = teamId
        self.hardenedRuntime = hardenedRuntime
        self.requirement = requirement
    }

    public static let inProcess = CodeIdentity(level: .inProcess)
    public static let unknown = CodeIdentity(level: .sameUser)

    public var json: JSONValue {
        var m: [(String, JSONValue)] = [("level", .string(level.rawValue))]
        if let identifier { m.append(("identifier", .string(identifier))) }
        if let teamId { m.append(("teamId", .string(teamId))) }
        m.append(("hardenedRuntime", .bool(hardenedRuntime)))
        if let requirement { m.append(("requirement", .string(requirement))) }
        return .obj(m)
    }

    public init(json: JSONValue?) {
        level = json?["level"]?.stringValue.flatMap(Level.init(rawValue:)) ?? .sameUser
        identifier = json?["identifier"]?.stringValue
        teamId = json?["teamId"]?.stringValue
        hardenedRuntime = json?["hardenedRuntime"]?.boolValue ?? false
        requirement = json?["requirement"]?.stringValue
    }
}

/// Reads and checks code identities. Tests replace it; the product uses
/// SecurityCodeIdentityVerifier.
public protocol CodeIdentityVerifier: Sendable {
    func identify(auditToken: Data, executable: String?) -> CodeIdentity
    /// Whether the process behind `auditToken` satisfies `requirement` now.
    func satisfies(auditToken: Data, requirement: String) -> Bool
}

/// The kernel's audit token of a connected unix socket's peer.
public func peerAuditToken(_ fd: Int32) -> Data? {
    var token = audit_token_t()
    var len = socklen_t(MemoryLayout<audit_token_t>.size)
    guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &len) == 0 else { return nil }
    return withUnsafeBytes(of: &token) { Data($0) }
}

public struct SecurityCodeIdentityVerifier: CodeIdentityVerifier {
    static let interpreters = ["python", "node", "ruby", "perl", "bash", "zsh", "sh", "osascript", "java", "deno", "bun", "php", "lua", "tclsh"]

    public init() {}

    private func guest(_ token: Data) -> SecCode? {
        var code: SecCode?
        let attrs = [kSecGuestAttributeAudit: token] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess else { return nil }
        return code
    }

    public func identify(auditToken: Data, executable: String?) -> CodeIdentity {
        guard let code = guest(auditToken), SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return .unknown }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return .unknown }
        var info: CFDictionary?
        SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation), &info)
        let d = (info as? [String: Any]) ?? [:]
        let identifier = d[kSecCodeInfoIdentifier as String] as? String
        let team = d[kSecCodeInfoTeamIdentifier as String] as? String
        let flags = (d[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let hardened = flags & 0x10000 != 0          // kSecCodeSignatureRuntime
        let adhoc = flags & 0x2 != 0                  // kSecCodeSignatureAdhoc
        var id = CodeIdentity(level: .sameUser, identifier: identifier, teamId: team, hardenedRuntime: hardened)
        guard let team, !team.isEmpty, hardened, !adhoc else { return id }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement else { return id }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return id }
        id.requirement = text as String
        id.level = Self.runsOthersCode(identifier: identifier, executable: executable, entitlements: d[kSecCodeInfoEntitlementsDict as String] as? [String: Any])
            ? .sharedInterpreter : .verified
        return id
    }

    /// Entitlements that let other code run inside a signed program.
    static let injectable = ["com.apple.security.cs.allow-dyld-environment-variables", "com.apple.security.cs.disable-library-validation",
                             "com.apple.security.get-task-allow"]

    /// Whether code other than the signer's can run under this identity (A4
    /// review M4): an interpreter (by file name or signing identifier, which
    /// survives renaming), an Electron app (ELECTRON_RUN_AS_NODE), or code
    /// signed with entitlements that allow injection.
    static func runsOthersCode(identifier: String?, executable: String?, entitlements: [String: Any]?) -> Bool {
        let name = ((executable ?? "") as NSString).lastPathComponent.lowercased()
        let ident = (identifier ?? "").lowercased()
        if interpreters.contains(where: { name == $0 || name.hasPrefix($0 + "3") || name.hasPrefix($0 + "-") || name.hasPrefix($0 + ".")
            || ident == $0 || ident.hasSuffix("." + $0) || ident.contains("." + $0 + ".") || ident.hasPrefix($0 + "-") }) {
            return true
        }
        if let executable, let range = executable.range(of: ".app/Contents/MacOS/") {
            let bundle = String(executable[..<range.lowerBound]) + ".app"
            if FileManager.default.fileExists(atPath: bundle + "/Contents/Frameworks/Electron Framework.framework") { return true }
        }
        if let entitlements, injectable.contains(where: { entitlements[$0] as? Bool == true }) { return true }
        return false
    }

    public func satisfies(auditToken: Data, requirement: String) -> Bool {
        var req: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, let req,
              let code = guest(auditToken) else { return false }
        return SecCodeCheckValidity(code, [], req) == errSecSuccess
    }
}
