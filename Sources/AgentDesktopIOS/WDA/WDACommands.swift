import Foundation

public struct WDAStatus: Sendable, Codable, Equatable {
    public let ready: Bool
    public let message: String?
    /// WebDriverAgent build version, when the runner reports it.
    public let wdaVersion: String?
    public let runnerBundleId: String?
    public let osName: String?
    public let osVersion: String?
    public let sdkVersion: String?
    public let device: String?
    public let deviceIP: String?
    /// A session the runner already holds, if any.
    public let runnerSessionId: String?
    public let checkedAt: Date
}

public struct WDAScreenshot: Sendable, Equatable {
    public let png: Data
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let capturedAt: Date
    public let sessionId: String?
}

public enum WDASourceFormat: String, Sendable, Codable {
    case xml
    case json
    /// WDA's compact accessible-elements description.
    case description
}

public struct WDASource: Sendable, Equatable {
    public let format: WDASourceFormat
    /// The element tree as WDA returned it (XML text, or JSON re-serialised).
    public let text: String
    public let capturedAt: Date
}

public struct WDASize: Sendable, Codable, Equatable {
    public let width: Double
    public let height: Double
}

/// How to find an element (W3C `using` strategies WDA serves).
public struct WDALocator: Sendable, Equatable {
    public let using: String
    public let value: String
    public init(using: String, value: String) {
        self.using = using
        self.value = value
    }
    public static func accessibilityId(_ value: String) -> WDALocator { .init(using: "accessibility id", value: value) }
    public static func classChain(_ value: String) -> WDALocator { .init(using: "class chain", value: value) }
    public static func predicate(_ value: String) -> WDALocator { .init(using: "predicate string", value: value) }
    public static func xpath(_ value: String) -> WDALocator { .init(using: "xpath", value: value) }
}

public struct WDAElement: Sendable, Equatable {
    public let id: String
    /// The session the id belongs to; ids do not survive a session rebuild.
    public let sessionId: String
}

extension WDAClient {
    // MARK: - Reads

    /// `GET /status`. Needs no session.
    public func status(deadline: ContinuousClock.Instant? = nil) async throws -> WDAStatus {
        let reply = try await send("GET", "/status", deadline: deadline)
        guard let value = reply.answer.value as? [String: Any] else {
            throw WDAError(kind: .invalidResponse, delivery: .rejected, endpoint: reply.endpoint,
                           httpStatus: reply.answer.httpStatus, message: "status has no value object")
        }
        let build = value["build"] as? [String: Any]
        let os = value["os"] as? [String: Any]
        let ios = value["ios"] as? [String: Any]
        let ready = value["ready"] as? Bool ?? ((value["state"] as? String) == "success")
        return WDAStatus(
            ready: ready,
            message: value["message"] as? String,
            wdaVersion: build?["version"] as? String,
            runnerBundleId: build?["productBundleIdentifier"] as? String,
            osName: os?["name"] as? String,
            osVersion: os?["version"] as? String,
            sdkVersion: os?["sdkVersion"] as? String,
            device: value["device"] as? String,
            deviceIP: ios?["ip"] as? String,
            runnerSessionId: reply.answer.sessionId,
            checkedAt: reply.answeredAt
        )
    }

    /// `GET /session/:id/screenshot` — PNG of the device screen.
    public func screenshot(deadline: ContinuousClock.Instant? = nil) async throws -> WDAScreenshot {
        try await screenshot(deadline: deadline, use: .createIfNeeded)
    }

