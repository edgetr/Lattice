import Foundation
import Darwin
import Testing
@testable import LatticeCore

@Suite("Workspace checkpoint store")
struct WorkspaceCheckpointStoreTests {
    private func uniqueRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-checkpoint-store-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func checkpoint(id: UUID, sessionID: UUID, runID: UUID) -> WorkspaceCheckpoint {
        WorkspaceCheckpoint(
            id: id,
            ownership: WorkspaceCheckpointOwnership(
                worktreePath: "/tmp/worktree",
                worktreeIdentity: "identity",
                sessionID: sessionID,
                runID: runID
            ),
            boundary: .beforeRun,
            status: .captured
        )
    }

    @Test func concurrentInstancesSerializeReadModifyWrite() async throws {
        let root = try uniqueRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("workspace-checkpoints.json")
        let stores = (0..<4).map { _ in WorkspaceCheckpointStore(fileURL: url) }
        let sessionID = UUID()
        let runID = UUID()
        let checkpointIDs = (0..<32).map { _ in UUID() }
        let notes = checkpointIDs.map { id in
            WorkspaceReviewNote(
                checkpointID: id,
                sessionID: sessionID,
                runID: runID,
                path: "Sources/Feature.swift",
                body: "Review " + id.uuidString
            )
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in checkpointIDs.indices {
                let store = stores[index % stores.count]
                let row = checkpoint(id: checkpointIDs[index], sessionID: sessionID, runID: runID)
                group.addTask {
                    try store.upsert(row)
                }
            }
            for index in notes.indices {
                let store = stores[(index + 1) % stores.count]
                let note = notes[index]
                group.addTask {
                    try store.appendNote(note)
                }
            }
            try await group.waitForAll()
        }

        let final = try stores[0].load()
        #expect(final.checkpoints.count == checkpointIDs.count)
        #expect(Set(final.checkpoints.map(\.id)) == Set(checkpointIDs))
        #expect(final.notes.count == notes.count)
        #expect(Set(final.notes.map(\.id)) == Set(notes.map(\.id)))
    }

