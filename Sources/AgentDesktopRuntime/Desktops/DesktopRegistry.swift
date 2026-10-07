import AgentDesktopProtocol
import Foundation

/// Desktops this Runtime manages. Creation and destruction come with the
/// write path (CLI plan PR2); until then the registry is read through
/// desktop.list/show and stays empty in the product.
public final class DesktopRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var desktops: [Desktop] = []

    public init() {}

    public var count: Int { lock.withLock { desktops.count } }

    public func list() -> [Desktop] { lock.withLock { desktops } }

    public func show(_ id: String) -> Desktop? { lock.withLock { desktops.first { $0.desktopId == id } } }

    /// Record a desktop the Runtime created.
    public func add(_ desktop: Desktop) {
        lock.withLock { desktops.append(desktop) }
    }
}
