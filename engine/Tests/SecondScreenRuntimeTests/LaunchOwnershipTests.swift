import AppKit
import CoreGraphics
import Foundation
@testable import SecondScreenCore
import Testing
@testable import SecondScreenRuntime

// A launch owns only a process it can prove it created (a one-time token in
// the environment the kernel recorded). Refusals come before any window is
// moved or bound; after an open the foreground is handed back; only a
// proved process is ever quit. Every system call is scripted: no real app
// is started, moved or bound.

/// A system the test scripts.
final class ScriptedSystem: @unchecked Sendable {
    let lock = NSLock()
    var running: [pid_t: String] = [:]
    var environments: [pid_t: [String: String]] = [:]
    var bundles: [String: (id: String?, single: Bool)] = [:]
    /// What the open does, given the environment it was asked to pass.
    var onOpen: (ScriptedSystem, [String: String]) -> pid_t = { _, _ in 0 }
    var window: WindowInfo?
    var opened = 0, moves = 0
    var binds: [pid_t] = []
    var quitPIDs: [pid_t] = []
    var focusReturned: [(pid_t, pid_t)] = []
    /// The signed identity each bundle reports, and the verifications in force.
    var identities: [String: AppIdentity] = [:]
    var verifications: [VerifiedApp]? = nil   // nil: every identity on disk is verified

    var launching: AppLaunching {
        var l = AppLaunching(
            runningPIDs: { self.lock.withLock { Set(self.running.keys) } },
            processes: { id in self.lock.withLock { Set(self.running.filter { $0.value == id }.keys) } },
            bundleInfo: { url in self.lock.withLock { self.bundles[url.path] ?? (nil, false) } },
            frontmost: { 77 },
            open: { _, env in
                self.lock.withLock { self.opened += 1 }
                return .success(LaunchedProcess(pid: self.onOpen(self, env)))
            },
            environment: { pid in self.lock.withLock { self.environments[pid] } },
            bundleURL: { pid in
                self.lock.withLock {
                    guard let id = self.running[pid] else { return nil }
                    return self.bundles.first { $0.value.id == id }.map { URL(fileURLWithPath: $0.key) }
                }
            },
            returnFocus: { previous, opened in self.lock.withLock { self.focusReturned.append((previous, opened.pid)) } },
            quit: { opened in self.lock.withLock { self.quitPIDs.append(opened.pid); self.running[opened.pid] = nil } },
            canPlaceWindows: { true },
            firstWindow: { pid, _ in self.lock.withLock { self.window.map { WindowInfo(pid: pid, windowID: $0.windowID, appName: $0.appName, title: $0.title, frame: $0.frame) } } },
            move: { _, _, _ in self.lock.withLock { self.moves += 1 }; return true })
        l.bound = { pid in self.lock.withLock { self.binds.append(pid) } }
        l.identity = { url in
            self.lock.withLock {
                if let i = self.identities[url.path] { return i }
                guard let id = self.bundles[url.path]?.id ?? nil else { return nil }
                return AppIdentity(bundleId: id, teamId: "TEAM1", signingIdentifier: id, version: "1.0", build: "100")
            }
        }
        l.verified = {
            self.lock.withLock {
                if let v = self.verifications { return v }
                return self.bundles.compactMap { path, b in
                    guard let id = b.id else { return nil }
                    let identity = self.identities[path]
                        ?? AppIdentity(bundleId: id, teamId: "TEAM1", signingIdentifier: id, version: "1.0", build: "100")
                    return VerifiedApp(identity: identity, technique: "launch_token_env", verifiedOn: "2026-10-09")
                }
            }
        }
        return l
    }

    /// A process the user (or the system) started: no launch token.
    @discardableResult func userStarts(_ pid: pid_t, _ id: String = "com.apple.Notes") -> pid_t {
        lock.withLock { running[pid] = id; environments[pid] = ["HOME": "/Users/u"] }
        return pid
    }
    /// The process this launch created, with the environment it was given.
    func launchStarts(_ pid: pid_t, _ env: [String: String], _ id: String = "com.apple.Notes") -> pid_t {
        lock.withLock { running[pid] = id; environments[pid] = env.merging(["HOME": "/Users/u"]) { a, _ in a } }
        return pid
    }
}

