import AgentDesktopProtocol
import Foundation

extension RuntimeService {
    /// The product's Runtime with every record on disk under `records`
    /// (owner-only): the request ledger, Runs and their events, and
    /// artifacts. The host builds its Runtime through this one function so
    /// no store silently falls back to memory.
    public static func persistent(identity: RuntimeIdentity, backend: RuntimeBackend, platform: DesktopPlatform?,
                                  records: String) throws -> RuntimeService {
        RuntimeService(identity: identity, backend: backend, platform: platform,
                       ledger: try RequestLedger(path: records + "/requests.sqlite"),
                       runs: try RunStore(path: records + "/runs.sqlite"),
                       artifacts: try ArtifactStore(directory: records + "/artifacts"),
                       hub: try HubStore(path: records + "/hub.sqlite"),
                       ownerCredential: try ownerCredential(in: records))
    }

    /// The owner credential in `<records>/owner.credential`: created 0600 on
    /// first start, kept across restarts. Same-user processes can read it;
    /// it separates the owner from paired apps that play by the rules, not
    /// from code running as the user (docs/security/a4-identity.md).
    static func ownerCredential(in records: String) throws -> String {
        let path = records + "/owner.credential"
        try FileManager.default.createDirectory(atPath: records, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if let data = FileManager.default.contents(atPath: path),
           let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            _ = chmod(path, 0o600)
            return token
        }
        let token = HubStore.newToken()
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RuntimeStoreError("cannot create \(path): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        let bytes = Array((token + "\n").utf8)
        guard write(fd, bytes, bytes.count) == bytes.count else { throw RuntimeStoreError("cannot write \(path)") }
        return token
    }
}
