import Foundation
import Testing
@testable import LatticeCore

@Suite("Apple Intelligence task lifecycle")
struct AppleIntelligenceClientLifecycleTests {
    @Test func immediatelyFinishingStreamCannotLeaveStaleRegistration() async {
        let client = AppleIntelligenceClient()
        let sessionID = UUID()
        for await _ in client.stream(prompt: "hello", sessionID: sessionID) {}
        #expect(client.activeTaskCount == 0)
    }

    @Test func sameSessionReplacementDoesNotLetOldCompletionRemoveNewOwner() async {
        let client = AppleIntelligenceClient()
        let sessionID = UUID()
        let first = client.stream(prompt: "first", sessionID: sessionID)
        let second = client.stream(prompt: "second", sessionID: sessionID)

        async let firstEvents = collect(first)
        async let secondEvents = collect(second)
        _ = await (firstEvents, secondEvents)
        #expect(client.activeTaskCount == 0)
        client.cancel(sessionID: sessionID)
        #expect(client.activeTaskCount == 0)
    }

    private func collect(_ stream: AsyncStream<AgentEvent>) async -> [AgentEvent] {
        var result: [AgentEvent] = []
        for await event in stream { result.append(event) }
        return result
    }
}
