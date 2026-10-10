import Darwin
import Foundation

// Waits with a deadline for the engine tests (#183).
//
// The engine tests once stalled on CI with every thread parked, and nothing
// said which wait never returned. Each wait here has a limit; when it runs
// out, the evidence is taken first (what was awaited, at which stage, for how
// long, and a sample of this process's threads), and then the wait throws, so
// the test fails with that evidence instead of hanging the run. A timeout is
// never a pass. The limits are set far above the normal time (see each call
// site); reaching one is a failure to look into, not to raise.

/// A wait that ran out. Its description is what a failing test shows.
public struct WaitTimedOut: Error, CustomStringConvertible {
    public let what: String
    public let stage: String
    public let seconds: Double
    public let evidence: String

    public var description: String {
        "timed out after \(Self.format(seconds)) s waiting for \(what) (stage: \(stage)); evidence: \(evidence)"
    }

    static func format(_ seconds: Double) -> String { String(format: "%.1f", seconds) }
}

public enum Bounded {
    /// Where evidence goes: ENGINE_TEST_EVIDENCE_DIR (CI points it into the
    /// watchdog's uploaded directory), else a temporary directory.
    public static var evidenceDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["ENGINE_TEST_EVIDENCE_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("engine-test-evidence", isDirectory: true)
    }

    /// Takes the evidence for a wait that ran out: a note and a 3-second
    /// `sample` of this process, itself limited. Returns where it is, or why
    /// part of it could not be taken. (`sampler` is a seam for the
    /// self-tests.)
    static func collectEvidence(what: String, stage: String, seconds: Double,
                                sampler samplerPath: String = "/usr/bin/sample") -> String {
        let dir = evidenceDirectory
        let name = "wait-\(getpid())-\(UUID().uuidString.prefix(8))"
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return "none (could not create \(dir.path): \(error))"
        }
        let note = dir.appendingPathComponent("\(name).txt")
        let text = "waiting for: \(what)\nstage: \(stage)\nwaited: \(WaitTimedOut.format(seconds)) s\npid: \(getpid())\n"
        try? text.write(to: note, atomically: true, encoding: .utf8)
        let samplePath = dir.appendingPathComponent("\(name)-sample.txt")
        let sampler = Process()
        sampler.executableURL = URL(fileURLWithPath: samplerPath)
        sampler.arguments = [String(getpid()), "3", "-file", samplePath.path]
        sampler.standardOutput = FileHandle.nullDevice
        sampler.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        sampler.terminationHandler = { _ in done.signal() }
        // A sample that fails or overruns never replaces the timeout: the
        // test still fails for the wait, and the evidence says what went
        // wrong with collecting it.
        do { try sampler.run() } catch { return note.path + " (sample collection failed: could not run: \(error))" }
        // sample takes 3 s; 20 s is its limit, and a sampler that overruns
        // it is stopped (it is this test's own child, still unreaped).
        if done.wait(timeout: .now() + 20) == .timedOut {
            sampler.terminate()
            return note.path + " (sample collection failed: timed out after 20 s)"
        }
        guard sampler.terminationStatus == 0 else {
            return note.path + " (sample collection failed: exit \(sampler.terminationStatus))"
        }
        return note.path + ", " + samplePath.path
    }

    public static func timedOut(_ what: String, _ stage: String, _ seconds: Double,
                                sampler: String = "/usr/bin/sample") -> WaitTimedOut {
        WaitTimedOut(what: what, stage: stage, seconds: seconds,
                     evidence: collectEvidence(what: what, stage: stage, seconds: seconds, sampler: sampler))
    }

    /// Waits for `semaphore` at most `seconds`.
    public static func wait(_ semaphore: DispatchSemaphore, _ seconds: Double, for what: String, stage: String) throws {
        if semaphore.wait(timeout: .now() + seconds) == .timedOut {
            throw timedOut(what, stage, seconds)
        }
    }

    /// Waits at most `seconds` for everything already submitted to `queue`
    /// to have run (what `queue.sync {}` waits for, with a limit).
    public static func sync(_ queue: DispatchQueue, _ seconds: Double, for what: String, stage: String) throws {
        let reached = DispatchSemaphore(value: 0)
        queue.async { reached.signal() }
        try wait(reached, seconds, for: what, stage: stage)
    }
}
