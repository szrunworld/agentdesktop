import Foundation
import Testing
@testable import AgentDesktopIOS

/// Runs `body`, expecting a `WDAError`, and returns it.
private func expectWDAError<T>(_ body: () async throws -> T,
                               sourceLocation: SourceLocation = #_sourceLocation) async -> WDAError? {
    do {
        _ = try await body()
        Issue.record("expected a WDAError", sourceLocation: sourceLocation)
        return nil
    } catch let error as WDAError {
        return error
    } catch {
        Issue.record("expected a WDAError, got \(error)", sourceLocation: sourceLocation)
        return nil
    }
}

/// The pointer action items of the single `finger1` source in a body.
private func pointerItems(_ body: [String: Any]?) -> [[String: Any]] {
    guard let sources = body?["actions"] as? [[String: Any]], sources.count == 1 else { return [] }
    let source = sources[0]
    #expect(source["type"] as? String == "pointer")
    #expect(source["id"] as? String == "finger1")
    #expect((source["parameters"] as? [String: Any])?["pointerType"] as? String == "touch")
    return source["actions"] as? [[String: Any]] ?? []
}

private func shape(_ items: [[String: Any]]) -> [String] {
    items.map { item in
        let type = item["type"] as? String ?? "?"
        switch type {
        case "pointerMove":
            let x = (item["x"] as? NSNumber)?.doubleValue ?? -1
            let y = (item["y"] as? NSNumber)?.doubleValue ?? -1
            let d = (item["duration"] as? NSNumber)?.intValue ?? -1
            #expect(item["origin"] as? String == "viewport")
            return "move(\(Int(x)),\(Int(y)),\(d)ms)"
        case "pause":
            return "pause(\((item["duration"] as? NSNumber)?.intValue ?? -1)ms)"
        case "pointerDown", "pointerUp":
            #expect((item["button"] as? NSNumber)?.intValue == 0)
            return type == "pointerDown" ? "down" : "up"
        default:
            return type
        }
    }
}

@Suite struct WDAGestureShapeTests {
    @Test func swipeIsMoveDownMoveUp() async throws {
        let fake = FakeWDA()
        let client = fake.client()
        let evidence = try await client.swipe(from: WDAPoint(x: 200, y: 700), to: WDAPoint(x: 200, y: 150),
                                              duration: .milliseconds(400))
        let sent = fake.requests("POST", suffix: "/actions")
        #expect(sent.count == 1)
        #expect(shape(pointerItems(sent[0].json)) == ["move(200,700,0ms)", "down", "move(200,150,400ms)", "up"])
        #expect(evidence.operation == "swipe")
    }

