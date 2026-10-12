import AgentDesktopProtocol
import Foundation
import Security

/// Where a client keeps the credential it was issued at pairing (A4, S3).
/// One credential per Runtime endpoint and profile (a client may pair under
/// several names, e.g. the CLI and an MCP host it serves).
public protocol CredentialStore: Sendable {
    func load(endpoint: String, profile: String) throws -> ClientCredential?
    func save(_ credential: ClientCredential, endpoint: String, profile: String) throws
    func delete(endpoint: String, profile: String) throws
}

/// In memory only: tests, and a host that must not persist anything.
public final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: ClientCredential] = [:]

    public init() {}

    public func load(endpoint: String, profile: String) throws -> ClientCredential? {
        lock.withLock { items[endpoint + "\n" + profile] }
    }

    public func save(_ credential: ClientCredential, endpoint: String, profile: String) throws {
        lock.withLock { items[endpoint + "\n" + profile] = credential }
    }

    public func delete(endpoint: String, profile: String) throws {
        _ = lock.withLock { items.removeValue(forKey: endpoint + "\n" + profile) }
    }
}

/// The macOS keychain: a generic password per endpoint and profile.
/// Team-signed clients use the Data Protection keychain and the provisioned
/// product access group. Only development clients use the legacy keychain.
/// There is no migration or fallback from release storage to legacy items.
///
/// What this protects (docs/security/a4-credential-assessment.md): the
/// item's access list trusts only the program that created it; another
/// program reading it makes macOS ask the user, it is never handed over
/// silently. It does NOT separate two scripts of one interpreter, and a
/// user who answers "Always Allow" widens it. The token never touches a
/// plain file, an environment variable or a command line.
public final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {
    public static let service = "com.agentdesktop.client-credential"
    private let keychain: SecKeychain?
    private let accessGroup: String?

    /// Select from our validated code signature, never from environment or
    /// a mutable plist. Team-signed clients must not fall back to legacy storage.
    static func releaseAccessGroup(team: String?, entitlements: [String: Any]) throws -> String? {
        guard let team, !team.isEmpty else { return nil }
        let expected = team + ".com.agentdesktop.client-credential"
        guard (entitlements["keychain-access-groups"] as? [String])?.contains(expected) == true else {
            throw RuntimeError("permission_denied", "signed client lacks its credential keychain access group", phase: .local, notSent: true)
        }
        return expected
    }

    private static func signedAccessGroup() throws -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            throw RuntimeError("permission_denied", "cannot inspect client code identity", phase: .local, notSent: true)
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            throw RuntimeError("permission_denied", "cannot inspect client static code", phase: .local, notSent: true)
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else {
            throw RuntimeError("permission_denied", "cannot read client code signature", phase: .local, notSent: true)
        }
        let fields = (info as? [String: Any]) ?? [:]
        let team = fields[kSecCodeInfoTeamIdentifier as String] as? String
        if team != nil && SecCodeCheckValidity(code, [], nil) != errSecSuccess {
            throw RuntimeError("permission_denied", "client code signature is invalid", phase: .local, notSent: true)
        }
        return try releaseAccessGroup(team: team, entitlements: fields[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:])
    }

    /// `keychainPath`: a keychain file other than the login keychain (test
    /// copies use one under their /tmp directory); nil means the default.
    public init(keychainPath: String? = nil) throws {
        accessGroup = try Self.signedAccessGroup()
        if accessGroup != nil, keychainPath != nil {
            throw RuntimeError("permission_denied", "signed clients cannot use a legacy test keychain", phase: .local, notSent: true)
        }
        if let keychainPath {
            var k: SecKeychain?
            let status = SecKeychainOpen(keychainPath, &k)
            guard status == errSecSuccess, let k else {
                throw RuntimeError("invalid_argument", "cannot open the keychain \(keychainPath) (\(status))", phase: .local, notSent: true)
            }
            keychain = k
        } else {
            keychain = nil
        }
    }

    private func query(_ endpoint: String, _ profile: String) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: Self.service,
                                kSecAttrAccount as String: endpoint + "|" + profile]
        if let accessGroup {
            q[kSecUseDataProtectionKeychain as String] = true
            q[kSecAttrAccessGroup as String] = accessGroup
            q[kSecAttrSynchronizable as String] = false
        }
        if let keychain {
            q[kSecUseKeychain as String] = keychain
            q[kSecMatchSearchList as String] = [keychain]
        }
        return q
    }

    public func load(endpoint: String, profile: String) throws -> ClientCredential? {
        var q = query(endpoint, profile)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else {
            throw RuntimeError("permission_denied", "the keychain refused the AgentDesktop credential (\(status))", phase: .local, notSent: true)
        }
        guard let v = try? StrictJSON.parse(data), let id = v["clientId"]?.stringValue, let token = v["token"]?.stringValue else {
            throw RuntimeError("invalid_argument", "the keychain item holds no credential", phase: .local, notSent: true)
        }
        return ClientCredential(clientId: id, token: token)
    }

    public func save(_ credential: ClientCredential, endpoint: String, profile: String) throws {
        try delete(endpoint: endpoint, profile: profile)
        var q = query(endpoint, profile)
        q.removeValue(forKey: kSecMatchSearchList as String)
        q[kSecValueData as String] = Data(credential.json.encoded().utf8)
        q[kSecAttrLabel as String] = "AgentDesktop credential (\(profile))"
        if accessGroup != nil { q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly }
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw RuntimeError("permission_denied", "cannot store the credential in the keychain (\(status))", phase: .local, notSent: true)
        }
    }

    public func delete(endpoint: String, profile: String) throws {
        let status = SecItemDelete(query(endpoint, profile) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw RuntimeError("permission_denied", "cannot remove the credential from the keychain (\(status))", phase: .local, notSent: true)
        }
    }
}
