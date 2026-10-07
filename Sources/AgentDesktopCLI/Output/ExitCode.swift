import AgentDesktopProtocol

/// Process exit status: a coarse class for scripts. Programs read
/// `error.code` from the JSON instead (contracts/runtime/v1/errors.json).
enum ExitStatus {
    static let ok: Int32 = 0
    /// A code this build does not know.
    static let unclassified: Int32 = 1

    static func of(_ error: RuntimeError, contract: RuntimeContract = .shared) -> Int32 {
        contract.error(error.code)?.exitCode ?? unclassified
    }
}