/// An .app directory on disk (the launch checks the path exists).
func tempApp(_ sys: ScriptedSystem, id: String? = "com.apple.Notes", single: Bool = false) throws -> (URL, () -> Void) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("launch-\(UUID().uuidString)")
    let app = dir.appendingPathComponent("App.app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    sys.bundles[app.path] = (id, single)
    return (app, { try? FileManager.default.removeItem(at: dir) })
}

@MainActor
func launch(_ sys: ScriptedSystem, _ app: URL, newInstance: Bool = true) async -> (ControlResponse, AgentScreens) {
    let screens = AgentScreens()
    screens.launching = sys.launching
    let target = ScreenInfo(name: "agent-1", kind: .agent, displayID: 9, width: 800, height: 600, hiDPI: false,
                            frame: .init(CGRect(x: 0, y: 0, width: 800, height: 600)))
    return (await screens.launch(on: target, bundleID: nil, path: app.path, newInstance: newInstance, fill: false), screens)
}

/// Nothing of the user's was touched: no move, no binding, nothing quit.
@MainActor
func touchedNothing(_ sys: ScriptedSystem, _ screens: AgentScreens) -> Bool {
    sys.moves == 0 && sys.binds.isEmpty && screens.boundPIDs.isEmpty && sys.quitPIDs.isEmpty
}

@Test func theLaunchAlwaysAsksForANewInstanceWithoutActivatingAndCarriesTheToken() {
    let c = LaunchOwnership.configuration([LaunchOwnership.tokenVariable: "t1"])
    #expect(c.createsNewApplicationInstance)
    #expect(!c.activates)
    #expect(c.environment[LaunchOwnership.tokenVariable] == "t1")
}

// ① The user already has an instance: refused before opening, with or
// without newInstance (browsers and editors hand a new instance's request
// to the running one).
@MainActor
@Test func anAppTheUserHasOpenIsRefusedBeforeOpening() async throws {
    for newInstance in [false, true] {
        let sys = ScriptedSystem()
        let (app, cleanup) = try tempApp(sys)
        defer { cleanup() }
        sys.userStarts(100)
        sys.window = WindowInfo(pid: 100, windowID: 5, appName: "Notes", title: "", frame: .zero)
        let (r, screens) = await launch(sys, app, newInstance: newInstance)
        #expect(!r.ok)
        #expect(sys.opened == 0, "never opened")
        #expect(touchedNothing(sys, screens))
        #expect(sys.focusReturned.isEmpty, "nothing was opened, nothing to hand back")
    }
}

// ② The user starts the app while it opens, and the system hands back
// the user's process: it carries no token, so it is refused, untouched,
// and the foreground goes back.
@MainActor
@Test func aProcessTheUserStartedMeanwhileIsRefusedUntouched() async throws {
    let sys = ScriptedSystem()
    let (app, cleanup) = try tempApp(sys)
    defer { cleanup() }
    sys.onOpen = { s, _ in s.userStarts(500) }
    sys.window = WindowInfo(pid: 500, windowID: 5, appName: "Notes", title: "", frame: .zero)
    let (r, screens) = await launch(sys, app)
    #expect(!r.ok)
    #expect(touchedNothing(sys, screens))
    #expect(sys.focusReturned.map(\.0) == [77])
    #expect(sys.focusReturned.map(\.1) == [500], "focus watch is on the returned process only")
    // Our instance carries the token, but the user started one at the same
    // time: which window is whose is not certain, so nothing is moved.
    let both = ScriptedSystem()
    let (app2, cleanup2) = try tempApp(both)
    defer { cleanup2() }
    both.onOpen = { s, env in s.userStarts(500); return s.launchStarts(600, env) }
    let (r2, screens2) = await launch(both, app2)
    #expect(!r2.ok)
    #expect(touchedNothing(both, screens2))
}

