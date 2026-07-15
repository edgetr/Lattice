import Foundation

/// Terminal outcomes for a provider run. Side-effectful cleanup lives in AppState/orchestrator.
public enum SessionRunTerminal: Equatable, Sendable {
    case completed
    case cancelled
    case failed(String)
    case permissionDenied(String)

    public var isSuccessful: Bool {
        if case .completed = self { return true }
        return false
    }
}

public enum SessionRunSideEffect: Equatable, Sendable {
    case scheduleStreamingPersist
    case persist
    case finalize(SessionRunTerminal)
    case setActivity(icon: String, title: String, detail: String)
    case clearHarnessThread
    case setHarnessThread(String)
}

public struct SessionRunState: Equatable, Sendable {
    public var isStreaming: Bool
    public var lastAssistantText: String
    public var hasAssistantMessage: Bool
    public var isSuppressingInlineImagePayload: Bool

    public init(
        isStreaming: Bool,
        lastAssistantText: String,
        hasAssistantMessage: Bool,
        isSuppressingInlineImagePayload: Bool
    ) {
        self.isStreaming = isStreaming
        self.lastAssistantText = lastAssistantText
        self.hasAssistantMessage = hasAssistantMessage
        self.isSuppressingInlineImagePayload = isSuppressingInlineImagePayload
    }
}

public struct SessionRunReduceResult: Equatable, Sendable {
    public var state: SessionRunState
    public var effects: [SessionRunSideEffect]
    public var assistantText: String?
    public var isSuppressingInlineImagePayload: Bool?

    public init(
        state: SessionRunState,
        effects: [SessionRunSideEffect] = [],
        assistantText: String? = nil,
        isSuppressingInlineImagePayload: Bool? = nil
    ) {
        self.state = state
        self.effects = effects
        self.assistantText = assistantText
        self.isSuppressingInlineImagePayload = isSuppressingInlineImagePayload
    }
}

/// Pure event reduction for the parts of apply that do not need AppKit/UI stores.
/// Complex permission/outbox ladders still execute in the orchestrator.
public enum SessionRunReducer {
    public static func reduce(
        state: SessionRunState,
        event: AgentEvent
    ) -> SessionRunReduceResult {
        var next = state
        switch event {
        case .sessionStarted, .metric, .plan, .toolRequested, .toolProgress,
                .permissionRequested, .permissionDecided, .providerSessionLifecycle,
                .runCancelled, .harnessActivity, .providerDiagnostic, .artifact, .computerFrame:
            return SessionRunReduceResult(state: next)

        case .harnessSessionStarted(let threadID):
            return SessionRunReduceResult(state: next, effects: [.setHarnessThread(threadID), .persist])

        case .harnessSessionRecovery(let detail):
            return SessionRunReduceResult(
                state: next,
                effects: [
                    .clearHarnessThread,
                    .setActivity(
                        icon: "arrow.triangle.2.circlepath",
                        title: "Provider session recovery",
                        detail: detail
                    ),
                    .persist
                ]
            )

        case .assistantDelta(let delta):
            guard next.isStreaming, next.hasAssistantMessage else {
                return SessionRunReduceResult(state: next)
            }
            let filtered = AssistantTranscriptMediaPolicy.appending(
                delta,
                to: next.lastAssistantText,
                isSuppressingPayload: next.isSuppressingInlineImagePayload
            )
            next.lastAssistantText = filtered.text
            next.isSuppressingInlineImagePayload = filtered.isSuppressingPayload
            return SessionRunReduceResult(
                state: next,
                effects: [.scheduleStreamingPersist],
                assistantText: filtered.text,
                isSuppressingInlineImagePayload: filtered.isSuppressingPayload
            )

        case .reasoningSummary:
            return SessionRunReduceResult(state: next, effects: [.scheduleStreamingPersist])

        case .completed:
            next.isStreaming = false
            return SessionRunReduceResult(state: next, effects: [.finalize(.completed)])

        case .cancelled:
            next.isStreaming = false
            return SessionRunReduceResult(state: next, effects: [.finalize(.cancelled)])

        case .failed(let message):
            next.isStreaming = false
            return SessionRunReduceResult(state: next, effects: [.finalize(.failed(message))])
        }
    }

    /// Classify terminal agent events for the unified finalize ladder.
    public static func terminal(for event: AgentEvent) -> SessionRunTerminal? {
        switch event {
        case .completed: return .completed
        case .cancelled: return .cancelled
        case .failed(let message): return .failed(message)
        default: return nil
        }
    }
}