    @Test func dragHoldsBeforeMovingAndSettlesBeforeLifting() async throws {
        let fake = FakeWDA()
        let client = fake.client()
        _ = try await client.drag(from: WDAPoint(x: 60, y: 300), to: WDAPoint(x: 300, y: 500),
                                  hold: .milliseconds(800), duration: .milliseconds(600))
        let sent = fake.requests("POST", suffix: "/actions")
        #expect(shape(pointerItems(sent.first?.json)) ==
            ["move(60,300,0ms)", "down", "pause(800ms)", "move(300,500,600ms)", "pause(150ms)", "up"])
    }

    @Test func longPressHoldsInPlace() async throws {
        let fake = FakeWDA()
        let client = fake.client()
        _ = try await client.longPress(WDAPoint(x: 120, y: 480), duration: .milliseconds(1500))
        let sent = fake.requests("POST", suffix: "/actions")
        #expect(shape(pointerItems(sent.first?.json)) == ["move(120,480,0ms)", "down", "pause(1500ms)", "up"])
    }

    @Test func tapIsShortContact() async throws {
        let fake = FakeWDA()
        let client = fake.client()
        _ = try await client.tap(WDAPoint(x: 10, y: 20))
        let sent = fake.requests("POST", suffix: "/actions")
        #expect(shape(pointerItems(sent.first?.json)) == ["move(10,20,0ms)", "down", "pause(50ms)", "up"])
    }

    @Test func gesturesNeverUseRemovedTouchActionRoutes() async throws {
        let fake = FakeWDA()
        let client = fake.client()
        _ = try await client.tap(WDAPoint(x: 1, y: 1))
        _ = try await client.swipe(from: WDAPoint(x: 1, y: 1), to: WDAPoint(x: 1, y: 100))
        _ = try await client.drag(from: WDAPoint(x: 1, y: 1), to: WDAPoint(x: 50, y: 50))
        _ = try await client.longPress(WDAPoint(x: 1, y: 1))
        let paths = fake.requests.map(\.path)
        #expect(!paths.contains { $0.contains("touch/") || $0.contains("dragfromtoforduration") || $0.contains("/wda/tap") })
        #expect(fake.requests("POST", suffix: "/actions").count == 4)
    }

    @Test func invalidGesturesAreNotSent() async throws {
        let fake = FakeWDA()
        let client = fake.client()
        for gesture in [WDAGesture.tap(WDAPoint(x: .nan, y: 1)),
                        .swipe(from: WDAPoint(x: 5, y: 5), to: WDAPoint(x: 5, y: 5), duration: .milliseconds(100)),
                        .longPress(WDAPoint(x: 5, y: 5), duration: .zero)] {
            let error = await expectWDAError { try await client.perform(gesture) }
            #expect(error?.kind == .invalidArgument)
            #expect(error?.delivery == .notSent)
        }
        #expect(fake.requests.isEmpty)
    }
}

@Suite struct WDASessionTests {
    @Test func sessionIsCreatedOnceAndReused() async throws {
        let fake = FakeWDA()
        let client = fake.client()
        _ = try await client.tap(WDAPoint(x: 1, y: 1))
        _ = try await client.screenshot()
        _ = try await client.source()
        #expect(fake.requests("POST", suffix: "/session").count == 1)
        #expect(await client.currentSessionId == "S1")
        #expect(fake.requests.allSatisfy { !$0.path.hasPrefix("/session/") || $0.path.hasPrefix("/session/S1/") })
    }

    @Test func sessionCapabilitiesUseW3CShape() async throws {
        let fake = FakeWDA()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let client = WDAClient(configuration: WDAConfiguration(
            baseURL: fake.baseURL, sessionCapabilities: ["bundleId": .string("com.apple.Preferences")]),
            urlSessionConfiguration: configuration)
        try await client.ensureSession()
        let body = fake.requests("POST", suffix: "/session").first?.json
        let capabilities = body?["capabilities"] as? [String: Any]
        #expect((capabilities?["alwaysMatch"] as? [String: Any])?["bundleId"] as? String == "com.apple.Preferences")
        #expect((capabilities?["firstMatch"] as? [Any])?.count == 1)
    }

    @Test func lostSessionFailsTheActionAndIsNotReplayed() async throws {
        let fake = FakeWDA()
        let client = fake.client()
        let first = try await client.tap(WDAPoint(x: 10, y: 10))
        #expect(first.sessionId == "S1")

        fake.killSession("S1")  // runner restarted
        let error = await expectWDAError {
            try await client.swipe(from: WDAPoint(x: 10, y: 400), to: WDAPoint(x: 10, y: 100))
        }
        #expect(error?.kind == .sessionInvalid)
        #expect(error?.delivery == .rejected)
        #expect(await client.currentSessionId == nil)

        // Nothing was retried on a new session behind the caller's back.
        let actions = fake.requests("POST", suffix: "/actions")
        #expect(actions.map(\.path) == ["/session/S1/actions", "/session/S1/actions"])
        #expect(fake.requests("POST", suffix: "/session").count == 1)

        // The next command opens S2 and carries only itself.
        let third = try await client.longPress(WDAPoint(x: 5, y: 5))
        #expect(third.sessionId == "S2")
        let after = fake.requests("POST", suffix: "/actions")
        #expect(after.map(\.path) == ["/session/S1/actions", "/session/S1/actions", "/session/S2/actions"])
        #expect(shape(pointerItems(after[2].json)) == ["move(5,5,0ms)", "down", "pause(1000ms)", "up"])
        #expect(await client.sessionGeneration == 2)
    }