// ③ The system reuses a process: no token, refused untouched. Apps that
// allow one instance, or have no bundle ID, are never opened.
@MainActor
@Test func aReusedProcessAndUnprovableAppsAreRefusedUntouched() async throws {
    let sys = ScriptedSystem()
    let (app, cleanup) = try tempApp(sys)
    defer { cleanup() }
    let other = sys.userStarts(100, "com.example.other")
    sys.onOpen = { _, _ in other }
    sys.window = WindowInfo(pid: other, windowID: 5, appName: "Other", title: "", frame: .zero)
    let (r, screens) = await launch(sys, app)
    #expect(!r.ok)
    #expect(touchedNothing(sys, screens))
    for (id, single) in [("com.example.one", true), (nil, false)] as [(String?, Bool)] {
        let s = ScriptedSystem()
        let (a, c) = try tempApp(s, id: id, single: single)
        defer { c() }
        let (r2, sc2) = await launch(s, a)
        #expect(!r2.ok)
        #expect(s.opened == 0)
        #expect(touchedNothing(s, sc2))
    }
}

// A process that claims the token through its own (later) environment is
// not believed: only what the kernel recorded counts, and a mismatch is a
// refusal.
@Test func aWrongTokenIsRefused() async throws {
    let sys = ScriptedSystem()
    let (app, cleanup) = try tempApp(sys)
    defer { cleanup() }
    sys.onOpen = { s, _ in s.launchStarts(700, [LaunchOwnership.tokenVariable: "someone-else"]) }
    let r = await LaunchOwnership.openOwnedProcess(app, newInstance: true, using: sys.launching, token: "mine")
    #expect(r.isRefused)
}

// b9's third review: an app not verified to carry the token is never
// opened (Apple's own apps, Google Chrome): no unowned window is left on
// the user's screen.
@MainActor
@Test func anAppNotVerifiedToProveALaunchIsNeverOpened() async throws {
    let sys = ScriptedSystem()
    let (app, cleanup) = try tempApp(sys)
    defer { cleanup() }
    sys.verifications = []
    sys.onOpen = { s, env in s.launchStarts(900, env) }
    let (r, screens) = await launch(sys, app)
    #expect(!r.ok)
    #expect(sys.opened == 0, "never opened")
    #expect(touchedNothing(sys, screens))
    #expect(sys.focusReturned.isEmpty)
    // The shipped list is empty until apps are verified one by one.
    #expect(LaunchOwnership.verifiedApps.isEmpty)
}

