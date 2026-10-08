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
                       artifacts: try ArtifactStore(directory: records + "/artifacts"))
    }
}
