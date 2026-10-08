import Foundation

// Shapes follow the review report §6.2 (Target / Observation / Capabilities
// / Host effects). They are local to this module on purpose: the formal
// contract (docs/ios, contracts/) is drafted elsewhere and these map onto it
// field by field.

public struct IOSTarget: Sendable, Codable, Equatable {
    public let targetId: String
    public let kind: String
    public let backend: String
    /// The configured UDID, or nil. WDA's `/status` reports no UDID.
    public let deviceIdentity: String?
    /// `configured_udid`: the UDID the runner was started for.
    /// `runner_endpoint`: only the runner URL is known; two phones behind
    /// one URL over time cannot be told apart.
    public let identityConfidence: String
}

public struct IOSPixelSize: Sendable, Codable, Equatable {
    public let width: Int
    public let height: Int
}

public struct IOSRect: Sendable, Codable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
}

/// One observation. Coordinates of actions planned on it are WDA points
/// within `contentRect`; image pixels map to points by `screenScale`.
public struct WDAObservation: Sendable, Equatable {
    public let observationId: UUID
    public let targetId: String
    public let capturedAt: Date
    public let imagePixelSize: IOSPixelSize
    /// Screen in WDA points (origin 0,0).
    public let contentRect: IOSRect
    public let orientation: String
    public let screenScale: Double
    /// Changes whenever image size, point size, scale or orientation do.
    public let geometryVersion: String
    public let backendSessionId: String?
    public let png: Data
}

public enum IOSCapabilityName: String, Sendable, Codable, CaseIterable {
    case tap, swipe, drag, longPress, unicodeText, elementTree, screenshot, appLaunch, home, audio
}

public enum IOSCapabilityState: String, Sendable, Codable {
    case supported, unsupported, unverified
}

public struct IOSCapability: Sendable, Codable, Equatable {
    public let name: IOSCapabilityName
    public let state: IOSCapabilityState
    /// `wda <version> / iOS <version>` when known.
    public let version: String?
    public let evidence: [String]
    public let conditions: [String]
}

public struct IOSHostEffects: Sendable, Codable, Equatable {
    public let usesPhysicalPointer: Bool
    public let mayTemporarilyActivateApp: Bool
    public let borrowsHostFocus: Bool
    public let usesHostClipboard: Bool
    /// Why these values hold and whether a device run backs them.
    public let basis: String
}

public struct WDAProbeReport: Sendable, Codable, Equatable {
    public let target: IOSTarget
    public let runnerReady: Bool
    public let status: WDAStatus?
    /// The observation's geometry (image bytes are not kept in the report).
    public let observation: ProbeObservation?
    /// Whether a screenshot plus its geometry (window size, scale,
    /// orientation) was read from one session. Separate from the
    /// `screenshot` capability: a runner can serve screenshots and still miss
    /// a geometry route, which leaves only this `unverified`.
    public let observationState: IOSCapabilityState
    public let observationEvidence: [String]
    public let capabilities: [IOSCapability]
    public let hostEffects: IOSHostEffects
    public let probedAt: Date

    public struct ProbeObservation: Sendable, Codable, Equatable {
        public let observationId: UUID
        public let targetId: String
        public let capturedAt: Date
        public let imagePixelSize: IOSPixelSize
        public let contentRect: IOSRect
        public let orientation: String
        public let geometryVersion: String
        public let backendSessionId: String?
    }

    public func capability(_ name: IOSCapabilityName) -> IOSCapability? {
        capabilities.first { $0.name == name }
    }
}

extension WDAClient {
    public nonisolated var target: IOSTarget {
        if let udid = configuration.deviceUDID, !udid.isEmpty {
            return IOSTarget(targetId: "ios:wda:\(udid)", kind: "ios", backend: "wda",
                             deviceIdentity: udid, identityConfidence: "configured_udid")
        }
        let host = configuration.baseURL.host ?? "unknown"
        let port = configuration.baseURL.port.map { ":\($0)" } ?? ""
        return IOSTarget(targetId: "ios:wda:\(host)\(port)", kind: "ios", backend: "wda",
                         deviceIdentity: nil, identityConfidence: "runner_endpoint")
    }

    /// WDA executes commands inside the XCTest runner on the phone: no Mac
    /// pointer, no Mac app activation, no Mac clipboard. This is the
    /// design of the path; I04 on a real device is what proves it.
    public nonisolated static let hostEffects = IOSHostEffects(
        usesPhysicalPointer: false,
        mayTemporarilyActivateApp: false,
        borrowsHostFocus: false,
        usesHostClipboard: false,
        basis: "by design: commands run in the on-device XCTest runner over HTTP; real-device check I04 NOT_RUN"
    )