    func screenshot(deadline: ContinuousClock.Instant?, use: SessionUse) async throws -> WDAScreenshot {
        let reply = try await sessionSend("GET", "/screenshot", deadline: deadline, isAction: false, use: use)
        guard let base64 = reply.answer.value as? String,
              let png = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]),
              let size = PNGHeader.pixelSize(png) else {
            throw WDAError(kind: .invalidResponse, delivery: .rejected, endpoint: reply.endpoint,
                           httpStatus: reply.answer.httpStatus, message: "screenshot is not a base64 PNG")
        }
        return WDAScreenshot(png: png, pixelWidth: size.width, pixelHeight: size.height,
                             capturedAt: reply.answeredAt, sessionId: reply.sessionId)
    }

    /// `GET /session/:id/source` — the accessibility element tree.
    public func source(format: WDASourceFormat = .xml,
                       deadline: ContinuousClock.Instant? = nil) async throws -> WDASource {
        try await source(format: format, deadline: deadline, use: .createIfNeeded)
    }

    func source(format: WDASourceFormat, deadline: ContinuousClock.Instant?,
                use: SessionUse) async throws -> WDASource {
        let reply = try await sessionSend("GET", "/source", query: [URLQueryItem(name: "format", value: format.rawValue)],
                                          deadline: deadline, isAction: false, use: use)
        let text: String?
        switch reply.answer.value {
        case let string as String:
            text = string
        case let object? where JSONSerialization.isValidJSONObject(object):
            text = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) }
        default:
            text = nil
        }
        guard let text, !text.isEmpty else {
            throw WDAError(kind: .invalidResponse, delivery: .rejected, endpoint: reply.endpoint,
                           httpStatus: reply.answer.httpStatus, message: "source is empty")
        }
        return WDASource(format: format, text: text, capturedAt: reply.answeredAt)
    }

    /// `GET /session/:id/window/size` — logical points, current orientation.
    public func windowSize(deadline: ContinuousClock.Instant? = nil) async throws -> WDASize {
        try await windowSize(deadline: deadline, use: .createIfNeeded)
    }

    func windowSize(deadline: ContinuousClock.Instant?, use: SessionUse) async throws -> WDASize {
        let reply = try await sessionSend("GET", "/window/size", deadline: deadline, isAction: false, use: use)
        guard let value = reply.answer.value as? [String: Any],
              let width = (value["width"] as? NSNumber)?.doubleValue,
              let height = (value["height"] as? NSNumber)?.doubleValue else {
            throw WDAError(kind: .invalidResponse, delivery: .rejected, endpoint: reply.endpoint,
                           httpStatus: reply.answer.httpStatus, message: "window size missing")
        }
        return WDASize(width: width, height: height)
    }

    /// `GET /session/:id/wda/screen` — screen scale (pixels per point).
    public func screenScale(deadline: ContinuousClock.Instant? = nil) async throws -> Double {
        try await screenScale(deadline: deadline, use: .createIfNeeded)
    }

    func screenScale(deadline: ContinuousClock.Instant?, use: SessionUse) async throws -> Double {
        let reply = try await sessionSend("GET", "/wda/screen", deadline: deadline, isAction: false, use: use)
        guard let scale = ((reply.answer.value as? [String: Any])?["scale"] as? NSNumber)?.doubleValue, scale > 0 else {
            throw WDAError(kind: .invalidResponse, delivery: .rejected, endpoint: reply.endpoint,
                           httpStatus: reply.answer.httpStatus, message: "screen scale missing")
        }
        return scale
    }

    /// `GET /session/:id/orientation` — `PORTRAIT`, `LANDSCAPE`, ...
    public func orientation(deadline: ContinuousClock.Instant? = nil) async throws -> String {
        try await orientation(deadline: deadline, use: .createIfNeeded)
    }

    func orientation(deadline: ContinuousClock.Instant?, use: SessionUse) async throws -> String {
        let reply = try await sessionSend("GET", "/orientation", deadline: deadline, isAction: false, use: use)
        guard let value = reply.answer.value as? String else {
            throw WDAError(kind: .invalidResponse, delivery: .rejected, endpoint: reply.endpoint,
                           httpStatus: reply.answer.httpStatus, message: "orientation missing")
        }
        return value
    }

    /// `POST /session/:id/element`. No match is `elementNotFound`.
    public func findElement(_ locator: WDALocator,
                            deadline: ContinuousClock.Instant? = nil) async throws -> WDAElement {
        let reply = try await sessionSend("POST", "/element", body: ["using": locator.using, "value": locator.value],
                                          deadline: deadline, isAction: false)
        let value = reply.answer.value as? [String: Any]
        guard let id = value?["element-6066-11e4-a52e-4f735466cecf"] as? String ?? value?["ELEMENT"] as? String,
              let session = reply.sessionId ?? currentSessionId else {
            throw WDAError(kind: .invalidResponse, delivery: .rejected, endpoint: reply.endpoint,
                           httpStatus: reply.answer.httpStatus, message: "element answer has no id")
        }
        return WDAElement(id: id, sessionId: session)
    }

    // MARK: - Input

    /// Runs one touch gesture as a W3C Actions request.
    public func perform(_ gesture: WDAGesture,
                        deadline: ContinuousClock.Instant? = nil) async throws -> WDAActionEvidence {
        if let problem = gesture.validate() {
            throw WDAError(kind: .invalidArgument, delivery: .notSent,
                           endpoint: "POST /session/:id/actions", message: problem)
        }
        let reply = try await sessionSend("POST", "/actions", body: gesture.w3cActionsBody(),
                                          deadline: deadline, isAction: true)
        return evidence(gesture.operation, reply)
    }

    public func tap(_ point: WDAPoint, deadline: ContinuousClock.Instant? = nil) async throws -> WDAActionEvidence {
        try await perform(.tap(point), deadline: deadline)
    }

    public func swipe(from: WDAPoint, to: WDAPoint, duration: Duration = .milliseconds(300),
                      deadline: ContinuousClock.Instant? = nil) async throws -> WDAActionEvidence {
        try await perform(.swipe(from: from, to: to, duration: duration), deadline: deadline)
    }

    public func drag(from: WDAPoint, to: WDAPoint, hold: Duration = .milliseconds(600),
                     duration: Duration = .milliseconds(500),
                     deadline: ContinuousClock.Instant? = nil) async throws -> WDAActionEvidence {
        try await perform(.drag(from: from, to: to, hold: hold, duration: duration), deadline: deadline)
    }

    public func longPress(_ point: WDAPoint, duration: Duration = .milliseconds(1000),
                          deadline: ContinuousClock.Instant? = nil) async throws -> WDAActionEvidence {
        try await perform(.longPress(point, duration: duration), deadline: deadline)
    }

    /// `POST /session/:id/element/:eid/click`.
    public func click(_ element: WDAElement,
                      deadline: ContinuousClock.Instant? = nil) async throws -> WDAActionEvidence {
        try requireCurrent(element, endpoint: "POST /session/:id/element/:eid/click")
        let reply = try await sessionSend("POST", "/element/\(element.id)/click", body: [String: Any](),
                                          deadline: deadline, isAction: true)
        return evidence("clickElement", reply)
    }

    /// Types Unicode text (Chinese, emoji, ...) on the device keyboard.
    ///
    /// Without `element` it goes to `POST /session/:id/wda/keys` (the
    /// focused field); with one, to `POST /session/:id/element/:eid/value`.
    /// Line breaks press Return on iOS and can submit a form, so they are
    /// refused unless `allowLineBreaks` is set: submitting is an explicit
    /// action, never a side effect of text.
    public func typeText(_ text: String, into element: WDAElement? = nil, allowLineBreaks: Bool = false,
                         deadline: ContinuousClock.Instant? = nil) async throws -> WDAActionEvidence {
        let endpoint = element == nil ? "POST /session/:id/wda/keys" : "POST /session/:id/element/:eid/value"
        guard !text.isEmpty else {
            throw WDAError(kind: .invalidArgument, delivery: .notSent, endpoint: endpoint, message: "text is empty")
        }
        if !allowLineBreaks, text.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) }) {
            throw WDAError(kind: .invalidArgument, delivery: .notSent, endpoint: endpoint,
                           message: "text contains a line break; pass allowLineBreaks to send Return")
        }
        // One array item per grapheme cluster: an emoji with modifiers or
        // a ZWJ sequence is never split.
        let characters = text.map(String.init)
        if let element {
            try requireCurrent(element, endpoint: endpoint)
            let reply = try await sessionSend("POST", "/element/\(element.id)/value",
                                              body: ["value": characters, "text": text],
                                              deadline: deadline, isAction: true)
            return evidence("typeText", reply)
        }
        let reply = try await sessionSend("POST", "/wda/keys", body: ["value": characters],
                                          deadline: deadline, isAction: true)
        return evidence("typeText", reply)
    }

    /// `POST /session/:id/wda/apps/launch`.
    public func launchApp(bundleId: String, arguments: [String] = [], environment: [String: String] = [:],
                          deadline: ContinuousClock.Instant? = nil) async throws -> WDAActionEvidence {
        guard !bundleId.isEmpty else {
            throw WDAError(kind: .invalidArgument, delivery: .notSent,
                           endpoint: "POST /session/:id/wda/apps/launch", message: "bundleId is empty")
        }
        let reply = try await sessionSend("POST", "/wda/apps/launch",
                                          body: ["bundleId": bundleId, "arguments": arguments,
                                                 "environment": environment] as [String: Any],
                                          deadline: deadline, isAction: true)
        return evidence("launchApp", reply)
    }

    /// `POST /wda/homescreen` — Home button. Needs no session.
    public func home(deadline: ContinuousClock.Instant? = nil) async throws -> WDAActionEvidence {
        let reply = try await send("POST", "/wda/homescreen", body: [String: Any](),
                                   deadline: deadline, isAction: true)
        return evidence("home", reply)
    }

    /// `GET /wda/activeAppInfo` — the foreground app. Needs no session.
    public func activeAppBundleId(deadline: ContinuousClock.Instant? = nil) async throws -> String? {
        let reply = try await send("GET", "/wda/activeAppInfo", deadline: deadline)
        return (reply.answer.value as? [String: Any])?["bundleId"] as? String
    }

    /// Element ids are session-scoped; one from an older session would
    /// address the wrong tree, so it is refused rather than sent.
    private func requireCurrent(_ element: WDAElement, endpoint: String) throws {
        guard element.sessionId == currentSessionId else {
            throw WDAError(kind: .elementNotFound, delivery: .notSent, endpoint: endpoint,
                           message: "element belongs to session \(element.sessionId), not the current one")
        }
    }
}
