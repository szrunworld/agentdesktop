import Foundation
import SecondScreenCore
import Testing
@testable import SecondScreenRuntime

// A launch owns only a process it provably created. Every refusal returns
// before AgentScreens.launch moves or binds a window (it only continues with
// an owned pid), so a refused launch leaves the user's windows where they are.

/// A system that the test scripts: who runs before, what the open returns,
/// and who appears meanwhile.
final class ScriptedSystem: @unchecked Sendable {
    let lock = NSLock()
    var running: [pid_t: String] = [:]
    var bundles: [String: (id: String?, single: Bool)] = ["/Apps/Notes.app": ("com.apple.Notes", false)]
    /// What the open does: returns a pid, and may add processes.
    var onOpen: (ScriptedSystem) -> pid_t = { _ in 0 }
    var opened = 0
    var quitPIDs: [pid_t] = []

    var launching: AppLaunching {
        AppLaunching(
            runningPIDs: { self.lock.withLock { Set(self.running.keys) } },
            processes: { id in self.lock.withLock { Set(self.running.filter { $0.value == id }.keys) } },
            bundleInfo: { url in self.lock.withLock { self.bundles[url.path] ?? (nil, false) } },
            open: { _ in
                self.lock.withLock { self.opened += 1 }
                return .success(self.onOpen(self))
            },
            bundleURL: { pid in
                self.lock.withLock {
                    guard let id = self.running[pid] else { return nil }
                    return self.bundles.first { $0.value.id == id }.map { URL(fileURLWithPath: $0.key) }
                }
            },
            quit: { pid in self.lock.withLock { self.quitPIDs.append(pid); self.running[pid] = nil } },
            canPlaceWindows: { true },
            firstWindow: { _, _ in nil })
    }

    func start(_ pid: pid_t, _ id: String = "com.apple.Notes") -> pid_t {
        lock.withLock { running[pid] = id }
        return pid
    }
}

let notes = URL(fileURLWithPath: "/Apps/Notes.app")

@Test func theLaunchAlwaysAsksForANewInstanceWithoutActivating() {
    let c = LaunchOwnership.configuration()
    #expect(c.createsNewApplicationInstance)
    #expect(!c.activates)
}

// ① The user already has an instance.
@Test func anAppTheUserHasOpenIsRefusedWithoutANewInstance() async {
    let sys = ScriptedSystem()
    _ = sys.start(100)
    let r = await LaunchOwnership.openOwnedProcess(notes, newInstance: false, using: sys.launching)
    #expect(r.isRefused)
    #expect(sys.opened == 0, "refused before opening anything")
}

// ② The user starts the same app while it opens.
@Test func anInstanceTheUserStartsMeanwhileMakesTheLaunchUnprovable() async {
    let sys = ScriptedSystem()
    sys.onOpen = { s in _ = s.start(500); return s.start(600) }   // the user's 500, ours 600
    let r = await LaunchOwnership.openOwnedProcess(notes, newInstance: true, using: sys.launching)
    // The launch asked for a new instance, so the system made 600 apart
    // from the user's 500; with two new processes neither is provably ours.
    #expect(r.isRefused)
}

// ③ The system reuses a process that was already running.
@Test func aProcessTheSystemReusesIsNotTheLaunchs() async {
    let sys = ScriptedSystem()
    let users = sys.start(100)
    sys.onOpen = { _ in users }
    let r = await LaunchOwnership.openOwnedProcess(notes, newInstance: true, using: sys.launching)
    #expect(r.isRefused)
    // Single-instance apps and apps without a bundle ID are never opened.
    sys.bundles["/Apps/One.app"] = ("com.example.one", true)
    let one = await LaunchOwnership.openOwnedProcess(URL(fileURLWithPath: "/Apps/One.app"), newInstance: true, using: sys.launching)
    let bare = await LaunchOwnership.openOwnedProcess(URL(fileURLWithPath: "/tmp/bare"), newInstance: true, using: sys.launching)
    #expect(one.isRefused && bare.isRefused)
    #expect(sys.opened == 1, "only the first case reached the open")
}

@Test func aNewProcessOfAnotherAppIsNotTheLaunchs() async {
    let sys = ScriptedSystem()
    sys.onOpen = { s in s.start(800, "com.example.other") }
    #expect(await LaunchOwnership.openOwnedProcess(notes, newInstance: true, using: sys.launching).isRefused)
}

// ④ A confirmed new process is the launch's.
@Test func theOnlyNewProcessOfTheAppIsTheLaunchs() async {
    let sys = ScriptedSystem()
    _ = sys.start(100)
    sys.onOpen = { s in s.start(900) }
    let r = await LaunchOwnership.openOwnedProcess(notes, newInstance: true, using: sys.launching)
    #expect(r == .success(900))
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

// Runtime bug found by 2ndscreen-42: an app that starts but shows no window
// (TextEdit with only its open panel) stayed on the user's display, owned by
// no Desktop. A launch that fails after it created the process quits it, and
// only it.
@MainActor
@Test func aLaunchWithoutAWindowQuitsTheProcessItStartedAndNothingElse() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("launch-\(UUID().uuidString)")
    let app = dir.appendingPathComponent("Notes.app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let sys = ScriptedSystem()
    sys.bundles = [app.path: ("com.apple.Notes", false)]
    let users = sys.start(100)
    sys.onOpen = { s in s.start(4100) }
    let screens = AgentScreens()
    screens.launching = sys.launching
    let target = ScreenInfo(name: "agent-1", kind: .agent, displayID: 9, width: 800, height: 600, hiDPI: false,
                            frame: .init(CGRect(x: 0, y: 0, width: 800, height: 600)))
    let r = await screens.launch(on: target, bundleID: nil, path: app.path, newInstance: true, fill: false)
    #expect(!r.ok)
    #expect(sys.quitPIDs == [4100], "only the process this launch created")
    #expect(sys.running[users] != nil, "the user's instance keeps running")
}

@MainActor
@Test func aRefusedLaunchQuitsNothing() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("launch-\(UUID().uuidString)")
    let app = dir.appendingPathComponent("Notes.app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let sys = ScriptedSystem()
    sys.bundles = [app.path: ("com.apple.Notes", false)]
    let users = sys.start(100)
    sys.onOpen = { _ in users }   // the system hands back the user's process
    let screens = AgentScreens()
    screens.launching = sys.launching
    let target = ScreenInfo(name: "agent-1", kind: .agent, displayID: 9, width: 800, height: 600, hiDPI: false,
                            frame: .init(CGRect(x: 0, y: 0, width: 800, height: 600)))
    let r = await screens.launch(on: target, bundleID: nil, path: app.path, newInstance: true, fill: false)
    #expect(!r.ok)
    #expect(sys.quitPIDs.isEmpty, "the user's app is neither moved nor quit")
}
