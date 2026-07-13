import Testing
import Foundation
@testable import LatticeCore

@Suite("Session save coordinator")
struct SessionSaveCoordinatorTests {

    // MARK: - Helpers

    private func sampleSession(title: String = "Chat", draft: String = "") -> LatticeSession {
        LatticeSession(title: title, backend: .codex(model: "gpt-5.4"), draft: draft)
    }

    private func makeCoordinator(
        filePath: String = "/tmp/lattice-test-sessions.json",
        gate: DurableStoreWriteGate = DurableStoreWriteGate(),
        debounceNanoseconds: UInt64 = 250_000_000,
        saveHandler: @escaping SessionSaveCoordinator.SaveHandler,
        now: @escaping SessionSaveCoordinator.Clock = { Date(timeIntervalSince1970: 1_700_000_000) },
        failures: LockBox<SessionSaveFailure?>? = nil
    ) -> SessionSaveCoordinator {
        SessionSaveCoordinator(
            storeID: SessionPersistence.storeID,
            storeName: SessionPersistence.storeName,
            filePath: filePath,
            writeGate: gate,
            debounceNanoseconds: debounceNanoseconds,
            saveHandler: saveHandler,
            now: now,
            failureObserver: { failure in
                failures?.value = failure
            }
        )
    }

    private func diskFullError() -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(ENOSPC),
            userInfo: [NSLocalizedDescriptionKey: "No space left on device"]
        )
    }

    private func permissionError() -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(EACCES),
            userInfo: [NSLocalizedDescriptionKey: "Permission denied"]
        )
    }

    private func writeFailedError() -> NSError {
        NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteUnknownError,
            userInfo: [NSLocalizedDescriptionKey: "Atomic replacement failed"]
        )
    }

    // MARK: - Failure visibility / classification

    @Test func classifiesDiskFullPermissionAndWriteFailures() {
        #expect(SessionSaveFailureClassifier.kind(for: diskFullError()) == .diskFull)
        #expect(SessionSaveFailureClassifier.kind(for: permissionError()) == .permissionDenied)
        #expect(SessionSaveFailureClassifier.kind(for: writeFailedError()) == .writeFailed)

        let cocoaDisk = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError, userInfo: nil)
        #expect(SessionSaveFailureClassifier.kind(for: cocoaDisk) == .diskFull)
        let readOnly = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteVolumeReadOnlyError, userInfo: nil)
        #expect(SessionSaveFailureClassifier.kind(for: readOnly) == .permissionDenied)

        let blocked = DurableStoreRecoveryError.writeBlocked(storeName: "Chat sessions")
        #expect(SessionSaveFailureClassifier.isWriteBlocked(blocked))
    }

    @Test func saveFailureIsVisibleAndSeparateFromLoadRecoveryIssue() {
        let failures = LockBox<SessionSaveFailure?>(nil)
        let coordinator = makeCoordinator(
            saveHandler: { _ in throw self.diskFullError() },
            failures: failures
        )

        let result = coordinator.saveNow([sampleSession(draft: "keep me")])
        guard case .failed(let failure) = result else {
            Issue.record("Disk-full save must surface as .failed")
            return
        }
        #expect(failure.kind == .diskFull)
        #expect(failure.summary.contains("in memory"))
        #expect(failure.technicalDetails.contains("Category: save/diskFull"))
        #expect(failure.storeID == SessionPersistence.storeID)
        #expect(coordinator.currentFailure?.fingerprint == failure.fingerprint)
        #expect(failures.value?.fingerprint == failure.fingerprint)

        // Save failures are not DurableStoreIssue load-recovery kinds.
        #expect(failure.kind.rawValue != DurableStoreIssueKind.corrupt.rawValue)
        #expect(failure.kind.rawValue != DurableStoreIssueKind.unreadable.rawValue)
    }

    // MARK: - Retry with latest data

    @Test func retryWritesLatestSnapshotNotStaleFailedOne() {
        let written = LockBox<[LatticeSession]?>(nil)
        let shouldFail = LockBox(true)
        let coordinator = makeCoordinator(
            saveHandler: { sessions in
                if shouldFail.value {
                    throw self.permissionError()
                }
                written.value = sessions
            }
        )

        let stale = [sampleSession(title: "Stale", draft: "old draft")]
        let latest = [sampleSession(title: "Latest", draft: "newest exact draft")]

        let first = coordinator.saveNow(stale)
        guard case .failed = first else {
            Issue.record("Expected initial permission failure")
            return
        }
        #expect(written.value == nil)

        shouldFail.value = false
        let retryResult = coordinator.retry(latest)
        #expect(retryResult == .saved)
        #expect(coordinator.currentFailure == nil)
        #expect(written.value?.count == 1)
        #expect(written.value?.first?.draft == "newest exact draft")
        #expect(written.value?.first?.title == "Latest")
    }

    // MARK: - Coalescing debounced drafts

    @Test func debouncedSavesCoalesceToLatestSnapshot() async throws {
        let written = LockBox<[LatticeSession]?>(nil)
        let writeCount = LockBox(0)
        let coordinator = makeCoordinator(
            debounceNanoseconds: 10_000_000,
            saveHandler: { sessions in
                writeCount.value += 1
                written.value = sessions
            }
        )

        coordinator.scheduleDebounced([sampleSession(draft: "one")])
        coordinator.scheduleDebounced([sampleSession(draft: "two")])
        coordinator.scheduleDebounced([sampleSession(draft: "three exact")])
        #expect(coordinator.hasPendingDebouncedSave)
        #expect(coordinator.pendingDebouncedSnapshot?.first?.draft == "three exact")

        // Cancelled work items may still be dequeued; only the latest generation writes.
        try await waitUntil { writeCount.value == 1 }

        #expect(writeCount.value == 1)
        #expect(written.value?.first?.draft == "three exact")
        #expect(!coordinator.hasPendingDebouncedSave)
    }

    @Test func semanticDraftAndStreamingSchedulesShareLatestSnapshotCoalescing() async throws {
        let writeCount = LockBox(0)
        let written = LockBox<[LatticeSession]?>(nil)
        let coordinator = makeCoordinator(
            debounceNanoseconds: 10_000_000,
            saveHandler: { sessions in
                writeCount.value += 1
                written.value = sessions
            }
        )

        coordinator.scheduleDraftSnapshot([sampleSession(draft: "typed")])
        var partial = sampleSession(draft: "typed")
        partial.messages = [
            ChatMessage(role: .user, text: "Question"),
            ChatMessage(role: .assistant, text: "Partial answer")
        ]
        partial.isStreaming = true
        coordinator.scheduleStreamingSnapshot([partial])

        try await waitUntil { writeCount.value == 1 }
        #expect(writeCount.value == 1)
        #expect(written.value?.first?.messages.last?.text == "Partial answer")
        #expect(written.value?.first?.isStreaming == true)
    }

    @Test func rapidReschedulingKeepsOnlyTheLatestGeneration() async throws {
        let writeCount = LockBox(0)
        let writtenDraft = LockBox<String?>(nil)
        let coordinator = makeCoordinator(
            debounceNanoseconds: 100_000_000,
            saveHandler: { sessions in
                writeCount.value += 1
                writtenDraft.value = sessions.first?.draft
            }
        )

        for index in 0..<2_000 {
            coordinator.scheduleDebounced([sampleSession(draft: "draft-\(index)")])
        }

        try await waitUntil(timeoutNanoseconds: 500_000_000) { writeCount.value == 1 }
        #expect(writeCount.value == 1)
        #expect(writtenDraft.value == "draft-1999")
        #expect(!coordinator.hasPendingDebouncedSave)
    }

    // MARK: - Immediate / termination flush

    @Test func immediateSaveCancelsPendingDebouncedWrite() async throws {
        let written = LockBox<[String]>([])
        let coordinator = makeCoordinator(
            debounceNanoseconds: 10_000_000,
            saveHandler: { sessions in
                written.value.append(sessions.first?.draft ?? "")
            }
        )

        coordinator.scheduleDebounced([sampleSession(draft: "pending draft")])
        #expect(coordinator.hasPendingDebouncedSave)

        let result = coordinator.saveNow([sampleSession(draft: "immediate boundary")])
        #expect(result == .saved)
        #expect(!coordinator.hasPendingDebouncedSave)
        #expect(written.value == ["immediate boundary"])

        // A cancelled work item reaching its deadline must not perform a second write.
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(written.value == ["immediate boundary"])
    }

    @Test func overlappingCallersSerializeWritesAndLatestBoundaryFinishesLast() async throws {
        let releaseFirstWrite = DispatchSemaphore(value: 0)
        let writeCount = LockBox(0)
        let written = LockBox<[String]>([])
        let coordinator = makeCoordinator(
            saveHandler: { sessions in
                writeCount.value += 1
                if writeCount.value == 1 {
                    releaseFirstWrite.wait()
                }
                written.value.append(sessions.first?.draft ?? "")
            }
        )
        let olderSnapshot = [sampleSession(draft: "older fired debounce")]
        let latestSnapshot = [sampleSession(draft: "latest safe boundary")]

        let first = Task.detached {
            coordinator.saveNow(olderSnapshot)
        }
        try await waitUntil { writeCount.value == 1 }

        let latest = Task.detached {
            coordinator.flush(latestSnapshot)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(writeCount.value == 1)

        releaseFirstWrite.signal()
        #expect(await first.value == .saved)
        #expect(await latest.value == .saved)
        #expect(written.value == ["older fired debounce", "latest safe boundary"])
    }

    @Test func terminationFlushWritesExactLatestDraftSnapshot() {
        let written = LockBox<[LatticeSession]?>(nil)
        let coordinator = makeCoordinator(
            saveHandler: { sessions in written.value = sessions }
        )

        coordinator.scheduleDebounced([sampleSession(draft: "stale pending")])
        let exact = [sampleSession(title: "Selected", draft: "typed before debounce expired\n  exact  ")]
        let result = coordinator.flush(exact)

        #expect(result == .saved)
        #expect(!coordinator.hasPendingDebouncedSave)
        #expect(written.value?.first?.draft == "typed before debounce expired\n  exact  ")
        #expect(written.value?.first?.title == "Selected")
    }

    // MARK: - Error storm suppression

    @Test func repeatedEquivalentFailuresCoalesceWithoutReNotifyStorm() {
        let notifyCount = LockBox(0)
        let lastNotified = LockBox<SessionSaveFailure?>(nil)
        let coordinator = SessionSaveCoordinator(
            storeID: SessionPersistence.storeID,
            storeName: SessionPersistence.storeName,
            filePath: "/tmp/sessions.json",
            writeGate: DurableStoreWriteGate(),
            saveHandler: { _ in throw self.diskFullError() },
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            failureObserver: { failure in
                notifyCount.value += 1
                lastNotified.value = failure
            }
        )

        let first = coordinator.saveNow([sampleSession()])
        let second = coordinator.saveNow([sampleSession(draft: "again")])
        let third = coordinator.saveNow([sampleSession(draft: "and again")])

        guard case .failed(let failure) = first else {
            Issue.record("First failure must notify")
            return
        }
        #expect(notifyCount.value == 1)
        guard case .coalescedFailure(let coalesced) = second else {
            Issue.record("Second equivalent failure must coalesce")
            return
        }
        guard case .coalescedFailure = third else {
            Issue.record("Third equivalent failure must coalesce")
            return
        }
        #expect(coalesced.fingerprint == failure.fingerprint)
        #expect(notifyCount.value == 1)
        #expect(lastNotified.value?.fingerprint == failure.fingerprint)
    }

    @Test func laterSuccessClearsSaveFailureStatus() {
        let failures = LockBox<SessionSaveFailure?>(nil)
        let shouldFail = LockBox(true)
        let coordinator = makeCoordinator(
            saveHandler: { _ in
                if shouldFail.value { throw self.writeFailedError() }
            },
            failures: failures
        )

        _ = coordinator.saveNow([sampleSession()])
        #expect(coordinator.currentFailure?.kind == .writeFailed)
        #expect(failures.value != nil)

        shouldFail.value = false
        let result = coordinator.saveNow([sampleSession(draft: "recovered")])
        #expect(result == .saved)
        #expect(coordinator.currentFailure == nil)
        #expect(failures.value == nil)
    }

    @Test func differentFailureKindsStillUpdateStatus() {
        let localNotify = LockBox(0)
        let shouldUseDiskFull = LockBox(false)
        let coordinator = SessionSaveCoordinator(
            storeID: SessionPersistence.storeID,
            storeName: SessionPersistence.storeName,
            filePath: "/tmp/sessions.json",
            writeGate: DurableStoreWriteGate(),
            saveHandler: { _ in
                if shouldUseDiskFull.value {
                    throw self.diskFullError()
                }
                throw self.permissionError()
            },
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            failureObserver: { _ in localNotify.value += 1 }
        )
        _ = coordinator.saveNow([sampleSession()])
        #expect(localNotify.value == 1)
        #expect(coordinator.currentFailure?.kind == .permissionDenied)

        shouldUseDiskFull.value = true
        let second = coordinator.saveNow([sampleSession()])
        guard case .failed(let failure) = second else {
            Issue.record("Different failure kind must notify as a new failure")
            return
        }
        #expect(failure.kind == .diskFull)
        #expect(localNotify.value == 2)
    }

    // MARK: - Blocked gate

    @Test func blockedWriteGateNeverWritesAndDoesNotBecomeSaveFailure() {
        let writeCount = LockBox(0)
        let failures = LockBox<SessionSaveFailure?>(nil)
        let gate = DurableStoreWriteGate()
        gate.block()
        let coordinator = makeCoordinator(
            gate: gate,
            saveHandler: { _ in
                writeCount.value += 1
            },
            failures: failures
        )

        let immediate = coordinator.saveNow([sampleSession(draft: "nope")])
        let flush = coordinator.flush([sampleSession(draft: "nope flush")])
        let retry = coordinator.retry([sampleSession(draft: "nope retry")])
        coordinator.scheduleDebounced([sampleSession(draft: "nope draft")])

        #expect(immediate == .blockedByWriteGate)
        #expect(flush == .blockedByWriteGate)
        #expect(retry == .blockedByWriteGate)
        #expect(writeCount.value == 0)
        #expect(coordinator.currentFailure == nil)
        #expect(failures.value == nil)
    }

    @Test func writeBlockedErrorFromHandlerIsNotSurfacedAsSaveFailure() {
        let failures = LockBox<SessionSaveFailure?>(nil)
        let coordinator = makeCoordinator(
            saveHandler: { _ in
                throw DurableStoreRecoveryError.writeBlocked(storeName: SessionPersistence.storeName)
            },
            failures: failures
        )

        let result = coordinator.saveNow([sampleSession()])
        #expect(result == .blockedByWriteGate)
        #expect(coordinator.currentFailure == nil)
        #expect(failures.value == nil)
    }

    @Test func persistenceIntegrationSaveThroughCoordinatorRespectsGateAndExactDraft() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("sessions.json")
        let gate = DurableStoreWriteGate()
        let persistence = SessionPersistence(fileURL: url, writeGate: gate)
        let coordinator = SessionSaveCoordinator(persistence: persistence)

        gate.block()
        #expect(coordinator.saveNow([sampleSession(draft: "blocked")]) == .blockedByWriteGate)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(coordinator.currentFailure == nil)

        gate.unblock()
        let exactDraft = "termination draft\nwith exact whitespace  "
        let sessions = [sampleSession(title: "A", draft: exactDraft)]
        #expect(coordinator.flush(sessions) == .saved)

        switch persistence.loadResult() {
        case .loaded(let loaded):
            #expect(loaded.count == 1)
            #expect(loaded.first?.draft == exactDraft)
        case .missing, .failed:
            Issue.record("Flushed sessions must load with exact draft content")
        }
    }
}

// MARK: - Test utilities

/// Simple mutex box for capturing values from @Sendable closures in tests.
private final class LockBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

private func waitUntil(
    timeoutNanoseconds: UInt64 = 500_000_000,
    pollNanoseconds: UInt64 = 2_000_000,
    condition: @Sendable () -> Bool
) async throws {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if condition() { return }
        try await Task.sleep(nanoseconds: pollNanoseconds)
    }
    if !condition() {
        Issue.record("Timed out waiting for condition")
    }
}
