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

    /// Screenshot plus the geometry needed to interpret it.
    public func observe(deadline: ContinuousClock.Instant? = nil) async throws -> WDAObservation {
        let shot = try await screenshot(deadline: deadline)
        let size = try await windowSize(deadline: deadline)
        let scale = try await screenScale(deadline: deadline)
        let orientation = try await orientation(deadline: deadline)
        let version = "\(shot.pixelWidth)x\(shot.pixelHeight)@\(scale)/\(size.width)x\(size.height)/\(orientation)"
        return WDAObservation(
            observationId: UUID(), targetId: target.targetId, capturedAt: shot.capturedAt,
            imagePixelSize: IOSPixelSize(width: shot.pixelWidth, height: shot.pixelHeight),
            contentRect: IOSRect(x: 0, y: 0, width: size.width, height: size.height),
            orientation: orientation, screenScale: scale, geometryVersion: version,
            backendSessionId: currentSessionId, png: shot.png
        )
    }

    /// Builds a per-capability report from `/status` and from routes the
    /// runner actually serves. Never sends a command that can change the
    /// phone: gestures are checked with an empty W3C action list (a no-op),
    /// text and Home are not sent at all.
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
                                  capabilities: unknown + [audio], hostEffects: Self.hostEffects, probedAt: Date())
        }

        var capabilities: [IOSCapability] = []
        let ready = "GET /status ready=true (\(status.message ?? "no message"))"

        // Observation: screenshot + geometry.
        var observation: WDAProbeReport.ProbeObservation?
        do {
            let seen = try await observe(deadline: deadline)
            observation = .init(observationId: seen.observationId, targetId: seen.targetId,
                                capturedAt: seen.capturedAt, imagePixelSize: seen.imagePixelSize,
                                contentRect: seen.contentRect, orientation: seen.orientation,
                                geometryVersion: seen.geometryVersion, backendSessionId: seen.backendSessionId)
            capabilities.append(entry(.screenshot, .supported,
                                      [ready, "GET screenshot decoded PNG \(seen.imagePixelSize.width)x\(seen.imagePixelSize.height)"]))
        } catch let error as WDAError {
            capabilities.append(entry(.screenshot, error.kind == .unsupportedEndpoint ? .unsupported : .unverified,
                                      [ready, "observe failed: \(error.kind.rawValue): \(error.message)"]))
        } catch {
            capabilities.append(entry(.screenshot, .unverified, [ready, "observe failed: \(error)"]))
        }

        // Element tree.
        do {
            let tree = try await source(format: .xml, deadline: deadline)
            let nodes = tree.text.components(separatedBy: "<XCUIElementType").count - 1
            capabilities.append(entry(.elementTree, .supported,
                                      ["GET source returned \(tree.text.utf8.count) bytes, \(nodes) XCUIElementType nodes"],
                                      ["self-drawn views (games, canvas, some WebViews) may expose few nodes"]))
        } catch let error as WDAError {
            capabilities.append(entry(.elementTree, error.kind == .unsupportedEndpoint ? .unsupported : .unverified,
                                      ["GET source failed: \(error.kind.rawValue): \(error.message)"]))
        } catch {
            capabilities.append(entry(.elementTree, .unverified, ["GET source failed: \(error)"]))
        }

        // Gestures: an empty W3C action list does nothing on any runner.
        let gestures: [IOSCapabilityName] = [.tap, .swipe, .drag, .longPress]
        let actionsRoute = await routeServed {
            _ = try await self.sessionSend("POST", "/actions", body: ["actions": [Any]()],
                                           deadline: deadline, isAction: false)
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
                              capabilities: capabilities, hostEffects: Self.hostEffects, probedAt: Date())
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
                return .unknown("\(error.kind.rawValue): \(error.message)")
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