    /// Screenshot plus the geometry needed to interpret it, all read from
    /// one session.
    ///
    /// The four reads are pinned to that session: none of them silently
    /// moves to a new one. If the session is invalidated or replaced part
    /// way, the whole observation is taken again once; a second change
    /// fails with `sessionInvalid` instead of mixing two sessions' data.
    public func observe(deadline: ContinuousClock.Instant? = nil) async throws -> WDAObservation {
        try await observe(deadline: deadline, use: .createIfNeeded)
    }

    func observe(deadline: ContinuousClock.Instant?, use: SessionUse) async throws -> WDAObservation {
        var decoded: WDAScreenshot?
        return try await observe(deadline: deadline, use: use, decodedScreenshot: &decoded)
    }

    /// As `observe(deadline:use:)`, and leaves the last screenshot it decoded
    /// in `decodedScreenshot` even when a later geometry read fails, so the
    /// probe can credit the screenshot route without fetching it again.
    func observe(deadline: ContinuousClock.Instant?, use: SessionUse,
                 decodedScreenshot: inout WDAScreenshot?) async throws -> WDAObservation {
        var lastChange = ""
        for _ in 0 ..< 2 {
            let id = try await session(use, deadline: deadline)
            let generation = sessionGeneration
            let shot: WDAScreenshot
            let size: WDASize
            let scale: Double
            let orientation: String
            do {
                shot = try await screenshot(deadline: deadline, use: .pinned(id))
                decodedScreenshot = shot
                size = try await windowSize(deadline: deadline, use: .pinned(id))
                scale = try await screenScale(deadline: deadline, use: .pinned(id))
                orientation = try await self.orientation(deadline: deadline, use: .pinned(id))
            } catch let error as WDAError where error.kind == .sessionInvalid {
                lastChange = "session \(id) became invalid at \(error.endpoint)"
                continue
            }
            guard sessionGeneration == generation, currentSessionId == id else {
                lastChange = "session changed from \(id) (generation \(generation)) to "
                    + "\(currentSessionId ?? "none") (generation \(sessionGeneration)) during the observation"
                continue
            }
            let version = "\(shot.pixelWidth)x\(shot.pixelHeight)@\(scale)/\(size.width)x\(size.height)/\(orientation)"
            return WDAObservation(
                observationId: UUID(), targetId: target.targetId, capturedAt: shot.capturedAt,
                imagePixelSize: IOSPixelSize(width: shot.pixelWidth, height: shot.pixelHeight),
                contentRect: IOSRect(x: 0, y: 0, width: size.width, height: size.height),
                orientation: orientation, screenScale: scale, geometryVersion: version,
                backendSessionId: id, png: shot.png
            )
        }
        throw WDAError(kind: .sessionInvalid, delivery: .rejected, endpoint: "observe",
                       message: "no consistent observation after one retry: \(lastChange)")
    }

