import Foundation

// MARK: - Save failure model (separate from load-recovery DurableStoreIssue)

/// Classifies durable session *save* failures. These are write-path problems, not corrupt/unreadable load recovery.
public enum SessionSaveFailureKind: String, Sendable, Hashable, Codable {
    case diskFull
    case permissionDenied
    case writeFailed

    public var displayName: String {
        switch self {
        case .diskFull: "Disk full"
        case .permissionDenied: "Permission denied"
        case .writeFailed: "Write failed"
        }
    }
}

/// Evidence for a failed session save. Intentionally does not offer reset/quarantine of readable on-disk data.
public struct SessionSaveFailure: Sendable, Hashable, Identifiable, Codable {
    public let storeID: String
    public let storeName: String
    public let filePath: String
    public let kind: SessionSaveFailureKind
    public let summary: String
    public let technicalDetails: String
    public let occurredAt: Date
    /// Stable fingerprint used to coalesce repeated equivalent failures.
    public let fingerprint: String

    public var id: String { fingerprint }

    public init(
        storeID: String,
        storeName: String,
        filePath: String,
        kind: SessionSaveFailureKind,
        summary: String,
        technicalDetails: String,
        occurredAt: Date,
        fingerprint: String
    ) {
        self.storeID = storeID
        self.storeName = storeName
        self.filePath = filePath
        self.kind = kind
        self.summary = summary
        self.technicalDetails = technicalDetails
        self.occurredAt = occurredAt
        self.fingerprint = fingerprint
    }
}

/// Outcome of a save attempt. Gate-blocked writes are not failures.
public enum SessionSaveAttemptResult: Sendable, Equatable {
    /// Write succeeded; any prior save-failure status is cleared.
    case saved
    /// Write gate is blocked (load recovery). No IO, no failure UI.
    case blockedByWriteGate
    /// Write failed and the active failure status was set or refreshed.
    case failed(SessionSaveFailure)
    /// Write failed with the same fingerprint as the already-visible failure (error-storm suppression).
    case coalescedFailure(SessionSaveFailure)
}

// MARK: - Classification

public enum SessionSaveFailureClassifier: Sendable {
    /// Classifies Foundation/POSIX/Cocoa write failures from direct error evidence.
    public static func kind(for error: Error) -> SessionSaveFailureKind {
        if isWriteBlocked(error) {
            // Callers should not surface write-blocked as a save failure; kind is only a fallback.
            return .writeFailed
        }
        if isDiskFull(error) { return .diskFull }
        if isPermissionDenied(error) { return .permissionDenied }
        return .writeFailed
    }

    public static func isWriteBlocked(_ error: Error) -> Bool {
        if let recovery = error as? DurableStoreRecoveryError, case .writeBlocked = recovery {
            return true
        }
        return false
    }

    public static func isDiskFull(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOSPC) {
            return true
        }
        if nsError.domain == NSCocoaErrorDomain {
            let codes: Set<Int> = [NSFileWriteOutOfSpaceError]
            if codes.contains(nsError.code) { return true }
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isDiskFull(underlying)
        }
        return false
    }

    public static func isPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            let codes: Set<Int> = [Int(EACCES), Int(EPERM)]
            if codes.contains(nsError.code) { return true }
        }
        if nsError.domain == NSCocoaErrorDomain {
            let codes: Set<Int> = [
                NSFileWriteNoPermissionError,
                NSFileWriteInvalidFileNameError,
                NSFileWriteVolumeReadOnlyError
            ]
            if codes.contains(nsError.code) { return true }
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isPermissionDenied(underlying)
        }
        return false
    }

    public static func makeFailure(
        storeID: String,
        storeName: String,
        filePath: String,
        error: Error,
        occurredAt: Date
    ) -> SessionSaveFailure {
        let kind = kind(for: error)
        let nsError = error as NSError
        let summary: String
        switch kind {
        case .diskFull:
            summary = "\(storeName) could not be saved because the disk is full. Your work remains in memory."
        case .permissionDenied:
            summary = "\(storeName) could not be saved due to a permission error. Your work remains in memory."
        case .writeFailed:
            summary = "\(storeName) could not be saved. Your work remains in memory."
        }
        var lines: [String] = [
            "Path: \(filePath)",
            "Category: save/\(kind.rawValue)",
            "Domain: \(nsError.domain)",
            "Code: \(nsError.code)",
            "Description: \(nsError.localizedDescription)"
        ]
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            lines.append("Underlying: \(underlying.domain) (\(underlying.code)) \(underlying.localizedDescription)")
        }
        let fingerprint = "\(storeID)|\(kind.rawValue)|\(nsError.domain)|\(nsError.code)|\(filePath)"
        return SessionSaveFailure(
            storeID: storeID,
            storeName: storeName,
            filePath: filePath,
            kind: kind,
            summary: summary,
            technicalDetails: lines.joined(separator: "\n"),
            occurredAt: occurredAt,
            fingerprint: fingerprint
        )
    }
}

