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
        #expect(!plan.prompt.isEmpty)
        #expect(plan.deliveryIssue == nil)
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
        #expect(SessionRunReducer.terminal(for: .assistantDelta("x")) == nil)
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
}
