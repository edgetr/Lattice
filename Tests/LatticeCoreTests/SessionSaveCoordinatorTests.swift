import Foundation
import Testing
@testable import LatticeCore

@Suite("Session save coordination")
struct SessionSaveCoordinatorTests {
    @Test("a stale debounce cannot overwrite a newer safe-boundary save")
    func staleDebounceIsRevalidatedAfterSerializationLock() {
        let writes = SaveRecorder()
        let enteredDebounceWindow = DispatchSemaphore(value: 0)
        let releaseDebounceWindow = DispatchSemaphore(value: 0)
        let coordinator = SessionSaveCoordinator(
            filePath: "/tmp/lattice-session-save-test.json",
            writeGate: DurableStoreWriteGate(),
            debounceNanoseconds: 0,
            saveHandler: { snapshot in writes.record(snapshot) },
            debounceQueue: DispatchQueue(label: "com.lattice.tests.session-save-stale")
        )
        coordinator.beforeDebouncedSaveLockHook = {
            enteredDebounceWindow.signal()
            _ = releaseDebounceWindow.wait(timeout: .now() + 5)
        }

        coordinator.scheduleDebounced([makeSession(title: "old")])
        #expect(enteredDebounceWindow.wait(timeout: .now() + 5) == .success)

        #expect(coordinator.saveNow([makeSession(title: "new")]) == .saved)
        releaseDebounceWindow.signal()

        // Wait for the fired work item to observe the superseded generation.
        for _ in 0..<100 where coordinator.hasPendingDebouncedSave {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(!coordinator.hasPendingDebouncedSave)
        #expect(writes.titles == ["new"])
    }

    @Test("a debounce that acquires the lock first still yields to a concurrent immediate save")
    func immediateSaveFollowsDebounceThatAlreadyStarted() {
        let writes = SaveRecorder()
        let oldSaveStarted = DispatchSemaphore(value: 0)
        let releaseOldSave = DispatchSemaphore(value: 0)
        let immediateSaveFinished = DispatchSemaphore(value: 0)
        let newSnapshot = [makeSession(title: "new")]
        let coordinator = SessionSaveCoordinator(
            filePath: "/tmp/lattice-session-save-test.json",
            writeGate: DurableStoreWriteGate(),
            debounceNanoseconds: 0,
            saveHandler: { snapshot in
                if snapshot.first?.title == "old" {
                    oldSaveStarted.signal()
                    _ = releaseOldSave.wait(timeout: .now() + 5)
                }
                writes.record(snapshot)
            },
            debounceQueue: DispatchQueue(label: "com.lattice.tests.session-save-order")
        )

        coordinator.scheduleDebounced([makeSession(title: "old")])
        #expect(oldSaveStarted.wait(timeout: .now() + 5) == .success)

        DispatchQueue.global().async {
            _ = coordinator.saveNow(newSnapshot)
            immediateSaveFinished.signal()
        }
        releaseOldSave.signal()

        #expect(immediateSaveFinished.wait(timeout: .now() + 5) == .success)
        #expect(writes.titles == ["old", "new"])
    }

    @Test("a newer schedule registered during an immediate write runs afterward")
    func concurrentScheduleCannotBeOvertakenByOlderImmediateSave() {
        let writes = SaveRecorder()
        let oldSaveStarted = DispatchSemaphore(value: 0)
        let releaseOldSave = DispatchSemaphore(value: 0)
        let scheduleInvoked = DispatchSemaphore(value: 0)
        let scheduleReturned = DispatchSemaphore(value: 0)
        let oldSnapshot = [makeSession(title: "old")]
        let newSnapshot = [makeSession(title: "new")]
        let coordinator = SessionSaveCoordinator(
            filePath: "/tmp/lattice-session-save-test.json",
            writeGate: DurableStoreWriteGate(),
            debounceNanoseconds: 0,
            saveHandler: { snapshot in
                if snapshot.first?.title == "old" {
                    oldSaveStarted.signal()
                    _ = releaseOldSave.wait(timeout: .now() + 5)
                }
                writes.record(snapshot)
            },
            debounceQueue: DispatchQueue(label: "com.lattice.tests.session-save-newer-schedule")
        )

        DispatchQueue.global().async {
            _ = coordinator.saveNow(oldSnapshot)
        }
        #expect(oldSaveStarted.wait(timeout: .now() + 5) == .success)
        DispatchQueue.global().async {
            scheduleInvoked.signal()
            coordinator.scheduleDebounced(newSnapshot)
            scheduleReturned.signal()
        }
        #expect(scheduleInvoked.wait(timeout: .now() + 5) == .success)
        releaseOldSave.signal()
        #expect(scheduleReturned.wait(timeout: .now() + 5) == .success)

        for _ in 0..<500 where writes.titles.count < 2 {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(writes.titles == ["old", "new"])
    }

    @Test("failure observer may synchronously retry without deadlocking")
    func synchronousFailureObserverCanReenter() {
        let attempts = AttemptCounter()
        let reentry = SaveCoordinatorReentry()
        let coordinator = SessionSaveCoordinator(
            filePath: "/tmp/lattice-session-save-test.json",
            writeGate: DurableStoreWriteGate(),
            saveHandler: { _ in
                if attempts.incrementAndRead() == 1 {
                    throw NSError(domain: "SessionSaveCoordinatorTests", code: 7)
                }
            },
            failureObserver: { failure in
                reentry.observe(failure)
            }
        )
        reentry.coordinator = coordinator

        guard case .failed = coordinator.saveNow([makeSession(title: "first")]) else {
            Issue.record("First write should fail")
            return
        }
        #expect(reentry.finished.wait(timeout: .now() + 5) == .success)
        #expect(attempts.value == 2)
        #expect(reentry.didReenter)
        #expect(coordinator.currentFailure == nil)
    }

    @Test("failure notifications retain write order across concurrent saves")
    func failureNotificationsCannotArriveAfterNewerSuccess() {
        let attempts = AttemptCounter()
        let observations = FailureObservationRecorder()
        let coordinator = SessionSaveCoordinator(
            filePath: "/tmp/lattice-session-save-test.json",
            writeGate: DurableStoreWriteGate(),
            saveHandler: { _ in
                if attempts.incrementAndRead() == 1 {
                    throw NSError(domain: "SessionSaveCoordinatorTests", code: 9)
                }
            },
            failureObserver: { failure in
                observations.record(failure)
            }
        )

        guard case .failed = coordinator.saveNow([makeSession(title: "failed")]) else {
            Issue.record("First write should fail")
            return
        }
        #expect(coordinator.saveNow([makeSession(title: "saved")]) == .saved)
        #expect(observations.finished.wait(timeout: .now() + 5) == .success)
        #expect(observations.states == ["failed", "cleared"])
    }

    private func makeSession(title: String) -> LatticeSession {
        LatticeSession(title: title, backend: .codex(model: "test-model"))
    }
}

private final class SaveRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedTitles: [String] = []

    func record(_ snapshot: [LatticeSession]) {
        lock.lock()
        recordedTitles.append(snapshot.first?.title ?? "")
        lock.unlock()
    }

    var titles: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedTitles
    }
}

private final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func incrementAndRead() -> Int {
        lock.lock()
        count += 1
        let value = count
        lock.unlock()
        return value
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class SaveCoordinatorReentry: @unchecked Sendable {
    private let lock = NSLock()
    var coordinator: SessionSaveCoordinator?
    private var reentered = false
    let finished = DispatchSemaphore(value: 0)

    var didReenter: Bool {
        lock.lock()
        defer { lock.unlock() }
        return reentered
    }

    func observe(_ failure: SessionSaveFailure?) {
        guard failure != nil else { return }
        lock.lock()
        guard !reentered else {
            lock.unlock()
            return
        }
        reentered = true
        let coordinator = coordinator
        lock.unlock()
        _ = coordinator?.saveNow([LatticeSession(title: "retry", backend: .codex(model: "test-model"))])
        finished.signal()
    }
}

private final class FailureObservationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedStates: [String] = []
    let finished = DispatchSemaphore(value: 0)

    func record(_ failure: SessionSaveFailure?) {
        lock.lock()
        recordedStates.append(failure == nil ? "cleared" : "failed")
        let complete = recordedStates.count == 2
        lock.unlock()
        if complete { finished.signal() }
    }

    var states: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedStates
    }
}
