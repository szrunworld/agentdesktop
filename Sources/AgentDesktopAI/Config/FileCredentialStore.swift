import Foundation

/// Secrets as files in one private directory: for test copies of the host,
/// never for the product. A test copy must not share the login Keychain
/// with the product (it would read and overwrite the product's items) and
/// cannot run unattended against Keychain items whose ACL names an earlier,
/// differently signed build. The directory is created 0700, each file 0600
/// and written atomically; ids are restricted to the contract's id
/// alphabet so a name can never leave the directory.
public struct FileCredentialStore: CredentialStore {
    public let directory: URL

    public init(directory: String) throws {
        self.directory = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard chmod(self.directory.path, 0o700) == 0 else {
            throw CredentialStoreError(operation: "chmod", status: errno)
        }
    }

    private func file(_ id: String) throws -> URL {
        let ok = !id.isEmpty && id.count <= 128 && id.first != "." &&
            id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._:-".unicodeScalars.contains($0) }
        guard ok else { throw CredentialStoreError(operation: "id", status: EINVAL) }
        return directory.appendingPathComponent(id)
    }

    public func write(credentialId: String, secret: String) throws {
        let target = try file(credentialId)
        let temp = directory.appendingPathComponent(".tmp-\(UUID().uuidString)")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw CredentialStoreError(operation: "write", status: errno) }
        let data = Data(secret.utf8)
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) }
        let synced = fsync(fd)
        close(fd)
        guard written == data.count, synced == 0, rename(temp.path, target.path) == 0 else {
            let e = errno
            unlink(temp.path)
            throw CredentialStoreError(operation: "write", status: e)
        }
    }

    public func read(credentialId: String) throws -> String? {
        let target = try file(credentialId)
        guard let data = FileManager.default.contents(atPath: target.path) else {
            if FileManager.default.fileExists(atPath: target.path) {
                throw CredentialStoreError(operation: "read", status: EACCES)
            }
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    public func delete(credentialId: String) throws {
        let target = try file(credentialId)
        if unlink(target.path) != 0 && errno != ENOENT {
            throw CredentialStoreError(operation: "delete", status: errno)
        }
    }
}
