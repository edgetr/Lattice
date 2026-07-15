import Foundation
import Testing
@testable import LatticeCore

@Suite("Session projection cache")
struct SessionProjectionCacheTests {
    @Test func matchesCanonicalOrderingWithoutHydratingTranscripts() throws {
        let now = Date()
        let sessions = (0..<250).map { index in
            let id = UUID()
            return LatticeSession(
                id: id,
                title: "Chat \(250 - index)",
                transcriptStorage: SessionTranscriptStorage(
                    fileName: "\(id.uuidString.lowercased())-projection.json",
                    messageCount: index + 1,
                    contentFingerprint: "fingerprint-\(index)",
                    lastMessagePreview: "Preview \(index)"
                ),
                isTranscriptLoaded: false,
                backend: .codex(model: "gpt-5.4"),
                isPinned: index.isMultiple(of: 17),
                lastUpdated: now.addingTimeInterval(TimeInterval(-index))
            )
        }
        var cache = SessionProjectionCache()

        let projections = cache.refresh(sessions)

        #expect(projections.map(\.id) == LatticeSessionListOrdering.sorted(sessions).map(\.id))
        #expect(projections.allSatisfy { $0.totalMessageCount > 0 })
        #expect(sessions.allSatisfy { !$0.isTranscriptLoaded && $0.messages.isEmpty })
        #expect(cache.rebuildCount == 1)
    }

    @Test func repeatedRapidNavigationReusesStableProjectionOrder() {
        let sessions = (0..<2_000).map { index in
            LatticeSession(
                title: "Thread \(index)",
                backend: .codex(model: "gpt-5.4"),
                lastUpdated: Date(timeIntervalSinceReferenceDate: TimeInterval(index))
            )
        }
        var cache = SessionProjectionCache()
        let expected = cache.orderedSessionIDs(for: sessions)

        for _ in 0..<1_000 {
            #expect(cache.orderedSessionIDs(for: sessions) == expected)
        }

        #expect(cache.rebuildCount == 1)
    }

    @Test func streamingTokenDeltasDoNotRebuildOrReorderRows() {
        var session = LatticeSession(
            title: "Streaming",
            messages: [.init(role: .user, text: "Prompt"), .init(role: .assistant, text: "")],
            backend: .codex(model: "gpt-5.4"),
            isStreaming: true,
            lastUpdated: Date(timeIntervalSinceReferenceDate: 1)
        )
        var cache = SessionProjectionCache()
        let initial = cache.refresh([session])

        for index in 0..<1_000 {
            session.messages[1].text += "x"
            session.lastUpdated = Date(timeIntervalSinceReferenceDate: TimeInterval(index + 2))
            #expect(cache.refresh([session]) == initial)
        }

        #expect(cache.rebuildCount == 1)
        session.isStreaming = false
        let completed = cache.refresh([session])
        #expect(cache.rebuildCount == 2)
        #expect(completed[0].lastMessagePreview == String(repeating: "x", count: 1_000))
    }

    @Test func unloadedNonemptyProjectionKeepsAuthoritativeCount() throws {
        let id = UUID()
        let session = LatticeSession(
            id: id,
            title: "Unloaded",
            transcriptStorage: SessionTranscriptStorage(
                fileName: "\(id.uuidString.lowercased())-unloaded.json",
                messageCount: 42,
                contentFingerprint: "stored"
            ),
            isTranscriptLoaded: false,
            backend: .codex(model: "gpt-5.4")
        )
        var cache = SessionProjectionCache()
        let projection = try #require(cache.refresh([session]).first)
        #expect(projection.totalMessageCount == 42)
        #expect(session.messages.isEmpty)
    }
}