// Kevin's ruling: a verification holds only for the identity it was made
// on. A new version or build, another team, another signing identifier, or
// a signature that no longer verifies: refused before opening.
@MainActor
@Test func aVerificationHoldsOnlyForTheExactSignedBuild() async throws {
    let verifiedOn = AppIdentity(bundleId: "com.apple.Notes", teamId: "TEAM1", signingIdentifier: "com.apple.Notes",
                                 version: "1.0", build: "100", designatedRequirement: "anchor apple and identifier \"com.apple.Notes\"")
    var updated = verifiedOn; updated.build = "101"
    var newVersion = verifiedOn; newVersion.version = "2.0"
    var otherTeam = verifiedOn; otherTeam.teamId = "EVIL1"
    var otherSigner = verifiedOn; otherSigner.signingIdentifier = "com.example.repack"
    // Every field copied, re-signed by someone else: another designated requirement.
    var resigned = verifiedOn; resigned.designatedRequirement = "identifier \"com.apple.Notes\" and certificate leaf = H\"00\""
    for (onDisk, why) in [(updated, "build"), (newVersion, "version"), (otherTeam, "team"), (otherSigner, "signer"),
                          (resigned, "issuer")] as [(AppIdentity?, String)] + [(nil, "no valid signature")] {
        let sys = ScriptedSystem()
        let (app, cleanup) = try tempApp(sys)
        defer { cleanup() }
        sys.verifications = [VerifiedApp(identity: verifiedOn, technique: "launch_token_env", verifiedOn: "2026-10-09")]
        if let onDisk { sys.identities[app.path] = onDisk } else { sys.identities[app.path] = nil; sys.bundles[app.path] = ("com.apple.Notes", false) }
        if onDisk == nil {
            // An unreadable signature: the identity reader returns nil.
            var l = sys.launching
            l.identity = { _ in nil }
            let r = await LaunchOwnership.openOwnedProcess(app, newInstance: true, using: l)
            #expect(r.isRefused, "\(why)")
            #expect(sys.opened == 0, "\(why): never opened")
            continue
        }
        sys.onOpen = { s, env in s.launchStarts(900, env) }
        let (r, screens) = await launch(sys, app)
        #expect(!r.ok, "\(why)")
        #expect(sys.opened == 0, "\(why): never opened")
        #expect(touchedNothing(sys, screens), "\(why)")
    }
    // A verification made with another technique does not count either.
    let sys = ScriptedSystem()
    let (app, cleanup) = try tempApp(sys)
    defer { cleanup() }
    sys.verifications = [VerifiedApp(identity: verifiedOn, technique: "guess", verifiedOn: "2026-10-09")]
    sys.identities[app.path] = verifiedOn
    let (r, _) = await launch(sys, app)
    #expect(!r.ok)
    #expect(sys.opened == 0)
}

// Helper and XPC processes carry their own bundle IDs: they do not make
// the launch's process ambiguous.
@MainActor
@Test func helperProcessesOfTheLaunchedAppDoNotBlockIt() async throws {
    let sys = ScriptedSystem()
    let (app, cleanup) = try tempApp(sys)
    defer { cleanup() }
    sys.onOpen = { s, env in
        _ = s.launchStarts(951, env, "com.apple.Notes.helper")
        _ = s.launchStarts(952, env, "com.apple.Notes.xpc.render")
        return s.launchStarts(950, env)
    }
    sys.window = WindowInfo(pid: 950, windowID: 5, appName: "Notes", title: "", frame: CGRect(x: 10, y: 10, width: 100, height: 100))
    _ = await launch(sys, app)
    #expect(sys.binds == [950])
}

// An app that restarts itself into another process: the launch's own
// process is quit, the other (not proved) is left alone, and the error says
// so instead of reporting a plain timeout.
@MainActor
@Test func anAppThatRestartsIntoAnotherProcessIsReportedAndOnlyItsOwnProcessQuit() async throws {
    let sys = ScriptedSystem()
    let (app, cleanup) = try tempApp(sys)
    defer { cleanup() }
    sys.onOpen = { s, env in s.launchStarts(960, env) }
    var l = sys.launching
    l.firstWindow = { pid, _ in
        // The launched process hands over to a fresh one and shows nothing.
        sys.lock.withLock { sys.running[961] = "com.apple.Notes"; sys.environments[961] = ["HOME": "/Users/u"] }
        return nil
    }
    let screens = AgentScreens()
    screens.launching = l
    let target = ScreenInfo(name: "agent-1", kind: .agent, displayID: 9, width: 800, height: 600, hiDPI: false,
                            frame: .init(CGRect(x: 0, y: 0, width: 800, height: 600)))
    let r = await screens.launch(on: target, bundleID: nil, path: app.path, newInstance: true, fill: false)
    #expect(!r.ok)
    #expect(r.error?.contains("another process") == true, "\(r.error ?? "")")
    #expect(sys.quitPIDs == [960], "only the proved process")
    #expect(sys.running[961] != nil, "the other is left alone")
    #expect(sys.moves == 0 && sys.binds.isEmpty)
}

@Test func theOpenAddsNoRecentItemAndNeverPrompts() {
    let c = LaunchOwnership.configuration()
    #expect(!c.addsToRecentItems)
    #expect(!c.promptsUserIfNeeded)
}