    @Test func lostSessionRetriesReadsOnce() async throws {
        let fake = FakeWDA()
        let client = fake.client()
        _ = try await client.screenshot()
        fake.killSession("S1")
        let shot = try await client.screenshot()
        #expect(shot.sessionId == "S2")
        #expect(fake.requests("GET", suffix: "/screenshot").map(\.path) ==
            ["/session/S1/screenshot", "/session/S1/screenshot", "/session/S2/screenshot"])
    }

    @Test func rebuildDeletesTheOldSession() async throws {
        let fake = FakeWDA()
        let client = fake.client()
        try await client.ensureSession()
        let fresh = try await client.rebuildSession()
        #expect(fresh == "S2")
        #expect(fake.requests("DELETE", suffix: "/session/S1").count == 1)
    }

    @Test func adoptsTheRunnerSessionWhenAsked() async throws {
        let fake = FakeWDA()
        fake.override("GET", "/status", .json(200, ["value": ["ready": true], "sessionId": "RUNNER"]))
        let client = fake.client(adopt: true)
        #expect(try await client.ensureSession() == "RUNNER")
        #expect(fake.requests("POST", suffix: "/session").isEmpty)
    }

    @Test func elementFromAnOldSessionIsRefused() async throws {
        let fake = FakeWDA()
        let client = fake.client()
        let element = try await client.findElement(.accessibilityId("General"))
        try await client.rebuildSession()
        let error = await expectWDAError { try await client.click(element) }
        #expect(error?.kind == .elementNotFound)
        #expect(error?.delivery == .notSent)
        #expect(fake.requests("POST", suffix: "/click").isEmpty)
    }
}

@Suite struct WDATimeoutTests {
    @Test func hangingActionTimesOutWithUnknownDelivery() async throws {
        let fake = FakeWDA()
        fake.override("POST", "/actions", .hang)
        let client = fake.client(timeout: .milliseconds(200))
        let error = await expectWDAError { try await client.tap(WDAPoint(x: 1, y: 1)) }
        #expect(error?.kind == .timeout)
        #expect(error?.delivery == .unknown)  // may have run: never replay
        // The 200 ms timeout applied, not the 30 s default. Read off the
        // request, not the wall clock: with one cooperative thread shared by
        // the whole suite (LIBDISPATCH_COOPERATIVE_POOL_STRICT=1) the timeout
        // can be reported seconds late, which a time bound mistook for a bug.
        let sent = fake.requests("POST", suffix: "/actions")
        #expect(sent.count == 1)
        #expect(sent.allSatisfy { abs($0.timeout - 0.2) < 0.001 })
    }

    @Test func deadlineShortensTheRequestTimeout() async throws {
        let fake = FakeWDA()
        fake.override("GET", "/screenshot", .hang)
        let client = fake.client(timeout: .seconds(30))
        try await client.ensureSession()
        let started = ContinuousClock.now
        let error = await expectWDAError {
            try await client.screenshot(deadline: .now + .milliseconds(200))
        }
        #expect(error?.kind == .timeout)
        #expect(error?.delivery == .rejected)  // a read has no effect to be unsure about
        #expect(ContinuousClock.now - started < .seconds(3))
    }

    @Test func passedDeadlineSendsNothing() async throws {
        let fake = FakeWDA()
        let client = fake.client()
        let error = await expectWDAError {
            try await client.home(deadline: .now - .milliseconds(1))
        }
        #expect(error?.kind == .timeout)
        #expect(error?.delivery == .notSent)
        #expect(fake.requests.isEmpty)
    }

