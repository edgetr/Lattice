import Foundation
import Testing
@testable import LatticeCore

@Suite("Run pipeline planner and reducer")
struct RunPipelineTests {
    @Test func plannerMarksPromptDrivenRuntimes() {
        #expect(RunLaunchPlanner.usesPromptDrivenBackend(runtimeID: "pi", backend: .codex(model: "gpt")))
        #expect(RunLaunchPlanner.usesPromptDrivenBackend(runtimeID: "hermes", backend: .openCode(model: "m")))
        #expect(RunLaunchPlanner.usesPromptDrivenBackend(runtimeID: "codex", backend: .codex(model: "gpt")))
        #expect(!RunLaunchPlanner.usesPromptDrivenBackend(runtimeID: "lattice", backend: .ollama(model: "q")))
        #expect(!RunLaunchPlanner.usesPromptDrivenBackend(runtimeID: "lattice", backend: .appleIntelligence))
    }

    @Test func plannerProducesPromptWithoutDeliveryIssueForEmptySession() {
        let session = LatticeSession(
            title: "t",
            messages: [.init(role: .user, text: "hi")],
            backend: .codex(model: "gpt-5.5"),
            executionRoute: ExecutionRoute(mode: .code, providerID: "codex", modelID: "gpt-5.5", runtimeID: "pi")
        )
        let plan = RunLaunchPlanner.plan(
            .init(
                session: session,
                submittedText: "hi",
                additionalContext: "",
                tokenLimit: 8_000,
                effectiveRuntimeID: "pi"
            )
        )
        #expect(plan.usesPromptDrivenBackend)
        #expect(plan.prompt.contains("hi"))
        #expect(plan.deliveryIssue == nil)
        #expect(plan.recoveryPrompt == nil)
        #expect(!plan.resetsHarnessSession)
    }

    @Test func plannerRecoveryWhenACPSessionExists() {
        let session = LatticeSession(
            title: "t",
            messages: [
                .init(role: .user, text: "first"),
                .init(role: .assistant, text: "reply")
            ],
            backend: .grok(model: "grok-4"),
            executionRoute: ExecutionRoute(mode: .code, providerID: "grok", modelID: "grok-4", runtimeID: "grok"),
            harnessThreadID: "thread-1"
        )
        let plan = RunLaunchPlanner.plan(
            .init(
                session: session,
                submittedText: "follow-up",
                additionalContext: "",
                tokenLimit: 8_000,
                effectiveRuntimeID: "grok"
            )
        )
        #expect(plan.usesPromptDrivenBackend)
        #expect(plan.recoveryPrompt != nil)
        #expect(plan.routeThreadID == "thread-1" || plan.resetsHarnessSession)
    }

    @Test func reducerFinalizesTerminalEvents() {
        let base = SessionRunState(
            isStreaming: true,
            lastAssistantText: "partial",
            hasAssistantMessage: true,
            isSuppressingInlineImagePayload: false
        )
        let completed = SessionRunReducer.reduce(state: base, event: .completed)
        #expect(!completed.state.isStreaming)
        #expect(completed.effects == [.finalize(.completed)])

        let failed = SessionRunReducer.reduce(state: base, event: .failed("boom"))
        #expect(failed.effects == [.finalize(.failed("boom"))])
        #expect(SessionRunReducer.terminal(for: .cancelled) == .cancelled)
        #expect(SessionRunReducer.terminal(for: .failed("x")) == .failed("x"))
        #expect(SessionRunReducer.terminal(for: .assistantDelta("x")) == nil)
        let cancelled = SessionRunReducer.reduce(state: base, event: .cancelled)
        #expect(cancelled.effects == [.finalize(.cancelled)])
        #expect(!cancelled.state.isStreaming)
    }

    @Test func reducerAppliesAssistantDeltaThroughMediaPolicy() {
        let base = SessionRunState(
            isStreaming: true,
            lastAssistantText: "Hello",
            hasAssistantMessage: true,
            isSuppressingInlineImagePayload: false
        )
        let result = SessionRunReducer.reduce(state: base, event: .assistantDelta(" world"))
        #expect(result.assistantText == "Hello world")
        #expect(result.effects == [.scheduleStreamingPersist])
    }

    @Test func permissionDeniedTerminalIsDistinct() {
        let terminal = SessionRunTerminal.permissionDenied("blocked")
        #expect(!terminal.isSuccessful)
        if case .permissionDenied(let message) = terminal {
            #expect(message == "blocked")
        } else {
            Issue.record("Expected permissionDenied")
        }
    }
}
