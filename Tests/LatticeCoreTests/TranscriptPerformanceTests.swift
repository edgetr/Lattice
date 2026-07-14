import Foundation
import Testing
@testable import LatticeCore

@Suite("Lazy transcript performance and recovery")
struct TranscriptPerformanceTests {
    @Test func lazyLoadDoesNotReadAnyTranscriptUntilMaterialized() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sessions.json")
        let writer = SessionPersistence(fileURL: url)
        let sessions = (0..<40).map { thread in
            LatticeSession(
                title: "Thread \(thread)",
                messages: (0..<250).map { .init(role: $0.isMultiple(of: 2) ? .user : .assistant, text: "thread-\(thread)-message-\($0)") },
                backend: .codex(model: "gpt-5.4")
            )
        }
        try writer.save(sessions)

        let reads = ReadRecorder()
        let reader = SessionPersistence(fileURL: url, io: recordingIO(reads))
        let snapshot = try #require(loaded(reader.loadLazyResult()))
        #expect(snapshot.sessions.count == 40)
        #expect(snapshot.sessions.allSatisfy { !$0.isTranscriptLoaded && $0.messages.isEmpty })
        #expect(reads.transcriptReads == 0)

        var selected = snapshot.sessions[17]
        try reader.materializeTranscript(in: &selected)
        #expect(selected.messages.count == 250)
        #expect(selected.messages.last?.text == "thread-17-message-249")
        #expect(reads.transcriptReads == 1)
    }

    @Test func appendEditAndDeleteInvalidateTranscriptAndIndexTogether() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionPersistence(fileURL: root.appendingPathComponent("sessions.json"))
        var session = LatticeSession(
            title: "Mutable",
            messages: [.init(role: .user, text: "alpha"), .init(role: .assistant, text: "beta")],
            backend: .codex(model: "gpt-5.4")
        )
        try store.save([session])
        let firstReference = try #require(loaded(store.loadLazyResult())?.sessions.first?.transcriptStorage)

        session.messages[0].text = "edited gamma"
        session.messages.append(.init(role: .assistant, text: "delta"))
        try store.save([session])
        let edited = try #require(loaded(store.loadLazyResult()))
        let secondReference = try #require(edited.sessions.first?.transcriptStorage)
        #expect(secondReference != firstReference)
        #expect(edited.searchIndex.candidateSessionIDs(for: "gamma", allSessionIDs: [session.id]) == [session.id])
        #expect(edited.searchIndex.candidateSessionIDs(for: "alpha", allSessionIDs: [session.id]).isEmpty)

        session.messages.removeAll()
        try store.save([session])
        let deleted = try #require(store.load().first)
        #expect(deleted.messages.isEmpty)
        #expect(try #require(loaded(store.loadLazyResult())?.sessions.first?.transcriptStorage).messageCount == 0)
    }

    @Test func missingOrCorruptDerivedIndexNeverHidesChatsAndRebuildsOnSave() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionPersistence(fileURL: root.appendingPathComponent("sessions.json"))
        let session = LatticeSession(
            title: "Indexed",
            messages: [.init(role: .user, text: "needle recovery")],
            backend: .codex(model: "gpt-5.4")
        )
        try store.save([session])
        try Data("not-json".utf8).write(to: store.searchIndexURL, options: .atomic)

        let recovered = try #require(loaded(store.loadLazyResult()))
        #expect(recovered.searchIndex.containsValidEntry(for: recovered.sessions[0]))
        #expect(recovered.searchIndex.candidateSessionIDs(for: "needle", allSessionIDs: [session.id]) == [session.id])
        #expect(recovered.searchIndex.candidateSessionIDs(for: "absent-token", allSessionIDs: [session.id]).isEmpty)

        var materialized = recovered.sessions[0]
        try store.materializeTranscript(in: &materialized)
        try store.save([materialized])
        let rebuilt = try #require(loaded(store.loadLazyResult()))
        #expect(rebuilt.searchIndex.containsValidEntry(for: rebuilt.sessions[0]))
        #expect(rebuilt.searchIndex.candidateSessionIDs(for: "needle", allSessionIDs: [session.id]) == [session.id])
    }

    @Test func corruptCanonicalTranscriptFailsObservablyWithoutMutatingIt() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionPersistence(fileURL: root.appendingPathComponent("sessions.json"))
        let session = LatticeSession(title: "Durable", messages: [.init(role: .user, text: "keep")], backend: .codex(model: "gpt-5.4"))
        try store.save([session])
        let lazy = try #require(loaded(store.loadLazyResult()))
        let reference = try #require(lazy.sessions[0].transcriptStorage)
        let transcriptURL = store.transcriptDirectoryURL.appendingPathComponent(reference.fileName)
        let corrupt = Data("[]".utf8)
        try corrupt.write(to: transcriptURL, options: .atomic)

        if case .failed(let issue) = store.loadResult() {
            #expect(issue.kind == .corrupt)
            #expect(issue.filePath == transcriptURL.path)
        } else {
            Issue.record("Fingerprint mismatch must surface as a durable-store failure")
        }
        #expect(try Data(contentsOf: transcriptURL) == corrupt)
    }

    @Test func legacyMonolithicStoreMigratesOnSaveWithoutChangingConversation() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("sessions.json")
        let legacy = LatticeSession(title: "Legacy", messages: [.init(role: .user, text: "old durable text")], backend: .codex(model: "gpt-5.4"))
        try JSONEncoder().encode([legacy]).write(to: url)
        let store = SessionPersistence(fileURL: url)

        let first = try #require(loaded(store.loadLazyResult()))
        #expect(first.usesLegacyMonolithicStore)
        #expect(first.sessions[0].messages == legacy.messages)
        try store.save(first.sessions)

        let migrated = try #require(loaded(store.loadLazyResult()))
        #expect(!migrated.usesLegacyMonolithicStore)
        #expect(!migrated.sessions[0].isTranscriptLoaded)
        #expect(migrated.sessions[0].messages.isEmpty)
        #expect(store.load() == [legacy])
    }

    @Test func hashedIndexDoesNotDuplicatePlaintextTranscript() throws {
        let message = "unique-private-search-phrase"
        let session = LatticeSession(title: "Chat", messages: [.init(role: .user, text: message)], backend: .codex(model: "gpt-5.4"))
        var index = SessionSearchIndex()
        index.update(session: session)
        let data = try JSONEncoder().encode(index)
        #expect(!String(decoding: data, as: UTF8.self).contains(message))
        #expect(index.candidateSessionIDs(for: "private search", allSessionIDs: [session.id]) == [session.id])
    }

    @Test func renderWindowsPageDeterministicallyAndStayBounded() {
        var cache = TranscriptRenderWindowCache(pageSize: 50, maximumThreadCount: 3, maximumVisibleMessageCount: 200)
        let ids = (0..<8).map { _ in UUID() }
        let initial = cache.activate(sessionID: ids[0], messageCount: 1_000)
        #expect(initial.range == 950..<1_000)
        #expect(cache.loadEarlier(sessionID: ids[0], messageCount: 1_000).range == 900..<1_000)
        #expect(cache.loadEarlier(sessionID: ids[0], messageCount: 1_000).range == 850..<1_000)

        for id in ids.dropFirst() { _ = cache.activate(sessionID: id, messageCount: 1_000) }
        #expect(cache.cachedThreadCount == 3)
        #expect(cache.cachedVisibleMessageCount <= 200)
        cache.invalidate(sessionID: ids[7])
        #expect(cache.cachedThreadCount == 2)
        cache.removeAll()
        #expect(cache.cachedVisibleMessageCount == 0)
    }

    private func loaded<T: Sendable>(_ result: DurableStoreLoadResult<T>) -> T? {
        if case .loaded(let value) = result { return value }
        return nil
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func recordingIO(_ recorder: ReadRecorder) -> DurableStoreFileIO {
        let base = DurableStoreFileIO.default
        return DurableStoreFileIO(
            fileExists: base.fileExists,
            attributesOfItem: base.attributesOfItem,
            readData: base.readData,
            readDataUpTo: { url, limit in
                recorder.record(url)
                return try base.readDataUpTo(url, limit)
            },
            writeDataAtomically: base.writeDataAtomically,
            createDirectory: base.createDirectory,
            copyItem: base.copyItem,
            moveItem: base.moveItem,
            removeItem: base.removeItem,
            replaceItem: base.replaceItem
        )
    }

    private final class ReadRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []

        var transcriptReads: Int {
            lock.lock(); defer { lock.unlock() }
            return paths.filter { $0.contains(SessionPersistence.transcriptDirectoryName) }.count
        }

        func record(_ url: URL) {
            lock.lock(); paths.append(url.path); lock.unlock()
        }
    }
}