    @Test func urlSessionTimeoutMapsToTimeout() async throws {
        let fake = FakeWDA()
        fake.override("POST", "/wda/keys", .fail(.timedOut))
        let client = fake.client()
        let error = await expectWDAError { try await client.typeText("hi") }
        #expect(error?.kind == .timeout)
        #expect(error?.delivery == .unknown)
    }
}

@Suite struct WDATextTests {
    static let text = "你好，世界！Café 👍🏽 👨‍👩‍👧 🇨🇳"

    @Test func unicodeTextGoesOutAsGraphemesInUTF8() async throws {
        let fake = FakeWDA()
        let client = fake.client()
        let evidence = try await client.typeText(Self.text)
        let request = try #require(fake.requests("POST", suffix: "/wda/keys").first)
        let body = try #require(request.body)
        #expect(String(data: body, encoding: .utf8) != nil)
        let value = try #require(request.json?["value"] as? [String])
        #expect(value == Self.text.map(String.init))
        #expect(value.joined() == Self.text)
        #expect(value.contains("👨‍👩‍👧"))  // ZWJ family is one item
        #expect(value.contains("🇨🇳"))
        #expect(value.contains("👍🏽"))
        #expect(evidence.delivery == .accepted)
        #expect(evidence.effect == .notVerifiedByClient)
    }

    @Test func elementValueCarriesTextAndCharacters() async throws {
        let fake = FakeWDA()
        let client = fake.client()
        let field = try await client.findElement(.classChain("**/XCUIElementTypeTextField"))
        _ = try await client.typeText("中文输入", into: field)
        let request = try #require(fake.requests("POST", suffix: "/element/E1/value").first)
        #expect(request.json?["text"] as? String == "中文输入")
        #expect(request.json?["value"] as? [String] == ["中", "文", "输", "入"])
    }

    @Test func lineBreaksAreRefusedUnlessAllowed() async throws {
        let fake = FakeWDA()
        let client = fake.client()
        let error = await expectWDAError { try await client.typeText("发送\n") }
        #expect(error?.kind == .invalidArgument)
        #expect(error?.delivery == .notSent)
        #expect(fake.requests.isEmpty)
        _ = try await client.typeText("第一行\n第二行", allowLineBreaks: true)
        #expect(fake.requests("POST", suffix: "/wda/keys").count == 1)
    }
}

@Suite struct WDAErrorClassificationTests {
    @Test func refusedConnectionIsUnreachableAndNotSent() async throws {
        let fake = FakeWDA()
        fake.override("GET", "/status", .fail(.cannotConnectToHost))
        let error = await expectWDAError { try await fake.client().status() }
        #expect(error?.kind == .runnerUnreachable)
        #expect(error?.delivery == .notSent)
    }

    @Test func droppedConnectionDuringActionIsUnknown() async throws {
        let fake = FakeWDA()
        fake.override("POST", "/wda/homescreen", .fail(.networkConnectionLost))
        let error = await expectWDAError { try await fake.client().home() }
        #expect(error?.kind == .runnerUnreachable)
        #expect(error?.delivery == .unknown)
    }

    @Test func missingElementIsElementNotFound() async throws {
        let fake = FakeWDA()
        let error = await expectWDAError {
            try await fake.client().findElement(.accessibilityId("missing"))
        }
        #expect(error?.kind == .elementNotFound)
        #expect(error?.wdaErrorCode == "no such element")
        #expect(error?.httpStatus == 404)
    }

    @Test func unknownRouteIsUnsupportedEndpoint() async throws {
        let fake = FakeWDA()
        fake.override("POST", "/wda/apps/launch",
                      .json(404, ["value": ["error": "unknown command", "message": "Unhandled endpoint"]]))
        let error = await expectWDAError {
            try await fake.client().launchApp(bundleId: "com.apple.Preferences")
        }
        #expect(error?.kind == .unsupportedEndpoint)
        #expect(error?.delivery == .rejected)
    }