// MARK: - Coordinator

/// Coalesces debounced draft writes, supports immediate/safe-boundary and termination flushes,
/// and reports save failures separately from load-recovery write gates.
///
/// Intended for single-threaded (MainActor) use in the app; locks protect shared state for tests.
public final class SessionSaveCoordinator: @unchecked Sendable {
    public typealias SaveHandler = @Sendable ([LatticeSession]) throws -> Void
    public typealias FailureObserver = @Sendable (SessionSaveFailure?) -> Void
    public typealias Clock = @Sendable () -> Date

    public let storeID: String
    public let storeName: String
    public let filePath: String
    public let writeGate: DurableStoreWriteGate
    public let debounceNanoseconds: UInt64

    private let saveHandler: SaveHandler
    private let debounceQueue: DispatchQueue
    private let failureNotificationQueue: DispatchQueue
    private let failureNotificationQueueKey = DispatchSpecificKey<UInt8>()
    private let now: Clock
    private let lock = NSLock()
    /// Serializes filesystem writes even when tests or a future caller invoke the coordinator
    /// from more than one executor. This also guarantees a safe-boundary save that races a
    /// fired debounce is the final (latest) write.
    private let saveLock = NSLock()
    /// Bridges write serialization to failure-notification enqueueing. A writer
    /// acquires this while it still owns `saveLock`, releases `saveLock`, then
    /// enqueues. This preserves write order without allowing observer code to
    /// begin while the corresponding write lock is held.
    private let notificationOrderLock = NSLock()

    private var pendingSnapshot: [LatticeSession]?
    private var pendingWorkItem: DispatchWorkItem?
    private var debounceGeneration: UInt64 = 0
    private var activeFailure: SessionSaveFailure?
    private var failureObserver: FailureObserver?

    /// Test seam used to deterministically pause a fired debounce between its
    /// generation check and the save serialization lock. Production callers
    /// leave this nil.
    internal var beforeDebouncedSaveLockHook: (@Sendable () -> Void)? = nil

    public init(
        storeID: String = SessionPersistence.storeID,
        storeName: String = SessionPersistence.storeName,
        filePath: String,
        writeGate: DurableStoreWriteGate,
        debounceNanoseconds: UInt64 = 250_000_000,
        saveHandler: @escaping SaveHandler,
        debounceQueue: DispatchQueue = DispatchQueue(
            label: "com.lattice.session-save-debounce",
            qos: .userInitiated
        ),
        now: @escaping Clock = { Date() },
        failureObserver: FailureObserver? = nil
    ) {
        self.storeID = storeID
        self.storeName = storeName
        self.filePath = filePath
        self.writeGate = writeGate
        self.debounceNanoseconds = debounceNanoseconds
        self.saveHandler = saveHandler
        self.debounceQueue = debounceQueue
        // Always own the callback queue so FIFO ordering cannot be weakened by
        // a caller injecting a concurrent target.
        self.failureNotificationQueue = DispatchQueue(
            label: "com.lattice.session-save-failure-notifications",
            qos: .userInitiated
        )
        self.now = now
        self.failureObserver = failureObserver
        self.failureNotificationQueue.setSpecific(key: failureNotificationQueueKey, value: 1)
    }

