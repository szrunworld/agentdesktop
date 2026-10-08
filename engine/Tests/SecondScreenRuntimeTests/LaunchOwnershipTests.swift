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
    var verified = true

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
        l.verifiedProvable = { _ in self.lock.withLock { self.verified } }
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
    sys.verified = false
    sys.onOpen = { s, env in s.launchStarts(900, env) }
    let (r, screens) = await launch(sys, app)
    #expect(!r.ok)
    #expect(sys.opened == 0, "never opened")
    #expect(touchedNothing(sys, screens))
    #expect(sys.focusReturned.isEmpty)
    // The shipped list is empty until apps are verified one by one.
    #expect(LaunchOwnership.verifiedApps.isEmpty)
    #expect(!AppLaunching.system.verifiedProvable("com.google.Chrome"))
    #expect(!AppLaunching.system.verifiedProvable("com.apple.Notes"))
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
