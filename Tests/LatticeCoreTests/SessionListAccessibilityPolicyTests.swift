import Testing
@testable import LatticeCore

@Suite("Session list accessibility policy")
struct SessionListAccessibilityPolicyTests {
    @Test func valueAnnouncesStreamingPinnedAndMessageState() {
        let session = LatticeSession(
            title: "Running chat",
            messages: [ChatMessage(role: .user, text: "Run tests")],
            backend: .codex(model: "gpt-5"),
            isPinned: true,
            isStreaming: true
        )

        #expect(SessionListAccessibilityPolicy.value(for: session) == "1 message, Streaming, Pinned")
    }

    @Test func idleUnpinnedEmptyChatKeepsExplicitState() {
        let session = LatticeSession(title: "New chat", backend: .codex(model: "gpt-5"))

        #expect(SessionListAccessibilityPolicy.value(for: session) == "0 messages, Idle, Not pinned")
    }
}
