import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

public final class AppleIntelligenceClient: @unchecked Sendable {
    private struct Registration {
        let token: UUID
        var task: Task<Void, Never>?
    }

    private let lock = NSLock()
    private var tasks: [UUID: Registration] = [:]

    public init() {}

    public var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    public var statusDescription: String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return "Available on this Mac"
            case .unavailable(.deviceNotEligible): return "This Mac is not eligible"
            case .unavailable(.appleIntelligenceNotEnabled): return "Enable Apple Intelligence in System Settings"
            case .unavailable(.modelNotReady): return "On-device model is still downloading"
            @unknown default: return "Unavailable"
            }
        }
        #endif
        return "Requires macOS 26 or later"
    }

    public func stream(prompt: String, sessionID: UUID) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            let token = UUID()
            reserve(sessionID: sessionID, token: token)?.cancel()
            let task = Task { [self] in
                defer {
                    unregister(sessionID, token: token)
                    continuation.finish()
                }
                #if canImport(FoundationModels)
                if #available(macOS 26.0, *) {
                    guard SystemLanguageModel.default.isAvailable else {
                        continuation.yield(.failed(statusDescription))
                        return
                    }
                    do {
                        let session = LanguageModelSession(
                            model: SystemLanguageModel.default,
                            instructions: "You are Lattice, a concise personal assistant. Never claim to have used tools you cannot access.\n\n\(LatticeProductInstructions.current)"
                        )
                        var previous = ""
                        for try await snapshot in session.streamResponse(to: prompt) {
                            try Task.checkCancellation()
                            let current = snapshot.content
                            let delta = current.hasPrefix(previous) ? String(current.dropFirst(previous.count)) : current
                            if !delta.isEmpty { continuation.yield(.assistantDelta(delta)) }
                            previous = current
                        }
                        continuation.yield(.completed)
                    } catch is CancellationError { continuation.yield(.cancelled) }
                    catch { continuation.yield(.failed(error.localizedDescription)) }
                    return
                }
                #endif
                continuation.yield(.failed("Apple Intelligence requires macOS 26 or later."))
            }
            attach(task, sessionID: sessionID, token: token)
            continuation.onTermination = { [weak self] _ in
                self?.cancel(sessionID: sessionID, token: token)
            }
        }
    }

    public func cancel(sessionID: UUID) {
        lock.lock()
        let task = tasks.removeValue(forKey: sessionID)?.task
        lock.unlock()
        task?.cancel()
    }

    var activeTaskCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return tasks.count
    }

    private func reserve(sessionID: UUID, token: UUID) -> Task<Void, Never>? {
        lock.lock()
        let previous = tasks.updateValue(Registration(token: token, task: nil), forKey: sessionID)?.task
        lock.unlock()
        return previous
    }

    private func attach(_ task: Task<Void, Never>, sessionID: UUID, token: UUID) {
        lock.lock()
        if tasks[sessionID]?.token == token {
            tasks[sessionID]?.task = task
            lock.unlock()
        } else {
            lock.unlock()
            task.cancel()
        }
    }

    private func unregister(_ id: UUID, token: UUID) {
        lock.lock()
        if tasks[id]?.token == token { tasks[id] = nil }
        lock.unlock()
    }

    private func cancel(sessionID: UUID, token: UUID) {
        lock.lock()
        let task: Task<Void, Never>?
        if tasks[sessionID]?.token == token {
            task = tasks.removeValue(forKey: sessionID)?.task
        } else {
            task = nil
        }
        lock.unlock()
        task?.cancel()
    }
}
