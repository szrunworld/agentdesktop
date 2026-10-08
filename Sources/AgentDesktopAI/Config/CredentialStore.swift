import Foundation
import Security

/// Holds API keys outside the configuration database. Only `credentialId`
/// (a random reference) ever appears in SQLite, responses or logs.
public protocol CredentialStore: Sendable {
    func write(credentialId: String, secret: String) throws
    /// Nil when no secret is stored under this id.
    func read(credentialId: String) throws -> String?
    /// Idempotent: deleting a missing id succeeds.
    func delete(credentialId: String) throws
}

public struct CredentialStoreError: Error, Equatable, Sendable {
    public let operation: String
    public let status: Int32
}

/// macOS Keychain, generic password items, never synchronized to iCloud.
public struct KeychainCredentialStore: CredentialStore {
    public static let servicePrefix = "com.agentdesktop.ai"
    public let service: String

    public init(service: String = KeychainCredentialStore.servicePrefix + ".credentials") {
        precondition(service.hasPrefix(Self.servicePrefix))
        self.service = service
    }

    private func query(_ id: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    public func write(credentialId: String, secret: String) throws {
        var add = query(credentialId)
        add[kSecValueData as String] = Data(secret.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(query(credentialId) as CFDictionary,
                                   [kSecValueData as String: Data(secret.utf8)] as CFDictionary)
        }
        guard status == errSecSuccess else { throw CredentialStoreError(operation: "write", status: status) }
    }

    public func read(credentialId: String) throws -> String? {
        var q = query(credentialId)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else {
            throw CredentialStoreError(operation: "read", status: status)
        }
        return String(decoding: data, as: UTF8.self)
    }

    public func delete(credentialId: String) throws {
        let status = SecItemDelete(query(credentialId) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError(operation: "delete", status: status)
        }
    }
}

/// In-process store for tests, with injectable failures.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    public enum Op: Sendable { case write, read, delete }
    private let lock = NSLock()
    private var items: [String: String] = [:]
    private var failing: Set<String> = []

    public init() {}

    public func fail(_ op: Op, _ on: Bool = true) {
        lock.lock(); defer { lock.unlock() }
        let k = "\(op)"
        if on { failing.insert(k) } else { failing.remove(k) }
    }

    private func check(_ op: Op) throws {
        if failing.contains("\(op)") { throw CredentialStoreError(operation: "\(op)", status: -1) }
    }

    public func write(credentialId: String, secret: String) throws {
        lock.lock(); defer { lock.unlock() }
        try check(.write)
        items[credentialId] = secret
    }

    public func read(credentialId: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        try check(.read)
        return items[credentialId]
    }

    public func delete(credentialId: String) throws {
        lock.lock(); defer { lock.unlock() }
        try check(.delete)
        items[credentialId] = nil
    }

    public var storedIds: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(items.keys)
    }

    /// Remove an item behind the service's back (lost/locked keychain item).
    public func drop(_ credentialId: String) {
        lock.lock(); defer { lock.unlock() }
        items[credentialId] = nil
    }
}
