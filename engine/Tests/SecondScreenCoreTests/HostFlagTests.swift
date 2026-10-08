import Foundation
import Testing
@testable import SecondScreenCore

@Suite struct HostFlagTests {
    private func scratch() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("hostflag-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func anExpiredRaisingIsDropped() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let flag = HostFlag(url: directory.appendingPathComponent("flag"))
        try flag.raise("old", until: Date().addingTimeInterval(-1))
        #expect(flag.reason() == nil)
        #expect(!FileManager.default.fileExists(atPath: flag.url.path))
    }

    /// Codex on #127: a raising made between reading an expired record and
    /// dropping it stays, and the flag reads as up, not down.
    @Test func aRaisingMadeWhileDroppingAnExpiredOneIsSeen() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        var flag = HostFlag(url: directory.appendingPathComponent("flag"))
        try flag.raise("old", until: Date().addingTimeInterval(-1))
        let other = HostFlag(url: flag.url)
        flag.beforeDropping = { try? other.raise("new", until: Date().addingTimeInterval(60)) }
        #expect(flag.reason() == "new")
    }

    @Test func lowerIfStillLeavesANewerRaising() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let flag = HostFlag(url: directory.appendingPathComponent("flag"))
        try flag.raise("first")
        let first = try #require(flag.generation())
        try flag.raise("second")
        #expect(!flag.lower(ifStill: first))
        #expect(flag.reason() == "second")
        #expect(flag.lower(ifStill: try #require(flag.generation())))
        #expect(flag.reason() == nil)
    }
}
