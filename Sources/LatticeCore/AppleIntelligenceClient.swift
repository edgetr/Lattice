import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

public final class AppleIntelligenceClient: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [UUID: Task<Void, Never>] = [:]

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
            let task = Task { [self] in
                #if canImport(FoundationModels)
                if #available(macOS 26.0, *) {
                    guard SystemLanguageModel.default.isAvailable else {
                        continuation.yield(.failed(statusDescription)); continuation.finish(); unregister(sessionID); return
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
                    continuation.finish(); unregister(sessionID); return
                }
                #endif
                continuation.yield(.failed("Apple Intelligence requires macOS 26 or later.")); continuation.finish(); unregister(sessionID)
            }
            register(task, for: sessionID)
            continuation.onTermination = { [weak self] _ in self?.cancel(sessionID: sessionID) }
        }
    }

    public func cancel(sessionID: UUID) {
        lock.lock(); let task = tasks.removeValue(forKey: sessionID); lock.unlock(); task?.cancel()
    }

    private func register(_ task: Task<Void, Never>, for id: UUID) { lock.lock(); tasks[id] = task; lock.unlock() }
    private func unregister(_ id: UUID) { lock.lock(); tasks[id] = nil; lock.unlock() }
}