    /// Builds a per-capability report from `/status` and from routes the
    /// runner actually serves. Never sends a command that can change the
    /// phone: gestures are checked with an empty W3C action list (a no-op),
    /// text and Home are not sent at all, and no session is created
    /// (`POST /session` can launch or foreground an app). Session-scoped
    /// checks use the client's current session, or the runner's when
    /// `adoptRunnerSession` is on; without one they stay `unverified`. Call
    /// `ensureSession()` first to probe them, accepting what it may do.
    ///
    /// A capability is `supported` only when the runner serves it and either
    /// the probe observed it directly (screenshot, element tree) or
    /// `acceptedOnDevice` carries a real-device acceptance record for it
    /// (e.g. `"I12 PASS 2026-10-10 iPhone 15 / iOS 18.6"`). Otherwise it is
    /// `unverified`, or `unsupported` when the route is missing.
    public func probe(acceptedOnDevice: [IOSCapabilityName: String] = [:],
                      deadline: ContinuousClock.Instant? = nil) async -> WDAProbeReport {
        var status: WDAStatus?
        var statusError: WDAError?
        do { status = try await self.status(deadline: deadline) } catch let error as WDAError {
            statusError = error
        } catch {
            statusError = WDAError(kind: .invalidResponse, delivery: .rejected, endpoint: "GET /status",
                                   message: "\(error)")
        }
        let version = status.map { s in
            [s.wdaVersion.map { "wda \($0)" }, s.osVersion.map { "\(s.osName ?? "iOS") \($0)" }]
                .compactMap { $0 }.joined(separator: " / ")
        }.flatMap { $0.isEmpty ? nil : $0 }

        func entry(_ name: IOSCapabilityName, _ state: IOSCapabilityState, _ evidence: [String],
                   _ conditions: [String] = []) -> IOSCapability {
            IOSCapability(name: name, state: state, version: version, evidence: evidence, conditions: conditions)
        }
        let audio = entry(.audio, .unsupported, ["WDA serves no audio stream route"],
                          ["audio needs another backend (CoreDevice / Mirroring)"])

        guard let status, status.ready else {
            let why = statusError.map { "GET /status failed: \($0.kind.rawValue): \($0.message)" }
                ?? "GET /status answered ready=false"
            let unknown = IOSCapabilityName.allCases.filter { $0 != .audio }.map {
                entry($0, .unverified, [why], ["runner must be running and reachable"])
            }
            return WDAProbeReport(target: target, runnerReady: false, status: status, observation: nil,
                                  observationState: .unverified, observationEvidence: [why],
                                  capabilities: unknown + [audio], hostEffects: Self.hostEffects, probedAt: Date())
        }

        var capabilities: [IOSCapability] = []
        let ready = "GET /status ready=true (\(status.message ?? "no message"))"

        // Observation: screenshot + geometry from one existing session.
        // The screenshot capability is judged on the screenshot route alone;
        // a missing geometry route only leaves the combined observation
        // unverified. A screenshot decoded inside a failed observation is
        // kept: asking again could only spend the same, possibly expired,
        // deadline and would hide that the route already answered.
        var observation: WDAProbeReport.ProbeObservation?
        var observationState = IOSCapabilityState.unverified
        var observationEvidence: [String] = []
        var decodedShot: WDAScreenshot?
        do {
            let seen = try await observe(deadline: deadline, use: .existingOnly, decodedScreenshot: &decodedShot)
            observation = .init(observationId: seen.observationId, targetId: seen.targetId,
                                capturedAt: seen.capturedAt, imagePixelSize: seen.imagePixelSize,
                                contentRect: seen.contentRect, orientation: seen.orientation,
                                geometryVersion: seen.geometryVersion, backendSessionId: seen.backendSessionId)
            observationState = .supported
            observationEvidence = ["screenshot, window size, scale and orientation read from session "
                                   + "\(seen.backendSessionId ?? "?"): \(seen.geometryVersion)"]
            capabilities.append(entry(.screenshot, .supported,
                                      [ready, "GET screenshot decoded PNG \(seen.imagePixelSize.width)x\(seen.imagePixelSize.height)"]))
        } catch {
            observationEvidence = ["observe failed: \(Self.describe(error))"]
            if let shot = decodedShot {
                capabilities.append(entry(.screenshot, .supported,
                                          [ready, "GET screenshot decoded PNG \(shot.pixelWidth)x\(shot.pixelHeight) "
                                           + "(during the observation; geometry failed afterwards)"]))
            } else {
                do {
                    let shot = try await screenshot(deadline: deadline, use: .existingOnly)
                    capabilities.append(entry(.screenshot, .supported,
                                              [ready, "GET screenshot decoded PNG \(shot.pixelWidth)x\(shot.pixelHeight)"]))
                } catch let error as WDAError {
                    capabilities.append(entry(.screenshot, error.kind == .unsupportedEndpoint ? .unsupported : .unverified,
                                              [ready, "GET screenshot failed: \(Self.describe(error))"]))
                } catch {
                    capabilities.append(entry(.screenshot, .unverified, [ready, "GET screenshot failed: \(error)"]))
                }
            }
        }

        // Element tree.
        do {
            let tree = try await source(format: .xml, deadline: deadline, use: .existingOnly)
            let nodes = tree.text.components(separatedBy: "<XCUIElementType").count - 1
            capabilities.append(entry(.elementTree, .supported,
                                      ["GET source returned \(tree.text.utf8.count) bytes, \(nodes) XCUIElementType nodes"],
                                      ["self-drawn views (games, canvas, some WebViews) may expose few nodes"]))
        } catch let error as WDAError {
            capabilities.append(entry(.elementTree, error.kind == .unsupportedEndpoint ? .unsupported : .unverified,
                                      ["GET source failed: \(Self.describe(error))"]))
        } catch {
            capabilities.append(entry(.elementTree, .unverified, ["GET source failed: \(error)"]))
        }

        // Gestures: an empty W3C action list does nothing on any runner.
        let gestures: [IOSCapabilityName] = [.tap, .swipe, .drag, .longPress]
        let actionsRoute = await routeServed {
            _ = try await self.sessionSend("POST", "/actions", body: ["actions": [Any]()],
                                           deadline: deadline, isAction: false, use: .existingOnly)
        }
        for name in gestures {
            let conditions = name == .tap ? [] : ["W3C Actions touch pointer; acceptance I12 confirms screen change"]
            capabilities.append(classify(name, routeEvidence: actionsRoute, route: "POST actions (empty list)",
                                         accepted: acceptedOnDevice[name], conditions: conditions, entry: entry))
        }

        // App routes: read-only activeAppInfo shows the /wda/apps family.
        let appsRoute = await routeServed { _ = try await self.activeAppBundleId(deadline: deadline) }
        capabilities.append(classify(.appLaunch, routeEvidence: appsRoute, route: "GET wda/activeAppInfo",
                                     accepted: acceptedOnDevice[.appLaunch],
                                     conditions: ["app must be installed; launch moves the phone's foreground app"],
                                     entry: entry))

        // Not sent: typing or Home would change the phone.
        let notProbed = "not probed: the command changes the phone; runner \(status.wdaVersion ?? "unknown version") is ready"
        capabilities.append(stateFromAcceptance(.unicodeText, accepted: acceptedOnDevice[.unicodeText],
                                                evidence: [notProbed],
                                                conditions: ["needs a focused text field",
                                                             "Chinese / emoji / multi-line per acceptance I09",
                                                             "secure fields cannot be read back"],
                                                entry: entry))
        capabilities.append(stateFromAcceptance(.home, accepted: acceptedOnDevice[.home], evidence: [notProbed],
                                                conditions: [], entry: entry))
        capabilities.append(audio)

        return WDAProbeReport(target: target, runnerReady: true, status: status, observation: observation,
                              observationState: observationState, observationEvidence: observationEvidence,
                              capabilities: capabilities, hostEffects: Self.hostEffects, probedAt: Date())
    }