    @Test func unclassifiedErrorDuringActionIsUnknown() async throws {
        let fake = FakeWDA()
        fake.override("POST", "/actions",
                      .json(500, ["value": ["error": "unknown error", "message": "XCTest failed mid-gesture"]]))
        let error = await expectWDAError { try await fake.client().tap(WDAPoint(x: 1, y: 1)) }
        #expect(error?.kind == .wdaRejected)
        #expect(error?.delivery == .unknown)
    }

    @Test func legacyStatusSixIsSessionInvalid() async throws {
        let fake = FakeWDA()
        let client = fake.client()
        try await client.ensureSession()
        fake.override("POST", "/wda/keys", .json(200, ["status": 6, "value": "Session does not exist"]))
        let error = await expectWDAError { try await client.typeText("a") }
        #expect(error?.kind == .sessionInvalid)
        #expect(await client.currentSessionId == nil)
    }

    @Test func nonJSONAnswerIsInvalidResponse() async throws {
        let fake = FakeWDA()
        fake.override("GET", "/status", .raw(200, Data("<html>proxy</html>".utf8)))
        let error = await expectWDAError { try await fake.client().status() }
        #expect(error?.kind == .invalidResponse)
    }
}

@Suite struct WDACommandTests {
    @Test func statusIsParsed() async throws {
        let status = try await FakeWDA().client().status()
        #expect(status.ready)
        #expect(status.wdaVersion == "9.0.0")
        #expect(status.osVersion == "18.6")
        #expect(status.deviceIP == "192.168.1.20")
        #expect(status.runnerSessionId == nil)
    }

    @Test func launchAndHomeUseWDARoutes() async throws {
        let fake = FakeWDA()
        let client = fake.client()
        let launch = try await client.launchApp(bundleId: "com.tencent.xin", arguments: ["-x"])
        let home = try await client.home()
        let body = fake.requests("POST", suffix: "/wda/apps/launch").first?.json
        #expect(body?["bundleId"] as? String == "com.tencent.xin")
        #expect(body?["arguments"] as? [String] == ["-x"])
        #expect(fake.requests("POST", suffix: "/wda/homescreen").first?.path == "/wda/homescreen")
        #expect(launch.operation == "launchApp" && home.operation == "home")
        #expect(home.delivery == .accepted && home.effect == .notVerifiedByClient)
    }

    @Test func observationCarriesGeometry() async throws {
        let fake = FakeWDA()
        let client = fake.client(udid: "00008110-000A1B2C3D4E5F60")
        let seen = try await client.observe()
        #expect(seen.imagePixelSize == IOSPixelSize(width: 1170, height: 2532))
        #expect(seen.contentRect == IOSRect(x: 0, y: 0, width: 390, height: 844))
        #expect(seen.screenScale == 3)
        #expect(seen.orientation == "PORTRAIT")
        #expect(seen.targetId == "ios:wda:00008110-000A1B2C3D4E5F60")
        #expect(seen.backendSessionId == "S1")
        fake.screenshotSize = (2532, 1170)
        let rotated = try await client.observe()
        #expect(rotated.geometryVersion != seen.geometryVersion)
    }
}

