import AgentDesktopCLI
import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopService

// Every error the AI service can raise reaches the wire as a code the
// runtime/1 contract defines (runtime-api-v1-freeze §6), with the service's
// own classification kept aside, and the CLI turns it into its exit class.
@Suite("Service → runtime/1 errors")
struct ErrorMappingTests {
    @Test func everyServiceErrorMapsToADefinedRuntimeCode() {
        let defined = Set(RuntimeContract.shared.errors.map(\.code))
        for code in ErrorCode.allCases {
            let e = RuntimeBridge.runtimeError(ContractError(code, "x"))
            #expect(defined.contains(e.code), "\(code.rawValue) → \(e.code) is not in errors.json")
            #expect(e.details?["serviceCode"]?.stringValue == code.rawValue)
            #expect(e.code == e.code.lowercased())
        }
    }

    @Test func theFreezeTableHolds() {
        let table: [(ErrorCode, String)] = [
            (.validationError, "invalid_argument"), (.notFound, "not_found"), (.forbidden, "permission_denied"),
            (.configConflict, "conflict"), (.idempotencyConflict, "idempotency_conflict"),
            (.capabilityMismatch, "capability_mismatch"), (.authFailed, "model_unavailable"),
            (.deadlineExceeded, "deadline_exceeded"), (.desktopBusy, "control_busy"),
            (.staleObservation, "stale_observation"), (.actionOutcomeUnknown, "action_delivery_unknown"),
            (.auditUnavailable, "audit_unavailable"), (.internalError, "internal_error"),
        ]
        for (service, runtime) in table { #expect(RuntimeBridge.runtimeError(ContractError(service, "x")).code == runtime) }
        // Details the service attaches survive; retryable is kept.
        let e = RuntimeBridge.runtimeError(ContractError(.rateLimited, "slow down", retryable: true,
                                                         details: .obj([("retryAfterMs", .int(2000))])))
        #expect(e.retryable == true)
        #expect(e.details?["retryAfterMs"]?.intValue == 2000)
        #expect(e.details?["reason"]?.stringValue == "rate_limited")
    }

    @Test func theCLIGivesEachRuntimeErrorItsExitClass() {
        func code(_ c: String) -> ExitCode { ContractCLI.exitCode(.obj([("ok", .bool(false)), ("error", .obj([("code", .string(c))]))])) }
        for c in ["capability_missing", "version_mismatch", "handshake_required", "runtime_offline"] { #expect(code(c) == .runtimeUnavailable, "\(c)") }
        for c in ["invalid_argument", "not_found", "conflict", "model_unavailable"] { #expect(code(c) == .rejected, "\(c)") }
    }
}
