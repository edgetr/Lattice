import Foundation

/// Observable state for a user-initiated control whose work may outlive the click.
/// `begin` is the single dispatch gate: callers must not launch work when it returns false.
public struct ControlActionState: Equatable, Sendable {
    public enum Phase: String, Equatable, Sendable {
        case idle
        case running
        case succeeded
        case failed
    }

    public private(set) var phase: Phase
    public private(set) var message: String?

    public init(phase: Phase = .idle, message: String? = nil) {
        self.phase = phase
        self.message = message
    }

    public var isRunning: Bool { phase == .running }

    /// Returns false while an invocation is already active, preventing duplicate dispatch.
    @discardableResult
    public mutating func begin(progressMessage: String) -> Bool {
        guard !isRunning else { return false }
        phase = .running
        message = progressMessage
        return true
    }

    /// Applies the control's current prerequisite result at the same dispatch boundary.
    @discardableResult
    public mutating func begin(progressMessage: String, disabledReason: String?) -> Bool {
        guard disabledReason == nil else { return false }
        return begin(progressMessage: progressMessage)
    }

    public mutating func succeed(_ message: String) {
        guard isRunning else { return }
        phase = .succeeded
        self.message = message
    }

    public mutating func fail(_ message: String) {
        guard isRunning else { return }
        phase = .failed
        self.message = message
    }
}
