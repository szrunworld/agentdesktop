import Foundation
import Testing
@testable import SecondScreenCore

func scratchLockURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("agentdesktop-lease-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("clipboard.lock")
}

@Suite struct ClipboardLeaseTests {
    @Test func secondHolderWaitsThenTimesOut() throws {
        let url = scratchLockURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = try ClipboardLease.acquire(at: url, timeout: 1)
        let start = Date()
        #expect(throws: ClipboardLease.LeaseError.busy(seconds: 0.3)) {
            try ClipboardLease.acquire(at: url, timeout: 0.3)
        }
        #expect(Date().timeIntervalSince(start) >= 0.3)
        first.release()
        let second = try ClipboardLease.acquire(at: url, timeout: 0.3)
        second.release()
    }

    @Test func waitingHolderGetsItWhenReleased() throws {
        let url = scratchLockURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = try ClipboardLease.acquire(at: url, timeout: 1)
        // A thread of its own: under a full parallel run the shared pools can
        // be busy for seconds, which would turn this into a timeout.
        Thread {
            Thread.sleep(forTimeInterval: 0.2)
            first.release()
        }.start()
        let second = try ClipboardLease.acquire(at: url, timeout: 5)
        second.release()
    }

    @Test func lockFileIsPrivate() throws {
        let url = scratchLockURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try ClipboardLease.with(at: url, timeout: 1) {}
        let file = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((file[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let directory = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        #expect((directory[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func tightensALooseLockFile() throws {
        let url = scratchLockURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o666])
        try ClipboardLease.with(at: url, timeout: 1) {}
        let file = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((file[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    /// Another process holding the lock (as another `agentdesktop` CLI would)
    /// keeps this one out until it exits.
    @Test func excludesOtherProcesses() throws {
        let url = scratchLockURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try ClipboardLease.with(at: url, timeout: 1) {}  // creates the file

        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        holder.arguments = ["-e", """
            use Fcntl qw(:flock); open(F, "+<", $ARGV[0]) or die; flock(F, LOCK_EX) or die;
            $| = 1; print "locked\\n"; sleep 1;
            """, url.path]
        let out = Pipe()
        holder.standardOutput = out
        try holder.run()
        defer { if holder.isRunning { holder.terminate() } }
        let line = String(data: out.fileHandleForReading.availableData, encoding: .utf8)
        #expect(line == "locked\n")

        #expect(throws: ClipboardLease.LeaseError.busy(seconds: 0.2)) {
            try ClipboardLease.acquire(at: url, timeout: 0.2)
        }
        // Released when the holder exits, without it unlocking.
        let lease = try ClipboardLease.acquire(at: url, timeout: 10)
        lease.release()
        holder.waitUntilExit()
    }
}
