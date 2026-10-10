import Foundation
import Darwin

/// Temporary directories this test process made, removed when it exits:
/// test runs used to leave tens of thousands behind in the temp folder.
enum ScratchDirectory {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var made: [(URL, dev_t, ino_t)] = []
    private static let registered: Void = { atexit { ScratchDirectory.removeAll() } }()

    /// A new directory whose identity is recorded before it is returned.
    static func url(_ prefix: String) -> URL {
        _ = registered
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { preconditionFailure("cannot create scratch directory: \(error)") }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            preconditionFailure("cannot identify scratch directory")
        }
        lock.lock(); made.append((url, info.st_dev, info.st_ino)); lock.unlock()
        return url
    }

    static func removeAll() {
        lock.lock(); let all = made; made = []; lock.unlock()
        for (url, device, inode) in all {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == getuid(), info.st_dev == device, info.st_ino == inode else {
                fputs("scratch cleanup skipped changed directory identity\n", stderr)
                continue
            }
            try? FileManager.default.removeItem(at: url)
        }
    }
}
