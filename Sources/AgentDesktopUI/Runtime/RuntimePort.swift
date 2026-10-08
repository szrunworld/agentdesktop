import AgentDesktopProtocol
import Foundation

/// The only way the main window reaches the Runtime (docs/plan/10 §1.6).
/// Every call is one runtime/1 method with its `params`; the answer is the
/// response's `data`, or a `RuntimeError` with a runtime/1 code. The UI
/// never decides state on its own: it shows what these calls return.
///
/// Implementations: `MockRuntime` (here, for development and tests) and the
/// in-process adapter over `RuntimeService` (U1b, in the host; it runs off
/// the main thread because the engine platform calls into the main actor).
public protocol RuntimePort: AnyObject, Sendable {
    /// A source that is not the real Runtime (Mock, sample data). The shell
    /// shows a permanent "样例数据" mark while it is true (09 brief).
    var isSample: Bool { get }

    /// One runtime/1 request.
    func call(_ method: String, _ params: JSONValue) async throws -> JSONValue

    /// `events.subscribe` without a runId: EventFrame values for every Run
    /// the caller may see, starting after `after` (nil: from now). The
    /// stream ends with a `RuntimeError` (for instance
    /// `events_cursor_expired`) or when the caller stops iterating.
    /// Closing it never affects a Run (ADR-02).
    func subscribe(after: Int?) async throws -> AsyncThrowingStream<JSONValue, Error>
}

extension RuntimePort {
    public func call(_ method: String) async throws -> JSONValue {
        try await call(method, .obj([]))
    }
}

/// Methods the main window may call: the implemented part of the frozen
/// catalog (`methods.json` "methods"). Reserved and frozen-but-unimplemented
/// names are absent, so nothing can be mocked ahead of the contract.
public enum RuntimeCatalog {
    public static var implemented: Set<String> {
        Set(RuntimeContract.shared.methods.map(\.method))
    }

    public static func spec(_ method: String) -> RuntimeContract.MethodSpec? {
        RuntimeContract.shared.method(method)
    }
}
