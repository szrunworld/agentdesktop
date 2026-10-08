import Foundation

/// Accessibility reads, isolated (plan A3, RT-23A/B; MAC-001). An AX call
/// cannot be interrupted, and a slow app can hold one for its full timeout,
/// so reads never run on the main thread, the Swift cooperative pool or with
/// a Desktop's lock held. They run on a small set of dedicated threads; each
/// Desktop has at most one read in flight; a caller waits only until its
/// deadline and then goes on with what it has, while a read that is still
/// running finishes on its own (the backend stops reading new nodes past
/// the deadline, so it ends soon after).
public final class AXReader: @unchecked Sendable {
    public enum Outcome {
        case read(ElementRead)
        case failed(Error)
        /// The deadline passed before the read returned.
        case timedOut
        /// A read of this Desktop is still running, or every AX thread is
        /// busy: none was started.
        case busy
    }

    /// AX threads in the whole Runtime.
    public let capacity: Int
    private let lock = NSLock()
    private var running = 0
    private var inFlight: Set<String> = []

    public init(capacity: Int = 4) {
        self.capacity = capacity
    }

    /// Reads currently running, timed out or not.
    public var activeReads: Int { lock.withLock { running } }

    public func read(desktopId: String, deadline: Date, _ work: @escaping @Sendable () throws -> ElementRead) -> Outcome {
        let admitted: Bool = lock.withLock {
            guard running < capacity, !inFlight.contains(desktopId) else { return false }
            running += 1
            inFlight.insert(desktopId)
            return true
        }
        guard admitted else { return .busy }
        final class Box: @unchecked Sendable { var outcome: Outcome = .timedOut }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let outcome: Outcome
            do { outcome = .read(try work()) } catch { outcome = .failed(error) }
            lock.withLock {
                box.outcome = outcome
                running -= 1
                inFlight.remove(desktopId)
            }
            done.signal()
        }
        thread.name = "agentdesktop.ax.\(desktopId)"
        thread.start()
        guard done.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .success else { return .timedOut }
        return lock.withLock { box.outcome }
    }
}