    private static func describe(_ error: Error) -> String {
        guard let error = error as? WDAError else { return "\(error)" }
        if error.kind == .noSession {
            return "noSession: the probe does not create a WDA session (POST /session may launch or "
                + "foreground an app); call ensureSession() first or enable adoptRunnerSession"
        }
        return "\(error.kind.rawValue) at \(error.endpoint): \(error.message)"
    }

    private enum RouteEvidence {
        case served(String)
        case missing(String)
        case unknown(String)
    }

    private func routeServed(_ call: () async throws -> Void) async -> RouteEvidence {
        do {
            try await call()
            return .served("answered success")
        } catch let error as WDAError {
            switch error.kind {
            case .unsupportedEndpoint:
                return .missing("route not served (\(error.wdaErrorCode ?? "http \(error.httpStatus ?? 0)"))")
            case .invalidArgument, .wdaRejected, .elementNotFound:
                // The runner routed the request and judged its arguments.
                return .served("route answered \(error.wdaErrorCode ?? error.kind.rawValue)")
            default:
                return .unknown(Self.describe(error))
            }
        } catch {
            return .unknown("\(error)")
        }
    }

    private func classify(_ name: IOSCapabilityName, routeEvidence: RouteEvidence, route: String,
                          accepted: String?, conditions: [String],
                          entry: (IOSCapabilityName, IOSCapabilityState, [String], [String]) -> IOSCapability) -> IOSCapability {
        switch routeEvidence {
        case let .missing(why):
            return entry(name, .unsupported, ["\(route): \(why)"], conditions)
        case let .unknown(why):
            return entry(name, .unverified, ["\(route): \(why)"], conditions)
        case let .served(why):
            return stateFromAcceptance(name, accepted: accepted, evidence: ["\(route): \(why)"],
                                       conditions: conditions, entry: entry)
        }
    }

    private func stateFromAcceptance(_ name: IOSCapabilityName, accepted: String?, evidence: [String],
                                     conditions: [String],
                                     entry: (IOSCapabilityName, IOSCapabilityState, [String], [String]) -> IOSCapability) -> IOSCapability {
        if let accepted {
            return entry(name, .supported, evidence + ["real-device acceptance: \(accepted)"], conditions)
        }
        return entry(name, .unverified, evidence + ["effect not confirmed on a real device"], conditions)
    }
}
