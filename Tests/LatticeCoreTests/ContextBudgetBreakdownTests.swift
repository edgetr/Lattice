import Foundation
import Testing
@testable import LatticeCore

@Suite("Context budget breakdown")
struct ContextBudgetBreakdownTests {
    @Test func categorizesRolesAndLabelsAsEstimate() {
        let system = "You are helpful."
        let user = "Hello there, how are you?"
        let assistant = "I am doing well, thanks."
        let draft = "follow up please"
        var session = LatticeSession(
            title: "Test",
            messages: [
                .init(role: .system, text: system),
                .init(role: .user, text: user),
                .init(role: .assistant, text: assistant)
            ],
            backend: .appleIntelligence,
            executionRoute: ExecutionRoute(
                mode: .code,
                providerID: "apple",
                modelID: "apple-intelligence",
                runtimeID: "apple"
            ),
            attachments: [
                ContextAttachment(path: "/tmp/notes.md")
            ],
            actions: [
                SessionAction(
                    messageID: UUID(),
                    kind: .tool,
                    toolKind: .write,
                    title: "Edit",
                    detail: "Sources/App.swift",
                    status: .completed
                )
            ]
        )

        let breakdown = LatticeContextBudgetEstimator.breakdown(session: session, draft: draft)
        #expect(breakdown.isEstimate)
        #expect(breakdown.providerReportedTotalTokens == nil)

        let expectedSystem = LatticeContextBudgetEstimator.estimateTokens(in: system)
        let expectedUser = LatticeContextBudgetEstimator.estimateTokens(in: user)
        let expectedAssistant = LatticeContextBudgetEstimator.estimateTokens(in: assistant)
        let expectedDraft = LatticeContextBudgetEstimator.estimateTokens(in: draft)
        #expect(breakdown.tokens(for: .system) == expectedSystem)
        #expect(breakdown.tokens(for: .user) == expectedUser)
        #expect(breakdown.tokens(for: .assistant) == expectedAssistant)
        #expect(breakdown.tokens(for: .draft) == expectedDraft)
        #expect(breakdown.tokens(for: .attachment) > 0)
        #expect(breakdown.tokens(for: .tool) > 0)

        let sliceSum = breakdown.slices.reduce(0) { $0 + $1.estimatedTokens }
        #expect(breakdown.estimatedTotal == sliceSum)
        _ = session
    }
}