@Suite struct WDAProbeTests {
    @Test func readyRunnerReportsPerCapability() async throws {
        let fake = FakeWDA()
        let client = fake.client(udid: "UDID-1")
        try await client.ensureSession()
        let report = await client.probe()
        #expect(report.runnerReady)
        #expect(report.target == IOSTarget(targetId: "ios:wda:UDID-1", kind: "ios", backend: "wda",
                                           deviceIdentity: "UDID-1", identityConfidence: "configured_udid"))
        #expect(report.capability(.screenshot)?.state == .supported)
        #expect(report.capability(.elementTree)?.state == .supported)
        for name in [IOSCapabilityName.tap, .swipe, .drag, .longPress, .appLaunch, .unicodeText, .home] {
            #expect(report.capability(name)?.state == .unverified, "\(name)")
        }
        #expect(report.capability(.audio)?.state == .unsupported)
        #expect(report.capability(.tap)?.version == "wda 9.0.0 / iOS 18.6")
        #expect(report.observation?.imagePixelSize == IOSPixelSize(width: 1170, height: 2532))
        #expect(report.observationState == .supported)
        #expect(fake.requests("POST", suffix: "/session").count == 1)  // only ensureSession's
        let effects = report.hostEffects
        #expect(!effects.usesPhysicalPointer && !effects.mayTemporarilyActivateApp)
        #expect(!effects.borrowsHostFocus && !effects.usesHostClipboard)
        #expect(Set(report.capabilities.map(\.name)) == Set(IOSCapabilityName.allCases))
    }

    @Test func probeNeverSendsInput() async throws {
        let fake = FakeWDA()
        let client = fake.client()
        try await client.ensureSession()
        _ = await client.probe()
        let paths = fake.requests.map { "\($0.method) \($0.path)" }
        #expect(paths.filter { $0 == "POST /session" }.count == 1)
        #expect(!paths.contains { $0.hasSuffix("/wda/keys") || $0.hasSuffix("/wda/homescreen")
                || $0.hasSuffix("/apps/launch") || $0.hasSuffix("/value") || $0.hasSuffix("/click") })
        for request in fake.requests("POST", suffix: "/actions") {
            #expect((request.json?["actions"] as? [Any])?.isEmpty == true)
        }
    }

    @Test func deviceAcceptanceUpgradesToSupported() async throws {
        let fake = FakeWDA()
        let client = fake.client()
        try await client.ensureSession()
        let report = await client.probe(acceptedOnDevice: [.swipe: "I12 PASS (example)"])
        #expect(report.capability(.swipe)?.state == .supported)
        #expect(report.capability(.swipe)?.evidence.contains { $0.contains("I12 PASS") } == true)
        #expect(report.capability(.tap)?.state == .unverified)
        #expect(report.target.identityConfidence == "runner_endpoint")
    }

    @Test func missingActionsRouteIsUnsupported() async throws {
        let fake = FakeWDA()
        fake.override("POST", "/actions", .json(404, ["value": ["error": "unknown command", "message": "no route"]]))
        let client = fake.client()
        try await client.ensureSession()
        let report = await client.probe(acceptedOnDevice: [.tap: "would not matter"])
        #expect(report.capability(.tap)?.state == .unsupported)
        #expect(report.capability(.swipe)?.state == .unsupported)
    }

    @Test func unreachableRunnerVerifiesNothing() async throws {
        let fake = FakeWDA()
        fake.override("GET", "/status", .fail(.cannotConnectToHost))
        let report = await fake.client().probe()
        #expect(!report.runnerReady)
        #expect(report.observation == nil)
        #expect(report.capabilities.filter { $0.name != .audio }.allSatisfy { $0.state == .unverified })
        #expect(report.capability(.tap)?.evidence.first?.contains("runnerUnreachable") == true)
        #expect(fake.requests.count == 1)
    }

    @Test func reportEncodesAsJSON() async throws {
        let report = await FakeWDA().client().probe()
        let data = try JSONEncoder().encode(report)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["hostEffects"] != nil)
        #expect(object?["capabilities"] is [Any])
    }
}

/// Review follow-ups on PR #56: probe without session creation, POST /session
/// delivery, per-waiter deadlines, one-session observations, screenshot vs
/// geometry in the probe.
@Suite struct WDAReviewFollowUpTests {
    static let launching: [String: WDAJSONValue] = ["bundleId": .string("com.apple.Preferences")]

    // 1. probe() never creates a session.

    @Test func probeWithoutSessionCreatesNone() async throws {
        let fake = FakeWDA()
        let client = fake.client(capabilities: Self.launching)
        let report = await client.probe()
        #expect(report.runnerReady)
        #expect(fake.requests("POST", suffix: "/session").isEmpty)
        #expect(!fake.requests.contains { $0.path.hasPrefix("/session") })
        #expect(await client.currentSessionId == nil)
        for name in [IOSCapabilityName.screenshot, .elementTree, .tap, .swipe, .drag, .longPress] {
            #expect(report.capability(name)?.state == .unverified, "\(name)")
            #expect(report.capability(name)?.evidence.contains { $0.contains("noSession") } == true, "\(name)")
        }
        #expect(report.observation == nil)
        #expect(report.observationState == .unverified)
        #expect(report.capability(.appLaunch)?.state == .unverified)  // activeAppInfo needs no session
    }

