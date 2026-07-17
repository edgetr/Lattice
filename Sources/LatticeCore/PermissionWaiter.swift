import Foundation

enum PermissionWaitResult<Value: Sendable>: Sendable {
    case resolved(Value)
    case timedOut
}

/// Async, one-shot permission response gate. Never parks a cooperative executor thread.
final class PermissionWaiter<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: PermissionWaitResult<Value>?
    private var continuations: [CheckedContinuation<PermissionWaitResult<Value>, Never>] = []
    private var timeoutTask: Task<Void, Never>?

    @discardableResult
    func resolve(_ value: Value) -> Bool {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return false
        }
        let result: PermissionWaitResult<Value> = .resolved(value)
        self.result = result
        let continuations = self.continuations
        self.continuations.removeAll(keepingCapacity: false)
        let timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        lock.unlock()

        timeoutTask?.cancel()
        continuations.forEach { $0.resume(returning: result) }
        return true
    }

    func wait(timeoutNanoseconds: UInt64) async -> PermissionWaitResult<Value> {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
                return
            }

            self.continuations.append(continuation)
            if self.timeoutTask == nil {
                let timeoutTask = Task.detached { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    } catch {
                        return
                    }
                    self?.expire()
                }
                self.timeoutTask = timeoutTask
            }
            lock.unlock()
        }
    }

    private func expire() {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = .timedOut
        let continuations = self.continuations
        self.continuations.removeAll(keepingCapacity: false)
        self.timeoutTask = nil
        lock.unlock()

        continuations.forEach { $0.resume(returning: .timedOut) }
    }
}

enum PermissionTimeout {
    static let message = "Permission request timed out."

    static func nanoseconds(for timeout: TimeInterval) -> UInt64 {
        guard timeout.isFinite else { return 120_000_000_000 }
        let seconds = max(0, timeout)
        let nanoseconds = seconds * 1_000_000_000
        return nanoseconds >= Double(UInt64.max) ? UInt64.max : UInt64(nanoseconds)
    }
}
