import AgentDesktopProtocol
import AgentDesktopUI
import Foundation

/// Test copies only: makes the Runtime look slow or unreachable to the main
/// window without touching the Runtime itself, so acceptance can cover a
/// quit while the Runtime does not answer (docs/acceptance/ui-u8).
///
/// AGENTDESKTOP_TEST_FAULT_FILE names a file under /tmp/adt-*; every call
/// reads it again, so a running copy can be switched between states:
/// - `delay <method|*> <milliseconds>` pauses before forwarding the call,
///   with Task.sleep, never a blocking wait;
/// - `offline` fails every call with `runtime_offline`;
/// - an empty or missing file passes everything through.
/// The product ignores the variable; only a side instance wraps its port.
final class TestFaultRuntimePort: RuntimePort, @unchecked Sendable {
    let base: RuntimePort
    let file: String
    var isSample: Bool { base.isSample }

    init(base: RuntimePort, file: String) {
        self.base = base
        self.file = file
    }

    /// The port the main window uses: `base`, wrapped only for a side
    /// instance that names a fault file in its own /tmp/adt-* directory.
    static func wrap(_ base: RuntimePort, role: HostRole,
                     environment env: [String: String] = ProcessInfo.processInfo.environment) -> RuntimePort {
        guard role.isSideInstance, let file = env["AGENTDESKTOP_TEST_FAULT_FILE"],
              file.hasPrefix("/tmp/adt-") || file.hasPrefix("/private/tmp/adt-") else { return base }
        return TestFaultRuntimePort(base: base, file: file)
    }

    struct Faults: Equatable {
        var offline = false
        var delays: [String: Int] = [:]

        func delay(for method: String) -> Int? { delays[method] ?? delays["*"] }
    }

    static func parse(_ text: String) -> Faults {
        var f = Faults()
        for line in text.split(whereSeparator: \.isNewline) {
            let words = line.split(separator: " ").map(String.init)
            switch words.first {
            case "offline": f.offline = true
            case "delay" where words.count == 3: if let ms = Int(words[2]), ms >= 0 { f.delays[words[1]] = ms }
            default: break
            }
        }
        return f
    }

    private func faults() -> Faults {
        (try? String(contentsOfFile: file, encoding: .utf8)).map(Self.parse) ?? Faults()
    }

    func call(_ method: String, _ params: JSONValue, context: RequestContext) async throws -> JSONValue {
        let f = faults()
        if f.offline { throw RuntimeError.runtimeOffline("test fault: the Runtime is offline", endpoint: file) }
        if let ms = f.delay(for: method) { try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000) }
        return try await base.call(method, params, context: context)
    }

    func call(_ method: String, _ params: JSONValue, context: RequestContext, requestId: String?) async throws -> JSONValue {
        let f = faults()
        if f.offline { throw RuntimeError.runtimeOffline("test fault: the Runtime is offline", endpoint: file) }
        if let ms = f.delay(for: method) { try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000) }
        return try await base.call(method, params, context: context, requestId: requestId)
    }

    func subscribe(after: Int?) async throws -> AsyncThrowingStream<JSONValue, Error> {
        if faults().offline { throw RuntimeError.runtimeOffline("test fault: the Runtime is offline", endpoint: file) }
        return try await base.subscribe(after: after)
    }
}