    @Test func probeAdoptsTheRunnerSessionWhenConfigured() async throws {
        let fake = FakeWDA()
        fake.override("GET", "/status", .json(200, ["value": ["ready": true], "sessionId": "RUNNER"]))
        fake.addSession("RUNNER")
        let client = fake.client(adopt: true, capabilities: Self.launching)
        let report = await client.probe()
        #expect(fake.requests("POST", suffix: "/session").isEmpty)
        #expect(report.capability(.screenshot)?.state == .supported)
        #expect(report.observation?.backendSessionId == "RUNNER")
    }

    @Test func probeDoesNotReplaceAnInvalidSession() async throws {
        let fake = FakeWDA()
        let client = fake.client(capabilities: Self.launching)
        try await client.ensureSession()
        fake.killSession("S1")
        let report = await client.probe()
        #expect(fake.requests("POST", suffix: "/session").count == 1)
        #expect(report.capability(.screenshot)?.state == .unverified)
        #expect(report.observation == nil)
        #expect(await client.currentSessionId == nil)
    }

    // 2. POST /session counts as a command that may have run.

    @Test func lostSessionCreateAnswerIsUnknown() async throws {
        let fake = FakeWDA()
        fake.override("POST", "/session", .fail(.networkConnectionLost))
        let client = fake.client(capabilities: Self.launching)
        let error = await expectWDAError { try await client.ensureSession() }
        #expect(error?.kind == .runnerUnreachable)
        #expect(error?.delivery == .unknown)
        #expect(error?.endpoint == "POST /session")
    }

    @Test func hangingSessionCreateIsUnknown() async throws {
        let fake = FakeWDA()
        fake.override("POST", "/session", .hang)
        let client = fake.client(timeout: .milliseconds(200), capabilities: Self.launching)
        let error = await expectWDAError { try await client.screenshot() }
        #expect(error?.kind == .timeout)
        #expect(error?.delivery == .unknown)
    }

    @Test func refusedSessionCreateIsNotSent() async throws {
        let fake = FakeWDA()
        fake.override("POST", "/session", .fail(.cannotConnectToHost))
        let client = fake.client(capabilities: Self.launching)
        let error = await expectWDAError { try await client.ensureSession() }
        #expect(error?.delivery == .notSent)
    }

    // 3. Each waiter on a session creation keeps its own deadline.