// ④ A process proved by the token is moved and bound.
@MainActor
@Test func aProvedNewProcessIsMovedAndBound() async throws {
    let sys = ScriptedSystem()
    let (app, cleanup) = try tempApp(sys)
    defer { cleanup() }
    sys.userStarts(100, "com.example.other")
    sys.onOpen = { s, env in s.launchStarts(900, env) }
    sys.window = WindowInfo(pid: 900, windowID: 5, appName: "Notes", title: "", frame: CGRect(x: 10, y: 10, width: 100, height: 100))
    let (_, screens) = await launch(sys, app)
    #expect(sys.moves >= 1)
    #expect(sys.binds == [900])
    _ = screens
    #expect(sys.quitPIDs.isEmpty)
}

// Runtime bug found by 2ndscreen-42 (TextEdit with only its open panel): a
// proved process that shows no window is quit, and only it.
@MainActor
@Test func aProvedLaunchWithoutAWindowQuitsOnlyItsProcess() async throws {
    let sys = ScriptedSystem()
    let (app, cleanup) = try tempApp(sys)
    defer { cleanup() }
    let users = sys.userStarts(100, "com.example.other")
    sys.onOpen = { s, env in s.launchStarts(4100, env) }
    let (r, screens) = await launch(sys, app)
    #expect(!r.ok)
    #expect(sys.quitPIDs == [4100])
    #expect(sys.running[users] != nil)
    #expect(sys.moves == 0 && sys.binds.isEmpty && screens.boundPIDs.isEmpty)
}

@Test func theKernelEnvironmentIsParsedAndReadForThisProcess() {
    var b: [UInt8] = []
    var argc: Int32 = 2
    withUnsafeBytes(of: &argc) { b += $0 }
    b += Array("/Applications/X.app/Contents/MacOS/X".utf8) + [0, 0, 0, 0]
    b += Array("X".utf8) + [0] + Array("-psn".utf8) + [0]
    b += Array("HOME=/Users/u".utf8) + [0] + Array("\(LaunchOwnership.tokenVariable)=abc=d".utf8) + [0, 0, 0]
    let env = LaunchOwnership.parseProcArgs(b)
    #expect(env?["HOME"] == "/Users/u")
    #expect(env?[LaunchOwnership.tokenVariable] == "abc=d")
    #expect(env?["X"] == nil && env?["-psn"] == nil, "arguments are not environment")
    #expect(LaunchOwnership.parseProcArgs([1, 0]) == nil)
    // The real sysctl, on this test process.
    #expect(LaunchOwnership.kernelEnvironment(of: getpid())?["PATH"] != nil)
}

@Test func aProcessRunningBeforeTheLaunchIsNotNew() {
    let before: Set<pid_t> = [100, 200, 300]
    #expect(!LaunchOwnership.isNewProcess(200, runningBefore: before))
    #expect(LaunchOwnership.isNewProcess(400, runningBefore: before))
    #expect(!LaunchOwnership.isNewProcess(0, runningBefore: before))
}

extension Result where Failure == LaunchRefusal {
    var isRefused: Bool { if case .failure = self { return true } else { return false } }
}

