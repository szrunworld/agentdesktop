import AgentDesktopProtocol
import Foundation

extension RuntimeService {
    /// The product's Runtime with every record on disk under `records`
    /// (owner-only): the request ledger, Runs and their events, and
    /// artifacts. The host builds its Runtime through this one function so
    /// no store silently falls back to memory.
    public static func persistent(identity: RuntimeIdentity, backend: RuntimeBackend, platform: DesktopPlatform?,
                                  records: String) throws -> RuntimeService {
        removeLegacyOwnerCredential(in: records)
        return RuntimeService(identity: identity, backend: backend, platform: platform,
                       ledger: try RequestLedger(path: records + "/requests.sqlite"),
                       runs: try RunStore(path: records + "/runs.sqlite"),
                       artifacts: try ArtifactStore(directory: records + "/artifacts"),
                       hub: try HubStore(path: records + "/hub.sqlite"))
    }

    /// A4 S1: there is no owner credential on disk. An earlier build left
    /// one in `<records>/owner.credential`; it is removed at start so it can
    /// never again stand for the owner.
    static func removeLegacyOwnerCredential(in records: String) {
        let path = records + "/owner.credential"
        var st = stat()
        guard lstat(path, &st) == 0 else { return }
        unlink(path)
    }
}