    @Test func shortDeadlineDoesNotLeakToAnotherWaiter() async throws {
        let fake = FakeWDA()
        let gate = WDAReplyGate()
        defer { gate.release() }
        fake.override("POST", "/session", .held(gate, .json(200, ["value": ["sessionId": "S1"], "sessionId": "S1"])))
        fake.addSession("S1")
        let client = fake.client(timeout: .seconds(30))
        let patient = Task { try await client.screenshot() }
        defer { patient.cancel() }
        for _ in 0..<200 where fake.requests("POST", suffix: "/session").isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fake.requests("POST", suffix: "/session").count == 1)
        let shortError = await expectWDAError {
            try await client.screenshot(deadline: .now + .milliseconds(100))
        }
        #expect(shortError?.kind == .timeout)
        #expect(await client.currentSessionId == nil, "the shared creation is still waiting at the barrier")
        // Timing out one waiter must not cancel or restart shared creation.
        gate.release()
        let shot = try await patient.value
        #expect(shot.sessionId == "S1")
        #expect(fake.requests("POST", suffix: "/session").count == 1)
    }

    @Test func waiterIsBoundedByItsOwnDeadline() async throws {
        let fake = FakeWDA()
        fake.override("POST", "/session", .hang)
        let client = fake.client(timeout: .seconds(2))
        let first = Task { try await client.ensureSession() }  // no deadline; bounded by the config
        try await Task.sleep(for: .milliseconds(50))
        let started = ContinuousClock.now
        let error = await expectWDAError { try await client.ensureSession(deadline: .now + .milliseconds(150)) }
        #expect(error?.kind == .timeout)
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(fake.requests("POST", suffix: "/session").count == 1)
        first.cancel()
    }

    // 4. An observation never mixes two sessions.

    @Test func sessionLostMidObservationRetakesTheWholeObservation() async throws {
        let fake = FakeWDA()
        let client = fake.client()
        var killed = false
        let lock = NSLock()
        fake.onRequest { [unowned fake] request in
            guard request.method == "GET", request.path.hasSuffix("/window/size") else { return }
            let first = lock.withLock { () -> Bool in defer { killed = true }; return !killed }
            if first { fake.killSession(request.path.split(separator: "/")[1].description) }
        }
        let seen = try await client.observe()
        #expect(seen.backendSessionId == "S2")
        #expect(fake.requests("GET", suffix: "/screenshot").map(\.path) ==
            ["/session/S1/screenshot", "/session/S2/screenshot"])
        for suffix in ["/wda/screen", "/orientation"] {
            #expect(fake.requests("GET", suffix: suffix).allSatisfy { $0.path.hasPrefix("/session/S2/") })
        }
    }

    @Test func repeatedSessionLossFailsTheObservation() async throws {
        let fake = FakeWDA()
        let client = fake.client()
        fake.onRequest { [unowned fake] request in
            guard request.method == "GET", request.path.hasSuffix("/orientation") else { return }
            fake.killSession(request.path.split(separator: "/")[1].description)
        }
        let error = await expectWDAError { try await client.observe() }
        #expect(error?.kind == .sessionInvalid)
        #expect(fake.requests("POST", suffix: "/session").count == 2)
    }

    // 5. A missing geometry route does not make screenshots unsupported.

    @Test func missingGeometryRouteLeavesScreenshotSupported() async throws {
        let fake = FakeWDA()
        fake.override("GET", "/wda/screen", .json(404, ["value": ["error": "unknown command", "message": "no route"]]))
        let client = fake.client()
        try await client.ensureSession()
        let report = await client.probe()
        #expect(report.capability(.screenshot)?.state == .supported)
        #expect(report.observation == nil)
        #expect(report.observationState == .unverified)
        #expect(report.observationEvidence.contains { $0.contains("wda/screen") })
    }

    @Test func geometryTimeoutKeepsTheDecodedScreenshot() async throws {
        let fake = FakeWDA()
        let geometry = ["value": ["width": 390, "height": 844], "sessionId": "S1"] as [String: Any]
        // The geometry never answers; the deadline is generous so that the
        // screenshot, which answers at once, is in hand well before it even
        // when the suite shares one cooperative thread.
        _ = geometry
        fake.override("GET", "/window/size", .hang)
        let client = fake.client()
        try await client.ensureSession()
        let report = await client.probe(deadline: .now + .seconds(5))
        #expect(report.capability(.screenshot)?.state == .supported)
        #expect(report.capability(.screenshot)?.evidence.contains { $0.contains("decoded PNG 1170x2532") } == true)
        #expect(report.observation == nil)
        #expect(report.observationState == .unverified)
        #expect(report.observationEvidence.contains { $0.contains("window/size") })
        // The screenshot is not fetched again with the spent deadline.
        #expect(fake.requests("GET", suffix: "/screenshot").count == 1)
    }

    @Test func missingScreenshotRouteIsUnsupported() async throws {
        let fake = FakeWDA()
        fake.override("GET", "/screenshot", .json(404, ["value": ["error": "unknown command", "message": "no route"]]))
        let client = fake.client()
        try await client.ensureSession()
        let report = await client.probe()
        #expect(report.capability(.screenshot)?.state == .unsupported)
        #expect(report.observationState == .unverified)
    }
}
