import AgentDesktopProtocol
@testable import AgentDesktopService
import Foundation

/// #166 (Kevin 2026-10-10): when a bridge task has waited more than two
/// seconds to start, sample this test process once, to see what holds the
/// threads it is waiting for. Test-only: on with AGENTDESKTOP_BRIDGE_DIAG=1
/// and AGENTDESKTOP_BRIDGE_STACKS=1; the product has nothing of it.
///
/// It reads the bridge timelines (BridgeDiagnostics) from its own plain
/// thread, decides under its lock and samples with no lock held; `sample`
/// is a separate process. At most `maxCaptures` per process, `spacing`
/// apart, each stalled call once, so the watch cannot pile up work or wait
/// on what it watches.
final class BridgeStallWatch: @unchecked Sendable {
    struct Stall: Sendable, CustomStringConvertible {
        let label: String
        let call: UInt64
        let method: String
        /// Since the task was created (monotonic).
        let waitedNanos: UInt64

        var description: String {
            "\(label) call=\(call) method=\(method) waiting=\(String(format: "%.1f", Double(waitedNanos) / 1e9))s"
        }
    }

    let after: UInt64
    let spacing: UInt64
    let maxCaptures: Int
    private let now: @Sendable () -> UInt64
    private let capture: @Sendable (_ due: [Stall], _ waiting: [Stall], _ index: Int) -> Void
    private let lock = NSLock()
    private var sources: [(label: String, recorder: BridgeDiagnostics)] = []
    private var captured: Set<String> = []
    private var captures = 0
    private var lastCapture: UInt64?
    private var started = false

    init(after: TimeInterval = 2, spacing: TimeInterval = 3, maxCaptures: Int = 5,
         now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         capture: @escaping @Sendable (_ due: [Stall], _ waiting: [Stall], _ index: Int) -> Void) {
        self.after = UInt64(after * 1e9)
        self.spacing = UInt64(spacing * 1e9)
        self.maxCaptures = maxCaptures
        self.now = now
        self.capture = capture
    }

    func watch(_ recorder: BridgeDiagnostics, label: String) {
        lock.withLock { sources.append((label, recorder)) }
    }

    /// Every task created and not yet started, with how long it has waited.
    func waiting() -> [Stall] {
        let at = now()
        return lock.withLock { sources }.flatMap { source -> [Stall] in
            var created: [UInt64: (String, UInt64)] = [:]
            var startedCalls: Set<UInt64> = []
            for e in source.recorder.events {
                if e.stage == .taskCreated { created[e.call] = (e.method, e.uptimeNanos) }
                if e.stage == .taskStarted { startedCalls.insert(e.call) }
            }
            return created.filter { !startedCalls.contains($0.key) }.map { call, v in
                Stall(label: source.label, call: call, method: v.0, waitedNanos: at > v.1 ? at - v.1 : 0)
            }.sorted { $0.call < $1.call }
        }
    }

    /// One look: the stalls a capture is due for now, if any. Marks them,
    /// so each is captured once.
    func due() -> (stalls: [Stall], waiting: [Stall], index: Int)? {
        let waiting = waiting()
        let at = now()
        return lock.withLock { () -> ([Stall], [Stall], Int)? in
            guard captures < maxCaptures else { return nil }
            if let last = lastCapture, at < last + spacing { return nil }
            let fresh = waiting.filter { $0.waitedNanos > after && !captured.contains("\($0.label)#\($0.call)") }
            guard !fresh.isEmpty else { return nil }
            fresh.forEach { captured.insert("\($0.label)#\($0.call)") }
            captures += 1
            lastCapture = at
            return (fresh, waiting, captures)
        }
    }

    /// Looks every 100 ms on its own thread, from the first call on.
    func start() {
        let first = lock.withLock { () -> Bool in defer { started = true }; return !started }
        guard first else { return }
        let thread = Thread { [self] in
            while true {
                if let d = due() { capture(d.stalls, d.waiting, d.index) }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        thread.name = "agentdesktop.tests.bridge-stall-watch"
        thread.start()
    }

    /// The watch SingleEndpointTests use when asked: writes what was waiting
    /// and a one-second `sample` of this process to `directory`.
    static let shared: BridgeStallWatch? = { () -> BridgeStallWatch? in
        let env = ProcessInfo.processInfo.environment
        guard env["AGENTDESKTOP_BRIDGE_DIAG"] == "1", env["AGENTDESKTOP_BRIDGE_STACKS"] == "1" else { return nil }
        let directory = env["AGENTDESKTOP_BRIDGE_STACKS_DIR"] ?? NSTemporaryDirectory() + "adt-bridge-stalls-\(getpid())"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        FileHandle.standardError.write(Data("BRIDGE-STALL watching; captures go to \(directory)\n".utf8))
        return BridgeStallWatch { due, waiting, index in
            let base = directory + "/stall-\(index)"
            let header = ["captured at \(Timestamp.string(Date())) (uptime \(DispatchTime.now().uptimeNanoseconds / 1_000_000) ms)",
                          "stalled past 2 s:"] + due.map { "  \($0)" } + ["all bridge tasks not yet started:"] + waiting.map { "  \($0)" }
            try? header.joined(separator: "\n").appending("\n").write(toFile: base + ".txt", atomically: true, encoding: .utf8)
            let sample = Process()
            sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            sample.arguments = [String(getpid()), "1", "-file", base + ".sample.txt"]
            sample.standardOutput = FileHandle.nullDevice
            sample.standardError = FileHandle.nullDevice
            let ran = (try? sample.run()) != nil
            if ran { sample.waitUntilExit() }
            FileHandle.standardError.write(Data(
                "BRIDGE-STALL \(index): \(due.map(\.description).joined(separator: "; ")) -> \(base).txt\(ran ? ", .sample.txt" : " (sample could not run)")\n".utf8))
        }
    }()
}
