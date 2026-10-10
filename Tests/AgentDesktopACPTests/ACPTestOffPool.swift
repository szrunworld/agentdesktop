import Foundation

/// Run blocking test work (spawning, sockets, lsof, semaphore waits) on its
/// own thread, so it never holds a cooperative-pool thread: under
/// LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 (CI's small pool) a blocked pool
/// thread starved an unrelated async test until it hung. Keep `#expect`
/// outside `body`, in the async test, so issues belong to the right test.
func offPool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread.detachNewThread { continuation.resume(with: Result { try body() }) }
    }
}