    /// Convenience that saves through a `SessionPersistence` instance.
    public convenience init(
        persistence: SessionPersistence,
        debounceNanoseconds: UInt64 = 250_000_000,
        debounceQueue: DispatchQueue = DispatchQueue(
            label: "com.lattice.session-save-debounce",
            qos: .userInitiated
        ),
        now: @escaping Clock = { Date() },
        failureObserver: FailureObserver? = nil
    ) {
        self.init(
            storeID: SessionPersistence.storeID,
            storeName: SessionPersistence.storeName,
            filePath: persistence.fileURL.path,
            writeGate: persistence.writeGate,
            debounceNanoseconds: debounceNanoseconds,
            saveHandler: { sessions in try persistence.save(sessions) },
            debounceQueue: debounceQueue,
            now: now,
            failureObserver: failureObserver
        )
    }

    public func setFailureObserver(_ observer: FailureObserver?) {
        lock.lock()
        failureObserver = observer
        lock.unlock()
    }

    public var currentFailure: SessionSaveFailure? {
        lock.lock(); defer { lock.unlock() }
        return activeFailure
    }

    public var hasPendingDebouncedSave: Bool {
        lock.lock(); defer { lock.unlock() }
        return pendingSnapshot != nil
    }

    /// Latest snapshot waiting for a debounced write, if any.
    public var pendingDebouncedSnapshot: [LatticeSession]? {
        lock.lock(); defer { lock.unlock() }
        return pendingSnapshot
    }

    /// Schedule a coalesced debounced snapshot write. Later schedules replace earlier snapshots.
    /// Used for drafts and high-frequency streaming/action progress where writing every delta would
    /// amplify full-store JSON serialization. Semantic wrappers below keep call sites explicit.
    public func scheduleDebounced(_ sessions: [LatticeSession]) {
        // Linearize schedule registration with immediate writes. Whichever
        // operation takes saveLock first defines the authoritative order.
        saveLock.lock()
        lock.lock()
        pendingSnapshot = sessions
        pendingWorkItem?.cancel()
        debounceGeneration &+= 1
        let generation = debounceGeneration
        let delay = debounceNanoseconds
        let workItem = DispatchWorkItem { [weak self] in
            self?.performPendingDebouncedSave(ifGenerationIs: generation)
        }
        pendingWorkItem = workItem
        lock.unlock()
        saveLock.unlock()

        let clampedDelay = Int(min(delay, UInt64(Int.max)))
        debounceQueue.asyncAfter(
            deadline: .now() + .nanoseconds(clampedDelay),
            execute: workItem
        )
    }

    /// Coalesced durability for ordinary composer edits.
    public func scheduleDraftSnapshot(_ sessions: [LatticeSession]) {
        scheduleDebounced(sessions)
    }

    /// Coalesced durability for partial assistant text and nonterminal action progress.
    public func scheduleStreamingSnapshot(_ sessions: [LatticeSession]) {
        scheduleDebounced(sessions)
    }

    /// Immediate save at a safe boundary. Cancels and absorbs any pending debounced draft into this write
    /// when the caller passes the latest exact snapshot (pending is dropped because caller supersedes it).
    @discardableResult
    public func saveNow(_ sessions: [LatticeSession]) -> SessionSaveAttemptResult {
        performImmediateSave(sessions)
    }

    /// Synchronous termination/lifecycle flush of the latest exact snapshot.
    /// Cancels pending debounced work; the provided snapshot is authoritative.
    @discardableResult
    public func flush(_ sessions: [LatticeSession]) -> SessionSaveAttemptResult {
        performImmediateSave(sessions)
    }

    /// Retry must write the latest snapshot, never the stale snapshot that originally failed.
    @discardableResult
    public func retry(_ latestSessions: [LatticeSession]) -> SessionSaveAttemptResult {
        performImmediateSave(latestSessions)
    }

    /// Drop pending debounced work without writing.
    public func cancelPending() {
        saveLock.lock()
        cancelPendingLocked()
        saveLock.unlock()
    }

    // MARK: - Internals

    private func cancelPendingLocked() {
        lock.lock()
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        pendingSnapshot = nil
        debounceGeneration &+= 1
        lock.unlock()
    }