    @Test func concurrentLoadsNeverDecodePartialReplacement() async throws {
        let root = try uniqueRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("workspace-checkpoints.json")
        let store = WorkspaceCheckpointStore(fileURL: url)
        let sessionID = UUID()
        let runID = UUID()
        try store.upsert(checkpoint(id: UUID(), sessionID: sessionID, runID: runID))

        try await withThrowingTaskGroup(of: WorkspaceCheckpointStoreDocument.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    try store.load()
                }
            }
            var snapshots: [WorkspaceCheckpointStoreDocument] = []
            for try await snapshot in group {
                snapshots.append(snapshot)
            }
            #expect(snapshots.count == 64)
            #expect(snapshots.allSatisfy { $0.checkpoints.count == 1 })
        }
    }

    @Test func symlinkAliasParentsShareOneLock() async throws {
        let root = try uniqueRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let alias = root.deletingLastPathComponent().appendingPathComponent("lattice-checkpoint-alias-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: alias) }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let realURL = root.appendingPathComponent("aliased.json")
        let aliasURL = alias.appendingPathComponent("aliased.json")
        let stores = [WorkspaceCheckpointStore(fileURL: realURL), WorkspaceCheckpointStore(fileURL: aliasURL)]
        let sessionID = UUID()
        let runID = UUID()
        let ids = (0..<20).map { _ in UUID() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, id) in ids.enumerated() {
                let store = stores[index % stores.count]
                let row = checkpoint(id: id, sessionID: sessionID, runID: runID)
                group.addTask { try store.upsert(row) }
            }
            try await group.waitForAll()
        }
        let final = try WorkspaceCheckpointStore(fileURL: realURL).load()
        #expect(Set(final.checkpoints.map(\.id)) == Set(ids))
    }

    @Test func oversizedStoreIsRejectedBeforeDecode() throws {
        let root = try uniqueRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("oversized.json")
        try Data(repeating: 0x7B, count: DurableStoreRecovery.maximumStoreByteCount + 1).write(to: url)
        do {
            _ = try WorkspaceCheckpointStore(fileURL: url).load()
            Issue.record("Oversized checkpoint stores must fail closed")
        } catch let error as WorkspaceCheckpointError {
            guard case .storeUnreadable(let detail) = error else {
                Issue.record("Oversized checkpoint store should map to storeUnreadable")
                return
            }
            #expect(detail.contains("limit"))
        }
    }

    @Test func symlinkAndSpecialStoreTargetsAreRejectedWithoutBlocking() throws {
        let root = try uniqueRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.json")
        try Data("{}".utf8).write(to: target)
        let link = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        do {
            _ = try WorkspaceCheckpointStore(fileURL: link).load()
            Issue.record("Symlinked checkpoint stores must be rejected")
        } catch let error as WorkspaceCheckpointError {
            guard case .storeUnreadable = error else { Issue.record("Symlink should map to storeUnreadable"); return }
        }
        do {
            try WorkspaceCheckpointStore(fileURL: link).save(.init())
            Issue.record("Symlinked checkpoint stores must reject writes")
        } catch let error as WorkspaceCheckpointError {
            guard case .storeWriteFailed = error else { Issue.record("Symlink write should map to storeWriteFailed"); return }
        }

        let fifo = root.appendingPathComponent("pipe.json")
        #expect(mkfifo(fifo.path, mode_t(0o600)) == 0)
        do {
            _ = try WorkspaceCheckpointStore(fileURL: fifo).load()
            Issue.record("Special checkpoint stores must be rejected")
        } catch let error as WorkspaceCheckpointError {
            guard case .storeUnreadable = error else { Issue.record("Special file should map to storeUnreadable"); return }
        }
        do {
            try WorkspaceCheckpointStore(fileURL: fifo).save(.init())
            Issue.record("Special checkpoint stores must reject writes")
        } catch let error as WorkspaceCheckpointError {
            guard case .storeWriteFailed = error else { Issue.record("Special-file write should map to storeWriteFailed"); return }
        }
    }

    @Test func oversizedEncodedSavePreservesExistingStore() throws {
        let root = try uniqueRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("bounded.json")
        let store = WorkspaceCheckpointStore(fileURL: url)
        let originalID = UUID()
        let sessionID = UUID()
        let runID = UUID()
        try store.save(.init(checkpoints: [checkpoint(id: originalID, sessionID: sessionID, runID: runID)]))

        var oversized = checkpoint(id: UUID(), sessionID: sessionID, runID: runID)
        oversized.failureSummary = String(repeating: "x", count: DurableStoreRecovery.maximumStoreByteCount + 1)
        do {
            try store.save(.init(checkpoints: [oversized]))
            Issue.record("Oversized encoded checkpoint stores must fail")
        } catch let error as WorkspaceCheckpointError {
            guard case .storeWriteFailed(let detail) = error else {
                Issue.record("Oversized save should map to storeWriteFailed")
                return
            }
            #expect(detail.contains("Existing data was preserved"))
        }
        let preserved = try store.load()
        #expect(preserved.checkpoints.map(\.id) == [originalID])
        let children = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!children.contains(where: { $0.hasPrefix(".bounded.json.tmp-") }))
    }

    @Test func unsafeDefaultStoreNameFallsBackToContainedBasename() {
        #expect(WorkspaceCheckpointStore.normalizedDefaultStoreFileName("../escaped.json") == WorkspaceCheckpointStore.defaultFileName)
        #expect(WorkspaceCheckpointStore.normalizedDefaultStoreFileName("nested/file.json") == WorkspaceCheckpointStore.defaultFileName)
        #expect(WorkspaceCheckpointStore.normalizedDefaultStoreFileName("safe.json") == "safe.json")
    }

    @Test func futureSchemaAndMalformedLegacyNotesFailClosed() throws {
        let futureData = try JSONSerialization.data(withJSONObject: [
            "version": WorkspaceCheckpointStoreDocument.currentVersion + 1,
            "checkpoints": [],
            "notes": []
        ])
        do {
            _ = try WorkspaceCheckpointStore.decodeMigrating(futureData)
            Issue.record("Future checkpoint store schema must be rejected")
        } catch let error as WorkspaceCheckpointError {
            guard case .storeUnreadable(let detail) = error else { Issue.record("Future schema should be unreadable"); return }
            #expect(detail.contains("newer than supported"))
        }

        let malformedNotes = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "checkpoints": [],
            "notes": [["unexpected": true]]
        ])
        do {
            _ = try WorkspaceCheckpointStore.decodeMigrating(malformedNotes)
            Issue.record("Malformed legacy review notes must fail closed")
        } catch let error as WorkspaceCheckpointError {
            guard case .storeUnreadable(let detail) = error else { Issue.record("Malformed notes should be unreadable"); return }
            #expect(detail.contains("review notes are malformed"))
        }
    }

    @Test func appendNoteIsIdempotentByIdentifier() throws {
        let root = try uniqueRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceCheckpointStore(fileURL: root.appendingPathComponent("notes.json"))
        let note = WorkspaceReviewNote(
            id: UUID(),
            checkpointID: UUID(),
            sessionID: UUID(),
            runID: UUID(),
            path: "Sources/Feature.swift",
            body: "Review once"
        )
        try store.appendNote(note)
        try store.appendNote(note)
        #expect(try store.load().notes.map(\.id) == [note.id])
    }

    @Test func symlinkAndSpecialLockFilesAreRejectedWithoutBlocking() throws {
        let root = try uniqueRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("locked.json")
        let lock = root.appendingPathComponent(".locked.json.lock")
        let target = root.appendingPathComponent("lock-target")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: target)
        do {
            _ = try WorkspaceCheckpointStore(fileURL: url).load()
            Issue.record("Symlinked checkpoint lock must be rejected")
        } catch let error as WorkspaceCheckpointError {
            guard case .storeUnreadable = error else { Issue.record("Symlink lock should be unreadable"); return }
        }

        try FileManager.default.removeItem(at: lock)
        #expect(mkfifo(lock.path, mode_t(0o600)) == 0)
        do {
            _ = try WorkspaceCheckpointStore(fileURL: url).load()
            Issue.record("Special checkpoint lock must be rejected")
        } catch let error as WorkspaceCheckpointError {
            guard case .storeUnreadable = error else { Issue.record("Special lock should be unreadable"); return }
        }
    }

    @Test func lockContentionTimesOutQuicklyWithTruthfulReadError() throws {
        let root = try uniqueRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("contended.json")
        let lockURL = root.appendingPathComponent(".contended.json.lock")
        let descriptor = Darwin.open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, mode_t(0o600))
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer { _ = Darwin.close(descriptor) }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        defer { _ = flock(descriptor, LOCK_UN) }

        let start = DispatchTime.now().uptimeNanoseconds
        do {
            _ = try WorkspaceCheckpointStore(fileURL: url).load()
            Issue.record("Contended checkpoint load must time out")
        } catch let error as WorkspaceCheckpointError {
            guard case .storeUnreadable(let detail) = error else { Issue.record("Read contention should be unreadable"); return }
            #expect(detail.contains("Timed out after 0.5 seconds"))
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        #expect(elapsed < 1.5)
    }
}
