import Foundation
import Testing
@testable import LatticeCore

@Suite("Transcript hydration invariants")
struct TranscriptHydrationInvariantTests {
    @Test func evictionKeepsSidecarsHydratableAndClean() {
        let message = ChatMessage(role: .assistant, text: "Stored")
        let artifact = AssistantArtifact(
            messageID: message.id,
            status: .available,
            displayName: "stored.png",
            mimeType: "image/png",
            byteCount: 8,
            canonicalPath: "/tmp/stored.png",
            provenance: .init(provider: "Test", origin: .codexImageView)
        )
        let transcript = SessionTranscriptStorage(
            fileName: "transcript.json",
            messageCount: 1,
            contentFingerprint: "transcript"
        )
        let artifacts = SessionArtifactStorage(
            fileName: "artifacts.json",
            artifactCount: 1,
            contentFingerprint: "artifacts"
        )
        var session = LatticeSession(
            title: "Cached",
            messages: [message],
            transcriptStorage: transcript,
            artifacts: [artifact],
            artifactStorage: artifacts,
            backend: .codex(model: "gpt-5.4")
        )

        #expect(TranscriptHydrationEvictionPolicy.evictCleanContent(in: &session))
        #expect(session.messages.isEmpty)
        #expect(!session.isTranscriptLoaded)
        #expect(!session.isTranscriptDirty)
        #expect(session.artifacts.isEmpty)
        #expect(!session.isArtifactsLoaded)
        #expect(!session.isArtifactsDirty)
        #expect(session.transcriptStorage == transcript)
        #expect(session.artifactStorage == artifacts)
        let request = TranscriptHydrationRequest(sessionID: session.id, storage: transcript)
        #expect(TranscriptHydrationApplyPolicy.shouldApply(
            request: request,
            activeRequest: request,
            selectedSessionID: session.id,
            currentSession: session
        ))
    }

    @Test func initializerNormalizesContradictorySidecarFlagsWithoutDroppingMemory() {
        let message = ChatMessage(role: .user, text: "Unsaved")
        let reference = SessionTranscriptStorage(
            fileName: "transcript.json",
            messageCount: 1,
            contentFingerprint: "stored"
        )
        let emptyPlaceholder = LatticeSession(
            title: "Placeholder",
            transcriptStorage: reference,
            isTranscriptLoaded: true,
            backend: .codex(model: "gpt-5.4")
        )
        #expect(!emptyPlaceholder.isTranscriptLoaded)
        #expect(!emptyPlaceholder.isTranscriptDirty)

        let memoryWins = LatticeSession(
            title: "Memory",
            messages: [message],
            transcriptStorage: reference,
            isTranscriptLoaded: false,
            backend: .codex(model: "gpt-5.4")
        )
        #expect(memoryWins.isTranscriptLoaded)
        #expect(memoryWins.isTranscriptDirty)
        #expect(memoryWins.messages == [message])
    }

    @Test func decoderPreservesInlineContentWhenSidecarReferencesAlsoExist() throws {
        let message = ChatMessage(role: .user, text: "Preserve inline")
        let artifact = AssistantArtifact(
            messageID: message.id,
            status: .available,
            displayName: "inline.png",
            mimeType: "image/png",
            byteCount: 8,
            canonicalPath: "/tmp/inline.png",
            provenance: .init(provider: "Test", origin: .codexImageView)
        )
        let source = LatticeSession(
            title: "Transitional",
            messages: [message],
            artifacts: [artifact],
            backend: .codex(model: "gpt-5.4")
        )
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as? [String: Any]
        )
        object["transcriptStorage"] = [
            "fileName": "transcript.json",
            "messageCount": 1,
            "contentFingerprint": "transcript"
        ]
        object["artifactStorage"] = [
            "fileName": "artifacts.json",
            "artifactCount": 1,
            "contentFingerprint": "artifacts"
        ]
        let decoded = try JSONDecoder().decode(
            LatticeSession.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.messages == [message])
        #expect(decoded.isTranscriptLoaded)
        #expect(decoded.isTranscriptDirty)
        #expect(decoded.artifacts == [artifact])
        #expect(decoded.isArtifactsLoaded)
        #expect(decoded.isArtifactsDirty)
    }

    @Test func artifactOnlyEvictionRemainsEligibleForHydration() {
        let message = ChatMessage(role: .assistant, text: "Transcript stays resident")
        let transcript = SessionTranscriptStorage(
            fileName: "transcript.json",
            messageCount: 1,
            contentFingerprint: "transcript"
        )
        let artifacts = SessionArtifactStorage(
            fileName: "artifacts.json",
            artifactCount: 1,
            contentFingerprint: "artifacts"
        )
        var session = LatticeSession(
            title: "Artifacts evicted",
            messages: [message],
            transcriptStorage: transcript,
            artifactStorage: artifacts,
            backend: .codex(model: "gpt-5.4")
        )
        session.isArtifactsLoaded = false
        session.artifacts = []
        session.isArtifactsDirty = false

        let request = TranscriptHydrationRequest(
            sessionID: session.id,
            storage: transcript,
            artifactStorage: artifacts
        )
        #expect(TranscriptHydrationApplyPolicy.shouldApply(
            request: request,
            activeRequest: request,
            selectedSessionID: session.id,
            currentSession: session
        ))

        var stale = session
        stale.artifactStorage = SessionArtifactStorage(
            fileName: "new-artifacts.json",
            artifactCount: 1,
            contentFingerprint: "new"
        )
        #expect(!TranscriptHydrationApplyPolicy.shouldApply(
            request: request,
            activeRequest: request,
            selectedSessionID: stale.id,
            currentSession: stale
        ))
    }

    @Test func lazyLegacySelfEditInferenceWaitsForHydratedTranscriptThenClassifies() {
        let message = ChatMessage(role: .user, text: "Please change this app sidebar color")
        let storage = SessionTranscriptStorage(
            fileName: "legacy.json",
            messageCount: 1,
            contentFingerprint: "legacy"
        )
        var session = LatticeSession(
            title: "Older conversation",
            transcriptStorage: storage,
            backend: .codex(model: "gpt-5.4")
        )
        #expect(!session.isTranscriptLoaded)
        #expect(!LegacySelfEditMigrationPolicy.shouldClassify(session))

        session.messages = [message]
        session.isTranscriptLoaded = true
        session.isTranscriptDirty = false
        #expect(LegacySelfEditMigrationPolicy.shouldClassify(session))
    }

    @Test func repeatedSelectionUsesExactRequestIdentityAndDelayedCancelCannotCancelFreshRequest() async {
        let sessionA = UUID()
        let sessionB = UUID()
        let storageA = SessionTranscriptStorage(
            fileName: "a.json",
            messageCount: 1,
            contentFingerprint: "a"
        )
        let storageB = SessionTranscriptStorage(
            fileName: "b.json",
            messageCount: 1,
            contentFingerprint: "b"
        )
        let oldA = TranscriptHydrationRequest(sessionID: sessionA, storage: storageA)
        let requestB = TranscriptHydrationRequest(sessionID: sessionB, storage: storageB)
        let freshA = TranscriptHydrationRequest(sessionID: sessionA, storage: storageA)
        #expect(oldA != freshA)
        #expect(oldA.requestID != freshA.requestID)

        let placeholder = LatticeSession(
            id: sessionA,
            title: "A",
            transcriptStorage: storageA,
            backend: .codex(model: "gpt-5.4")
        )
        #expect(!TranscriptHydrationApplyPolicy.shouldApply(
            request: oldA,
            activeRequest: freshA,
            selectedSessionID: sessionA,
            currentSession: placeholder
        ))
        #expect(TranscriptHydrationApplyPolicy.shouldApply(
            request: freshA,
            activeRequest: freshA,
            selectedSessionID: sessionA,
            currentSession: placeholder
        ))

        let gate = TranscriptHydrationTestGate()
        let coordinator = TranscriptHydrationCoordinator()
        let oldATask = Task {
            await coordinator.hydrate(oldA) {
                await gate.suspend("old-a")
                return .loaded([.init(role: .assistant, text: "old-a")])
            }
        }
        await gate.waitUntilStarted("old-a")
        let bTask = Task {
            await coordinator.hydrate(requestB) {
                await gate.suspend("b")
                return .loaded([.init(role: .assistant, text: "b")])
            }
        }
        await gate.waitUntilStarted("b")
        let freshATask = Task {
            await coordinator.hydrate(freshA) {
                await gate.suspend("fresh-a")
                return .loaded([.init(role: .assistant, text: "fresh-a")])
            }
        }
        await gate.waitUntilStarted("fresh-a")

        // This cancellation was queued for the first A selection. It must not match A2.
        await coordinator.cancel(oldA)
        await gate.release("fresh-a")
        let freshOutcome = await freshATask.value
        if case .loaded(let completedRequest, let content) = freshOutcome {
            #expect(completedRequest == freshA)
            #expect(content.messages.map(\.text) == ["fresh-a"])
        } else {
            Issue.record("Fresh A hydration was cancelled by a delayed old-A cancellation")
        }

        await gate.release("old-a")
        await gate.release("b")
        if case .cancelled(let cancelledRequest) = await oldATask.value {
            #expect(cancelledRequest == oldA)
        } else {
            Issue.record("Old A hydration should be cancelled")
        }
        if case .cancelled(let cancelledRequest) = await bTask.value {
            #expect(cancelledRequest == requestB)
        } else {
            Issue.record("B hydration should be cancelled by fresh A")
        }
    }
}

private actor TranscriptHydrationTestGate {
    private var started: Set<String> = []
    private var released: Set<String> = []
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]

    func suspend(_ key: String) async {
        started.insert(key)
        if released.remove(key) != nil { return }
        await withCheckedContinuation { continuation in
            waiters[key] = continuation
        }
    }

    func waitUntilStarted(_ key: String) async {
        while !started.contains(key) {
            await Task.yield()
        }
    }

    func release(_ key: String) {
        released.insert(key)
        if let continuation = waiters.removeValue(forKey: key) {
            released.remove(key)
            continuation.resume()
        }
    }
}
