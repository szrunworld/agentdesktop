import Foundation

/// Waiting between polls; tests inject a fast one. Shared by the shell's
/// Store and AgentDesktopAIUI's pages (moved here from its ContractClient).
public protocol PollClock: Sendable {
    func pause(milliseconds: Int) async throws
}

public struct SystemPollClock: PollClock {
    public init() {}
    public func pause(milliseconds: Int) async throws { try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000) }
}
