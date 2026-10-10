import Foundation

/// Temporary directories this test process made, removed when it exits:
/// test runs used to leave tens of thousands behind in the temp folder.
enum ScratchDirectory {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var made: [URL] = []
    private static let registered: Void = { atexit { ScratchDirectory.removeAll() } }()

    /// A new path "<prefix>-<uuid>" in the temp folder (not yet created).
    static func url(_ prefix: String) -> URL {
        _ = registered
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        lock.lock(); made.append(url); lock.unlock()
        return url
    }

    static func removeAll() {
        lock.lock(); let all = made; made = []; lock.unlock()
        for url in all { try? FileManager.default.removeItem(at: url) }
    }
}