// The real reader, on this machine: a signed system app has an identity;
// a bundle without a valid signature has none (and so is never opened).
@Test func theSignedIdentityIsReadFromTheBundleOnDisk() throws {
    let textEdit = try #require(AppIdentity.read(URL(fileURLWithPath: "/System/Applications/TextEdit.app")))
    #expect(textEdit.bundleId == "com.apple.TextEdit")
    #expect(textEdit.signingIdentifier == "com.apple.TextEdit")
    #expect(!textEdit.version.isEmpty && !textEdit.build.isEmpty)
    #expect(textEdit.designatedRequirement.contains("anchor apple"), "\(textEdit.designatedRequirement)")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("unsigned-\(UUID().uuidString)")
    let app = dir.appendingPathComponent("U.app/Contents")
    try FileManager.default.createDirectory(at: app.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try #"<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.u</string></dict></plist>"#
        .write(to: app.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
    #expect(AppIdentity.read(dir.appendingPathComponent("U.app")) == nil)
}

// Kevin: with no app verified, the refusal says "no app configured" and
// nothing is opened; with a list, an app outside it is "not verified".
@MainActor
@Test func theRefusalNamesItsReason() async throws {
    let none = ScriptedSystem()
    let (app, cleanup) = try tempApp(none)
    defer { cleanup() }
    none.verifications = []
    let (r1, _) = await launch(none, app)
    #expect(r1.reason == "no_launch_apps_configured")
    let other = ScriptedSystem()
    let (app2, cleanup2) = try tempApp(other)
    defer { cleanup2() }
    other.verifications = [VerifiedApp(identity: AppIdentity(bundleId: "com.example.other", teamId: "T", signingIdentifier: "x",
                                                             version: "1", build: "1"),
                                       technique: "launch_token_env", verifiedOn: "2026-10-09")]
    let (r2, _) = await launch(other, app2)
    #expect(r2.reason == "launch_not_verified")
    #expect(none.opened == 0 && other.opened == 0)
}

@Test func anUnreadableEnvironmentIsRefused() async throws {
    let sys = ScriptedSystem()
    let (app, cleanup) = try tempApp(sys)
    defer { cleanup() }
    sys.onOpen = { s, env in s.launchStarts(970, env) }
    var l = sys.launching
    l.environment = { _ in nil }
    #expect(await LaunchOwnership.openOwnedProcess(app, newInstance: true, using: l).isRefused)
}

@Test func aNegativeArgumentCountIsNotParsed() {
    var argc: Int32 = -3
    var b: [UInt8] = []
    withUnsafeBytes(of: &argc) { b += $0 }
    b += Array("/x".utf8) + [0, 0]
    #expect(LaunchOwnership.parseProcArgs(b) == nil)
}

// The real system, on this machine: an unverified app is refused before it
// is opened; no process of it appears. (Nothing is opened, so this is safe
// to run anywhere; it is skipped if the app is already running.)
@MainActor
@Test func aRealLaunchOfAnUnverifiedAppOpensNothing() async throws {
    let url = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
    guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").isEmpty else { return }
    var l = AppLaunching.system
    l.canPlaceWindows = { true }   // past the Accessibility check, to the launch rules
    let screens = AgentScreens()
    screens.launching = l
    let target = ScreenInfo(name: "agent-x", kind: .agent, displayID: 999_999, width: 800, height: 600, hiDPI: false,
                            frame: .init(CGRect(x: 0, y: 0, width: 800, height: 600)))
    let r = await screens.launch(on: target, bundleID: nil, path: url.path, newInstance: true, fill: false)
    #expect(!r.ok)
    #expect(r.reason == "no_launch_apps_configured", "\(r.error ?? "")")
    try await Task.sleep(nanoseconds: 1_000_000_000)
    #expect(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").isEmpty, "TextEdit was not opened")
}

// Ad-hoc signed code has no signer to pin (its requirement is only a
// hash): it has no identity, so it can never match a verification.
@Test func adHocSignedCodeHasNoIdentity() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("adhoc-\(UUID().uuidString)")
    let app = dir.appendingPathComponent("A.app")
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try #"<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.apple.TextEdit</string><key>CFBundleExecutable</key><string>A</string></dict></plist>"#
        .write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
    try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: app.appendingPathComponent("Contents/MacOS/A").path)
    let sign = Process()
    sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    sign.arguments = ["--force", "--sign", "-", app.path]
    sign.standardError = FileHandle.nullDevice
    try sign.run()
    defer { if sign.isRunning { sign.terminate() } }
    let deadline = ContinuousClock().now.advanced(by: .seconds(10))
    while sign.isRunning && ContinuousClock().now < deadline { Thread.sleep(forTimeInterval: 0.01) }
    try #require(!sign.isRunning, "codesign exceeded the bounded fixture deadline")
    #expect(sign.terminationStatus == 0)
    #expect(AppIdentity.read(app) == nil, "an ad-hoc copy claiming TextEdit's bundle ID has no identity")
}

