import Foundation
import Darwin
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
            $| = 1; print "locked\\n"; alarm 15; <STDIN>;
            """, url.path]
        let out = Pipe()
        let release = Pipe()
        holder.standardInput = release
        holder.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C", "LC_CTYPE": "C", "LANG": "C"]) { _, new in new }
        holder.standardOutput = out
        try holder.run()
        defer { if holder.isRunning { holder.terminate() } }
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        var received = Data()
        while !received.contains(10), ContinuousClock().now < deadline {
            var descriptor = pollfd(fd: out.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 100) >= 0 else { throw CocoaError(.fileReadUnknown) }
            if descriptor.revents & Int16(POLLIN | POLLHUP) != 0 {
                var bytes = [UInt8](repeating: 0, count: 64)
                let count = read(descriptor.fd, &bytes, bytes.count)
                guard count > 0 else { break }
                received.append(contentsOf: bytes.prefix(count))
            }
        }
        let line = String(data: received, encoding: .utf8)
        try #require(line == "locked\n", "holder did not confirm its lock before the bounded deadline")

        #expect(throws: ClipboardLease.LeaseError.busy(seconds: 0.2)) {
            try ClipboardLease.acquire(at: url, timeout: 0.2)
        }
        try release.fileHandleForWriting.write(contentsOf: Data("release\n".utf8))
        // Released when the holder exits, without it unlocking.
        let lease = try ClipboardLease.acquire(at: url, timeout: 10)
        lease.release()
        let exitDeadline = ContinuousClock().now.advanced(by: .seconds(5))
        while holder.isRunning && ContinuousClock().now < exitDeadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(!holder.isRunning, "holder exit exceeded the bounded deadline")
    }
}

@Test func aCancelledClipboardWaitRunsNoBody() throws {
    let url = scratchLockURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let first = try ClipboardLease.acquire(at: url, timeout: 1)
    defer { first.release() }
    var checks = 0
    var ran = false
    #expect(throws: ClipboardLease.LeaseError.gaveUp) {
        try ClipboardLease.with(at: url, timeout: 45, giveUp: { checks += 1; return checks >= 2 }) { ran = true }
    }
    #expect(!ran)
    #expect(checks == 2)
}