    private func performPendingDebouncedSave(ifGenerationIs generation: UInt64) {
        lock.lock()
        guard generation == debounceGeneration, pendingSnapshot != nil else {
            lock.unlock()
            return
        }
        lock.unlock()

        // A safe-boundary save can invalidate this generation while the debounce
        // waits for the filesystem serialization lock. Revalidate after taking
        // that lock, immediately before consuming the snapshot and doing IO.
        beforeDebouncedSaveLockHook?()
        saveLock.lock()

        lock.lock()
        guard generation == debounceGeneration, let snapshot = pendingSnapshot else {
            lock.unlock()
            saveLock.unlock()
            return
        }
        pendingSnapshot = nil
        pendingWorkItem = nil
        lock.unlock()
        let completion = performSaveLocked(snapshot)
        notificationOrderLock.lock()
        saveLock.unlock()
        completion.enqueueNotification(on: failureNotificationQueue)
        notificationOrderLock.unlock()
    }

    private func performImmediateSave(_ sessions: [LatticeSession]) -> SessionSaveAttemptResult {
        saveLock.lock()
        cancelPendingLocked()
        let completion = performSaveLocked(sessions)
        notificationOrderLock.lock()
        saveLock.unlock()
        completion.enqueueNotification(on: failureNotificationQueue)
        notificationOrderLock.unlock()
        drainFailureNotificationsIfPossible()
        return completion.result
    }

    /// Preserve the historical synchronous observer contract for ordinary
    /// callers. A callback that reenters the coordinator is already executing
    /// on this queue and must not synchronously wait on itself.
    private func drainFailureNotificationsIfPossible() {
        guard DispatchQueue.getSpecific(key: failureNotificationQueueKey) == nil else { return }
        failureNotificationQueue.sync {}
    }

    /// Performs one write while `saveLock` is held by the caller.
    private func performSaveLocked(_ sessions: [LatticeSession]) -> SaveCompletion {

        if writeGate.isBlocked {
            // Never write while load-recovery gate is blocked; do not surface as save-failure UI.
            return SaveCompletion(result: .blockedByWriteGate)
        }

        do {
            try saveHandler(sessions)
            return clearFailureAfterSuccessfulSave()
        } catch {
            if SessionSaveFailureClassifier.isWriteBlocked(error) {
                return SaveCompletion(result: .blockedByWriteGate)
            }
            let failure = SessionSaveFailureClassifier.makeFailure(
                storeID: storeID,
                storeName: storeName,
                filePath: filePath,
                error: error,
                occurredAt: now()
            )
            return recordFailure(failure)
        }
    }

    private func recordFailure(_ failure: SessionSaveFailure) -> SaveCompletion {
        lock.lock()
        let previous = activeFailure
        if let previous, previous.fingerprint == failure.fingerprint {
            // Keep original occurredAt so the status does not thrash; suppress re-notify storms.
            lock.unlock()
            return SaveCompletion(result: .coalescedFailure(previous))
        }
        activeFailure = failure
        let observer = failureObserver
        lock.unlock()
        return SaveCompletion(result: .failed(failure), observer: observer, observedFailure: failure)
    }

    private func clearFailureAfterSuccessfulSave() -> SaveCompletion {
        lock.lock()
        let hadFailure = activeFailure != nil
        activeFailure = nil
        let observer = failureObserver
        lock.unlock()
        return SaveCompletion(
            result: .saved,
            observer: hadFailure ? observer : nil,
            observedFailure: nil
        )
    }
}

private struct SaveCompletion {
    let result: SessionSaveAttemptResult
    let observer: SessionSaveCoordinator.FailureObserver?
    let observedFailure: SessionSaveFailure?

    init(
        result: SessionSaveAttemptResult,
        observer: SessionSaveCoordinator.FailureObserver? = nil,
        observedFailure: SessionSaveFailure? = nil
    ) {
        self.result = result
        self.observer = observer
        self.observedFailure = observedFailure
    }

    /// Enqueued after the caller releases `saveLock`, while the handoff lock
    /// still guarantees the same total order as the writes.
    func enqueueNotification(on queue: DispatchQueue) {
        guard let observer else { return }
        let failure = observedFailure
        queue.async {
            observer(failure)
        }
    }
}
