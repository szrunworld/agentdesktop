import AgentDesktopProtocol
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The GUI layer's observation, execution and session ports, served by the
/// Runtime (DEV-SPEC D06: the Runtime is the only real input path).
///
/// Nothing here sends input itself. `observe` is the Runtime's own observe;
/// `execute` turns a validated proposal into a runtime/1 `act` request with
/// the actionId as its requestId and runs it through the same checks,
/// lease, ledger and executor as any other caller — so a repeated actionId
/// can never input twice, and an unknown outcome stays unknown.
public final class RuntimeGuiPorts: GuiObservationPort, GuiExecutionPort, GuiSessionAuthority, @unchecked Sendable {
    struct RunBinding {
        let desktopId: String
        let sessionId: String
        let bindingEpoch: UInt64
    }

    /// The long side of the image handed to a model.
    public static let maxModelSide = 1280.0
    public static let backendId = "2ndscreen-engine"

    let service: RuntimeService
    private let connection: ConnectionState
    private let lock = NSLock()
    private var bindings: [String: RunBinding] = [:]
    /// Per Desktop: last window frame seen and its revision.
    private var geometry: [String: (frame: AgentDesktopProtocol.Rect, revision: UInt64)] = [:]

    public init(service: RuntimeService) {
        self.service = service
        // The GUI service runs in this process, as this user.
        connection = ConnectionState(peerUID: getuid())
        _ = service.respond(to: Data(#"{"apiVersion":"agentdesktop.runtime/1","requestId":"gui-handshake","method":"runtime.handshake","params":{"apiVersions":["agentdesktop.runtime/1"],"client":{"name":"agentdesktop-gui","version":"1"}}}"#.utf8),
                            on: connection)
    }

    /// Run a runtime/1 request off the cooperative pool: the platform blocks.
    private func call(_ method: RuntimeMethod, id: String = RuntimeRequest.newId(prefix: "gui"),
                      context: RequestContext, params: JSONValue) async -> Result<JSONValue, RuntimeError> {
        var request = RuntimeRequest(method, requestId: id, params: params)
        request.context = context
        let line = request.json.encodedData()
        let service = service, connection = connection
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                cont.resume(returning: service.respond(to: line, on: connection).result)
            }
        }
    }

    // MARK: GuiSessionAuthority

    public func authorize(sessionId: String?, desktopId: String, callerScope: String, trustedOwner: Bool,
                          runId: String) async throws -> (sessionId: String, bindingEpoch: UInt64) {
        guard let d = service.desktops.find(desktopId) else { throw ContractError(.notFound, "no desktop \(desktopId)") }
        guard let b = d.lock.withLock({ d.binding }) else {
            throw ContractError(.capabilityMismatch, "desktop \(desktopId) has no bound window; bind one before a GUI run")
        }
        let session: String
        if let sessionId {
            guard let s = service.sessions.find(sessionId, caller: connection.clientId), s.state == "open", s.desktopId == desktopId else {
                throw ContractError(.forbidden, "session \(sessionId) is not an open session of desktop \(desktopId)")
            }
            session = s.sessionId
        } else {
            guard trustedOwner else { throw ContractError(.forbidden, "a GUI run needs an explicit session") }
            session = service.sessions.open(desktopId: desktopId, caller: connection.clientId, at: Timestamp.string(Date())).sessionId
        }
        let epoch = UInt64(b.generation)
        lock.withLock { bindings[runId] = RunBinding(desktopId: desktopId, sessionId: session, bindingEpoch: epoch) }
        return (session, epoch)
    }

    private func binding(_ runId: String) throws -> RunBinding {
        guard let b = lock.withLock({ bindings[runId] }) else { throw ContractError(.notFound, "no GUI run \(runId) on this Runtime") }
        return b
    }

    // MARK: GuiObservationPort

    public func observe(runId: String, expectedGeneration: UInt64) async throws -> ObservationBundle {
        let rb = try binding(runId)
        let data: JSONValue
        switch await call(.observe, context: RequestContext(sessionId: rb.sessionId), params: .obj([])) {
        case let .failure(e): throw Self.contractError(e)
        case let .success(v): data = v
        }
        guard let snapshotId = data["snapshotId"]?.stringValue, let stored = service.observations.find(snapshotId),
              let b = stored.binding, let frame = stored.windowFrame,
              let t = stored.transform, let size = stored.imageSize,
              let source = data["image"]?["artifactId"]?.stringValue.flatMap(service.artifacts.file(of:))
        else { throw ContractError(.staleObservation, "the desktop has no bound window or screenshot to observe") }

        let revision: UInt64 = lock.withLock {
            var g = geometry[rb.desktopId] ?? (frame, 1)
            if !RuntimeService.sameFrame(g.frame, frame) { g = (frame, g.revision + 1) }
            geometry[rb.desktopId] = g
            return g.revision
        }
        let target = TargetIdentity(
            appId: service.backend.applications(includeBackground: true).first { $0.process.pid == b.process.pid }?.bundleId ?? b.appName,
            processId: Int(b.process.pid), processStartId: b.process.startedAt ?? "unknown", windowId: String(b.windowId),
            windowGeometryRevision: revision, backendId: Self.backendId,
            windowFrameDesktopLogical: GuiRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height))

        // The model sees the bound window: cropped from the screenshot and,
        // when large, scaled down. The transform says so exactly.
        let crop = Self.cropRect(window: frame, origin: (t.originX, t.originY), scale: t.scale, image: size)
        let longSide = max(crop.size.width, crop.size.height)
        let factor = longSide > Self.maxModelSide ? Self.maxModelSide / longSide : 1
        let resized = Size(width: (crop.size.width * factor).rounded(), height: (crop.size.height * factor).rounded())
        let modelPNG = try Self.render(source: source, crop: crop, to: resized)
        let artifactId = "art_gui_" + snapshotId.dropFirst(4)
        try modelPNG.write(to: URL(fileURLWithPath: service.artifacts.path(for: artifactId, ext: "png")))
        // Readable by id from the owner (Runs page), not by other clients.
        let sha = try service.artifacts.register(artifactId, mediaType: "image/png", clientId: "platform", runId: runId,
                                                 createdAt: Timestamp.string(Date())).sha256
        let shot = try ScreenshotDescriptor(
            screenshotId: "shot_" + snapshotId.dropFirst(4), artifactRef: artifactId, sha256: sha, mimeType: "image/png",
            transformVersion: "runtime-window-crop-v1",
            sourceToDesktop: GuiAffineTransform.scale(1 / t.scale, 1 / t.scale).then(.translate(t.originX, t.originY)),
            transform: .pipeline(sourceSize: Size(width: Double(size.width), height: Double(size.height)), crop: crop, resizedSize: resized))
        let observation = Observation(
            observationId: snapshotId,
            stamp: ObservationStamp(sessionId: rb.sessionId, desktopId: rb.desktopId, snapshotId: snapshotId,
                                    bindingEpoch: UInt64(b.generation), runGeneration: expectedGeneration),
            target: target, observedAt: Timestamp.date(stored.capturedAt) ?? Date(), screenshots: [shot])
        let elements = stored.readElements ? stored.elements.values.sorted { $0.index < $1.index }.map {
            ObservedElement(role: Self.role($0.role), text: $0.value ?? $0.label ?? "")
        } : nil
        return ObservationBundle(observation: observation,
                                 authorizedImages: [AiImageContent(screenshotId: shot.screenshotId, mimeType: "image/png", bytes: modelPNG)],
                                 elements: elements)
    }

    static func role(_ ax: String) -> String {
        let base = ax.split(separator: "/").first.map(String.init) ?? ax
        switch base {
        case "AXStaticText": return "static_text"
        case "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox": return "text_field"
        case "AXButton": return "button"
        default: return base.hasPrefix("AX") ? String(base.dropFirst(2)).lowercased() : base.lowercased()
        }
    }

    /// The window in screenshot pixels, clipped to the image.
    static func cropRect(window f: AgentDesktopProtocol.Rect, origin: (Double, Double), scale: Double,
                         image: (width: Int, height: Int)) -> GuiRect {
        let x0 = max(0, ((f.x - origin.0) * scale).rounded(.down))
        let y0 = max(0, ((f.y - origin.1) * scale).rounded(.down))
        let x1 = min(Double(image.width), ((f.x + f.width - origin.0) * scale).rounded(.up))
        let y1 = min(Double(image.height), ((f.y + f.height - origin.1) * scale).rounded(.up))
        return GuiRect(x: x0, y: y0, width: max(1, x1 - x0), height: max(1, y1 - y0))
    }

    static func render(source: String, crop: GuiRect, to size: Size) throws -> Data {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: source) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let cropped = image.cropping(to: CGRect(x: crop.origin.x, y: crop.origin.y, width: crop.size.width, height: crop.size.height)),
              let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ContractError(.internalError, "cannot crop the screenshot for the model") }
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        guard let out = ctx.makeImage() else { throw ContractError(.internalError, "cannot render the model image") }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ContractError(.internalError, "cannot encode the model image")
        }
        CGImageDestinationAddImage(dest, out, nil)
        guard CGImageDestinationFinalize(dest) else { throw ContractError(.internalError, "cannot encode the model image") }
        return data as Data
    }

    // MARK: GuiExecutionPort

    public func execute(_ proposal: GuiProposal, actionId: String) async throws -> GuiActionReceipt {
        let rb = try binding(proposal.runId)
        guard case let .action(action) = proposal.body else { throw ContractError(.invalidAction, "only actions are executed") }
        let started = Date()
        func receipt(_ state: DeliveryState, target: TargetIdentity?, path: String?, reason: String?,
                     ended: Date?, confirmation: String?, evidence: [String] = []) -> GuiActionReceipt {
            GuiActionReceipt(actionId: actionId, proposalId: proposal.proposalId, runId: proposal.runId, stamp: proposal.stamp,
                             actionType: action.kind, deliveryState: state, executionTarget: target, inputPath: path,
                             startedAt: state == .notSent || state == .rejected ? nil : started, endedAt: ended,
                             evidenceRefs: evidence, createdAt: started, updatedAt: Date(),
                             confirmationObservationId: confirmation, reasonCode: reason)
        }
        guard proposal.stamp.desktopId == rb.desktopId, proposal.stamp.sessionId == rb.sessionId else {
            return receipt(.rejected, target: nil, path: nil, reason: "FORBIDDEN", ended: nil, confirmation: nil)
        }
        // The target as the snapshot recorded it, for unknown outcomes.
        let snapTarget = service.observations.find(proposal.stamp.snapshotId).flatMap { s -> TargetIdentity? in
            guard let b = s.binding, let f = s.windowFrame else { return nil }
            return TargetIdentity(appId: b.appName, processId: Int(b.process.pid), processStartId: b.process.startedAt ?? "unknown",
                                  windowId: String(b.windowId), windowGeometryRevision: lock.withLock { geometry[rb.desktopId]?.revision ?? 1 },
                                  backendId: Self.backendId,
                                  windowFrameDesktopLogical: GuiRect(x: f.x, y: f.y, width: f.width, height: f.height))
        }
        let act = JSONValue.obj([("snapshotId", .string(proposal.stamp.snapshotId)), ("action", Self.actJSON(action))])
        let requestId = Self.requestId(for: actionId)
        switch await call(.act, id: requestId, context: RequestContext(sessionId: rb.sessionId), params: act) {
        case let .success(r):
            // The input went out. A fresh look at the window confirms the
            // target is still there before the explorer observes again.
            let path = r["route"]?.stringValue ?? "unknown"
            let evidence = [r["receiptId"]?.stringValue].compactMap { $0 }
            switch await call(.observe, context: RequestContext(sessionId: rb.sessionId),
                              params: .obj([("screenshot", .bool(false)), ("elements", .bool(false))])) {
            case let .success(o):
                return receipt(.confirmed, target: snapTarget, path: path, reason: nil, ended: Date(),
                               confirmation: o["snapshotId"]?.stringValue, evidence: evidence)
            case .failure:
                return receipt(.submitted, target: snapTarget, path: path, reason: "CONFIRMATION_UNAVAILABLE", ended: Date(),
                               confirmation: nil, evidence: evidence)
            }
        case let .failure(e):
            switch e.code {
            case "action_delivery_unknown", "request_acceptance_unknown":
                return receipt(.unknown, target: snapTarget, path: e.details?["receipt"]?["route"]?.stringValue ?? "runtime.act",
                               reason: "ACTION_OUTCOME_UNKNOWN", ended: nil, confirmation: nil)
            case "control_busy", "run_not_active", "deadline_exceeded":
                return receipt(.notSent, target: nil, path: nil, reason: Self.contractError(e).code.rawValue, ended: nil, confirmation: nil)
            default:
                return receipt(.rejected, target: nil, path: nil, reason: Self.contractError(e).code.rawValue, ended: nil, confirmation: nil)
            }
        }
    }

    /// actionId as a runtime/1 requestId (same ID ⇒ same request).
    static func requestId(for actionId: String) -> String {
        let allowed = actionId.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "._:-".unicodeScalars.contains($0) }
        if allowed, let first = actionId.unicodeScalars.first, CharacterSet.alphanumerics.contains(first), actionId.count <= 120 {
            return "gui-" + actionId
        }
        return "gui-" + SHA256.hash(data: Data(actionId.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static let keyNames: [String: String] = [
        "Enter": "return", "Tab": "tab", "Escape": "escape", "Backspace": "delete", "Delete": "forwarddelete",
        "ArrowUp": "up", "ArrowDown": "down", "ArrowLeft": "left", "ArrowRight": "right",
        "Home": "home", "End": "end", "PageUp": "pageup", "PageDown": "pagedown", "Space": "space",
    ]
    static let modifierNames: [String: String] = ["Shift": "shift", "Control": "ctrl", "Alt": "option", "Meta": "cmd"]

    static func actJSON(_ a: GuiAction) -> JSONValue {
        func point(_ p: Point) -> JSONValue { .obj([("imagePoint", .obj([("x", .double(p.x)), ("y", .double(p.y))]))]) }
        switch a {
        case let .click(p):
            return .obj([("kind", .string("click")), ("target", point(p))])
        case let .type(text):
            return .obj([("kind", .string("type")), ("text", .string(text))])
        case let .key(keys):
            let mods = keys.compactMap { modifierNames[$0] }
            let key = keys.first { modifierNames[$0] == nil }.map { keyNames[$0] ?? $0.lowercased() } ?? mods.last ?? "escape"
            var m: [(String, JSONValue)] = [("kind", .string("key")), ("key", .string(key))]
            if !mods.isEmpty, keys.contains(where: { modifierNames[$0] == nil }) { m.append(("modifiers", .array(mods.map(JSONValue.string)))) }
            return .obj(m)
        case let .scroll(p, direction, amountPixels):
            return .obj([("kind", .string("scroll")), ("target", point(p)), ("direction", .string(direction.rawValue)),
                         ("amount", .int(max(1, min(50, amountPixels / 40))))])
        }
    }

    static func contractError(_ e: RuntimeError) -> ContractError {
        let code: ErrorCode
        switch e.code {
        case "stale_observation": code = .staleObservation
        case "not_found": code = .notFound
        case "permission_denied": code = .forbidden
        case "invalid_target": code = .coordinateOutOfBounds
        case "control_busy": code = .desktopBusy
        case "deadline_exceeded": code = .deadlineExceeded
        case "run_not_active": code = .cancelled
        case "capability_missing": code = .capabilityMismatch
        case "action_delivery_unknown", "request_acceptance_unknown": code = .actionOutcomeUnknown
        case "schema_invalid", "invalid_argument": code = .invalidAction
        default: code = .internalError
        }
        return ContractError(code, e.message)
    }
}