// 42's review: every refusal names its reason; refusals after opening say
// the app was opened.
@MainActor
@Test func everyRefusalCarriesAReason() async throws {
    let running = ScriptedSystem()
    let (a1, c1) = try tempApp(running)
    defer { c1() }
    running.userStarts(100)
    #expect(await launch(running, a1).0.reason == "app_already_running")
    let single = ScriptedSystem()
    let (a2, c2) = try tempApp(single, single: true)
    defer { c2() }
    #expect(await launch(single, a2).0.reason == "launch_unprovable")
    let opened = ScriptedSystem()
    let (a3, c3) = try tempApp(opened)
    defer { c3() }
    opened.onOpen = { s, _ in s.userStarts(500) }
    let r = await launch(opened, a3).0
    #expect(r.reason == "launch_refused_after_open")
    #expect(r.error?.contains("the app was opened") == true)
}

// Kevin 2026-10-09: refused before opening, the open call failing, and a
// refusal after opening are three different outcomes. A failed open call is
// never reported as opened, and is not retried.
@MainActor
@Test func aFailedOpenCallIsNeitherOpenedNorRetried() async throws {
    let sys = ScriptedSystem()
    let (app, cleanup) = try tempApp(sys)
    defer { cleanup() }
    var l = sys.launching
    l.open = { _, _ in
        sys.lock.withLock { sys.opened += 1 }
        return .failure(CocoaError(.executableLoad))
    }
    let screens = AgentScreens()
    screens.launching = l
    let target = ScreenInfo(name: "agent-1", kind: .agent, displayID: 9, width: 800, height: 600, hiDPI: false,
                            frame: .init(CGRect(x: 0, y: 0, width: 800, height: 600)))
    let r = await screens.launch(on: target, bundleID: nil, path: app.path, newInstance: true, fill: false)
    #expect(!r.ok)
    #expect(r.reason == "launch_failed")
    #expect(r.error?.contains("was opened") == false, "not reported as opened: \(r.error ?? "")")
    #expect(sys.opened == 1, "tried once, never retried")
    #expect(sys.focusReturned.isEmpty && sys.moves == 0 && sys.binds.isEmpty && sys.quitPIDs.isEmpty)
}

@Test(arguments: ["target", "unchanged", "other", "restoreFailed"])
func failedOpenRestoresOnlyTheTargetForeground(scenario: String) async throws {
    let sys = ScriptedSystem()
    let (app, cleanup) = try tempApp(sys)
    defer { cleanup() }
    var l = sys.launching
    l.frontmost = { sys.lock.withLock {
        sys.opened == 0 || scenario == "unchanged" ? 77 : scenario == "other" ? 88 : 500
    } }
    l.open = { _, _ in
        sys.lock.withLock {
            sys.opened += 1
            sys.running[500] = sys.bundles[app.path]?.id
        }
        return .failure(CocoaError(.executableLoad))
    }
    l.restoreFocusOnce = { previous, expected in
        sys.lock.withLock { sys.focusReturned.append((previous, expected)) }
        return scenario != "restoreFailed"
    }
    let result = await LaunchOwnership.openOwnedProcess(app, newInstance: true, using: l)
    guard case let .failure(refusal) = result else { Issue.record("expected launch failure"); return }
    #expect(refusal.reason == "launch_failed")
    #expect(sys.opened == 1)
    #expect(sys.moves == 0 && sys.binds.isEmpty && sys.quitPIDs.isEmpty)
    if scenario == "target" || scenario == "restoreFailed" {
        #expect(sys.focusReturned.count == 1)
        #expect(sys.focusReturned.first?.0 == 77 && sys.focusReturned.first?.1 == 500)
        #expect(refusal.message.contains(scenario == "target" ? "was restored" : "not confirmed"))
    } else {
        #expect(sys.focusReturned.isEmpty)
    }
}
