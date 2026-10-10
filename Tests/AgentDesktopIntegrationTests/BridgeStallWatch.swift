import AgentDesktopProtocol
@testable import AgentDesktopService
import Darwin
import Foundation

/// #166 (Kevin 2026-10-10): when a bridge task has waited more than two
/// seconds to start, sample this test process once, to see what holds the
/// threads it is waiting for. Test-only: on with AGENTDESKTOP_BRIDGE_DIAG=1
/// and AGENTDESKTOP_BRIDGE_STACKS=1; the product has nothing of it.
///
/// It reads the bridge timelines (BridgeDiagnostics) incrementally from its
/// own plain thread, decides under its lock and samples with no lock held;
/// `sample` is a separate process, waited for at most `sampleLimit`. At most
/// `maxCaptures` per process, `spacing` apart, each stalled call once, so
/// the watch cannot pile up work or wait on what it watches.
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
    /// Per recorder: how many events were read, and the tasks created and
    /// not yet started (call -> method, created at).
    private final class Source {
        let label: String
        let recorder: BridgeDiagnostics
        var read = 0
        var pending: [UInt64: (method: String, createdAt: UInt64)] = [:]
        /// Started before their taskCreated was noted (Codex on d4ff0b6: the
        /// task can start before the connection thread notes its creation).
        var startedEarly: Set<UInt64> = []
        init(label: String, recorder: BridgeDiagnostics) { self.label = label; self.recorder = recorder }
    }
    private var sources: [Source] = []
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
        lock.withLock { sources.append(Source(label: label, recorder: recorder)) }
    }

    /// Every task created and not yet started, with how long it has waited.
    /// Reads only the events noted since the last look (b9 on bfbbb55).
    func waiting() -> [Stall] {
        let at = now()
        return lock.withLock { () -> [Stall] in
            sources.flatMap { source -> [Stall] in
                let new = source.recorder.events(after: source.read)
                source.read += new.count
                for e in new {
                    switch e.stage {
                    case .taskCreated:
                        if source.startedEarly.remove(e.call) == nil { source.pending[e.call] = (e.method, e.uptimeNanos) }
                    case .taskStarted:
                        if source.pending.removeValue(forKey: e.call) == nil { source.startedEarly.insert(e.call) }
                    default: break
                    }
                }
                return source.pending.map { call, v in
                    Stall(label: source.label, call: call, method: v.method, waitedNanos: at > v.createdAt ? at - v.createdAt : 0)
                }.sorted { $0.call < $1.call }
            }
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

    // MARK: Sampling

    enum SampleOutcome: Equatable, CustomStringConvertible {
        case captured
        /// Exited non-zero, or left no output; `reason` says which (and the
        /// first line it wrote to stderr).
        case failed(reason: String)
        /// Still running at the limit. `ended`: it was known to be the
        /// process this watch started, was asked to terminate and was seen to
        /// exit within two seconds (b9 on bb8c248: asking is not ending).
        case timedOut(ended: Bool)

        var description: String {
            switch self {
            case .captured: return "captured"
            case let .failed(reason): return "failed: \(reason)"
            case let .timedOut(ended): return "timed out (\(ended ? "terminated and exited" : "still running: not provably ours, or did not exit"))"
            }
        }
    }

    /// Runs `executable` with `arguments`, waiting at most `limit`, and says
    /// how it went; `output` must then exist and not be empty (Codex and b9
    /// on bfbbb55: a launch is not a capture).
    static func runSample(_ executable: String, _ arguments: [String], output: String, stderrFile: String,
                          limit: TimeInterval) -> SampleOutcome {
        // A reused directory may hold an earlier run's files: neither may
        // pass for this run's capture or its error (Codex on d4ff0b6).
        for stale in [output, stderrFile] where FileManager.default.fileExists(atPath: stale) {
            do { try FileManager.default.removeItem(atPath: stale) } catch { return .failed(reason: "cannot clear \(stale)") }
        }
        FileManager.default.createFile(atPath: stderrFile, contents: nil)
        guard let err = FileHandle(forWritingAtPath: stderrFile) else { return .failed(reason: "cannot write \(stderrFile)") }
        defer { try? err.close() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = err
        do { try p.run() } catch { return .failed(reason: "could not start: \(error.localizedDescription)") }
        // Monotonic: a clock set back or forward does not stretch or cut the
        // wait (Codex on 919e460).
        let deadline = DispatchTime.now() + limit
        while p.isRunning && DispatchTime.now() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning {
            // Only the process this watch started: its parent is this process
            // and its executable is the one launched.
            guard isChild(p.processIdentifier, running: executable) else { return .timedOut(ended: false) }
            p.terminate()
            let exitBy = DispatchTime.now() + 2
            while p.isRunning && DispatchTime.now() < exitBy { Thread.sleep(forTimeInterval: 0.05) }
            return .timedOut(ended: !p.isRunning)
        }
        let firstLine = (try? String(contentsOfFile: stderrFile, encoding: .utf8))?
            .split(separator: "\n").first.map(String.init) ?? ""
        guard p.terminationStatus == 0 else {
            return .failed(reason: "exit status \(p.terminationStatus)" + (firstLine.isEmpty ? "" : ": \(firstLine)"))
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: output)[.size] as? Int) ?? nil
        guard let size, size > 0 else {
            return .failed(reason: "no output at \(output)" + (firstLine.isEmpty ? "" : ": \(firstLine)"))
        }
        return .captured
    }

    /// Whether `pid` is a child of this process running `executable`.
    static func isChild(_ pid: Int32, running executable: String) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_ppid == UInt32(getpid()) else { return false }
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
        let actual = URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().path
        return actual == URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
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
            var header = ["captured at \(Timestamp.string(Date())) (uptime \(DispatchTime.now().uptimeNanoseconds / 1_000_000) ms)",
                          "stalled past 2 s:"] + due.map { "  \($0)" } + ["all bridge tasks not yet started:"] + waiting.map { "  \($0)" }
            let outcome = runSample("/usr/bin/sample", [String(getpid()), "1", "-file", base + ".sample.txt"],
                                    output: base + ".sample.txt", stderrFile: base + ".sample.err", limit: 1 + 10)
            header.append("sample: \(outcome)")
            try? header.joined(separator: "\n").appending("\n").write(toFile: base + ".txt", atomically: true, encoding: .utf8)
            FileHandle.standardError.write(Data(
                "BRIDGE-STALL \(index): \(due.map(\.description).joined(separator: "; ")) -> \(base).txt; sample \(outcome)\n".utf8))
        }
    }()
}
