import AgentDesktopProtocol
import Foundation

/// artifact.show / artifact.read: a client reaches what an observation
/// produced by id only, in chunks that fit one frame. Someone else's
/// artifact does not exist for it.
extension RuntimeService {
    static let maxArtifactChunk = 524_288

    func visibleArtifact(_ p: JSONValue, _ c: ConnectionState) -> Result<ArtifactStore.Info, RuntimeError> {
        let id = p["artifactId"]?.stringValue ?? ""
        guard let info = artifacts.info(id), isOwner(c) || info.clientId == c.clientId else {
            return .failure(.notFound("no artifact \(id)"))
        }
        return .success(info)
    }

    func showArtifact(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        visibleArtifact(p, c).map(\.json)
    }

    func readArtifact(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        visibleArtifact(p, c).flatMap { info in
            let offset = p["offset"]?.intValue ?? 0
            let length = min(p["length"]?.intValue ?? Self.maxArtifactChunk, Self.maxArtifactChunk)
            do {
                let chunk = try artifacts.read(info.artifactId, offset: offset, length: length)
                return .success(.obj([("artifactId", .string(info.artifactId)), ("offset", .int(offset)),
                                      ("length", .int(chunk.data.count)), ("eof", .bool(chunk.eof)),
                                      ("dataBase64", .string(chunk.data.base64EncodedString()))]))
            } catch let e as RuntimeError {
                return .failure(e)
            } catch {
                return .failure(RuntimeError("internal_error", "cannot read artifact \(info.artifactId): \(error)",
                                             phase: .handler))
            }
        }
    }
}
