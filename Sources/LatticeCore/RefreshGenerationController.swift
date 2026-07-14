import Foundation

/// Identifies the only refresh generation allowed to publish shared state.
///
/// Provider operations may ignore task cancellation. Callers therefore check the
/// generation again after suspension before applying any result or clearing UI state.
public final class RefreshGenerationController: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    public init() {}

    @discardableResult
    public func begin() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        return generation
    }

    public func isCurrent(_ candidate: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == candidate
    }

    public func current() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }
}
