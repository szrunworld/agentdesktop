import Foundation

/// Resources shared across Desktops. Two Desktops never send input to the
/// same process at once, even if both bound one of its windows.
final class ConflictRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var byPid: [Int32: NSLock] = [:]

    func withProcess<T>(_ pid: Int32, _ body: () throws -> T) rethrows -> T {
        let l = lock.withLock { () -> NSLock in
            if let l = byPid[pid] { return l }
            let l = NSLock()
            byPid[pid] = l
            return l
        }
        l.lock()
        defer { l.unlock() }
        return try body()
    }
}
