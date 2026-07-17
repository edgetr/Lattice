import CryptoKit
import Foundation

// MARK: - Service

/// Git-backed workspace checkpoint capture, review diff, notes, and guarded revert.
///
/// Snapshots use a temporary alternate index with no-filter Git plumbing (`hash-object`,
/// `update-index`, `write-tree`, `commit-tree`, `update-ref`) under a Lattice-specific
/// ref namespace. Untracked contents are never
/// written into Git objects or the durable store. Revert is preview-gated and uses
/// binary reverse patches with `git apply --check` / `git apply`.
public struct WorkspaceCheckpointService: Sendable {
    public var store: WorkspaceCheckpointStore
    public var gitExecutableURL: URL?
    public var deadline: TimeInterval
    public var maximumOutputBytes: Int
    var revertTestUnlinkFailureOrdinal: Int?
    var revertTestBeforeUnlink: (@Sendable (String) -> Void)?
    var captureTestFailAfterRef: Bool
    var captureTestFailRefCleanup: Bool
    var captureTestAfterRef: (@Sendable () -> Void)?

    public init(
        store: WorkspaceCheckpointStore,
        gitExecutableURL: URL? = nil,
        deadline: TimeInterval = 30,
        maximumOutputBytes: Int = BoundedSubprocessRequest.defaultMaximumOutputBytes
    ) {
        self.store = store
        self.gitExecutableURL = gitExecutableURL
        self.deadline = deadline
        self.maximumOutputBytes = maximumOutputBytes
        self.revertTestUnlinkFailureOrdinal = nil
        self.revertTestBeforeUnlink = nil
        self.captureTestFailAfterRef = false
        self.captureTestFailRefCleanup = false
        self.captureTestAfterRef = nil
    }

    /// Serializes repository-mutating checkpoint/revert operations within this
    /// process. Git's index and worktree are shared mutable state; allowing a
    /// capture and revert to interleave would invalidate both their snapshots
    /// and their confirmation checks.
    private static let mutationGate = WorkspaceCheckpointMutationGate()

    func withWorkspaceMutationLock<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        await Self.mutationGate.acquire()
        do {
            let value = try await operation()
            await Self.mutationGate.release()
            return value
        } catch {
            await Self.mutationGate.release()
            throw error
        }
    }

    // MARK: Capture

    /// Captures tracked working-tree state for the given ownership and boundary.
    @discardableResult
    public func capture(
        worktreeURL: URL,
        sessionID: UUID,
        runID: UUID,
        boundary: WorkspaceCheckpointBoundary
    ) async throws -> WorkspaceCheckpoint {
        try await withWorkspaceMutationLock {
            try await self.captureUnlocked(
                worktreeURL: worktreeURL,
                sessionID: sessionID,
                runID: runID,
                boundary: boundary
            )
        }
    }

    private func captureUnlocked(
        worktreeURL: URL,
        sessionID: UUID,
        runID: UUID,
        boundary: WorkspaceCheckpointBoundary
    ) async throws -> WorkspaceCheckpoint {
        let checkpointID = UUID()
        let createdAt = Date()
        let requestedPath = worktreeURL.resolvingSymlinksInPath().standardizedFileURL.path
        let unresolvedOwnership = WorkspaceCheckpointOwnership(
            worktreePath: requestedPath,
            worktreeIdentity: Self.worktreeIdentity(toplevel: requestedPath, gitCommonDir: "unresolved"),
            sessionID: sessionID,
            runID: runID
        )

        // Even executable discovery/worktree resolution failures are durable
        // when the requested path and ownership are available. This gives the
        // UI a truthful failure trail instead of silently losing the attempt.
        let git: URL
        let context: WorktreeContext
        do {
            git = try resolveGit()
            context = try await resolveWorktreeContext(git: git, worktreeURL: worktreeURL)
        } catch let error as WorkspaceCheckpointError {
            let primaryMessage = error.message
            let failed = WorkspaceCheckpoint(
                id: checkpointID,
                ownership: unresolvedOwnership,
                boundary: boundary,
                status: .failed,
                createdAt: createdAt,
                failureSummary: error.message
            )
            do {
                try store.upsert(failed)
            } catch let storeError {
                throw WorkspaceCheckpointError.storeWriteFailed(
                    "Could not persist the checkpoint failure trail. Primary failure: "
                        + primaryMessage + " Store failure: " + storeError.localizedDescription
                )
            }
            throw error
        } catch {
            let primaryError = error
            let mapped = WorkspaceCheckpointError.captureFailed(primaryError.localizedDescription)
            let failed = WorkspaceCheckpoint(
                id: checkpointID,
                ownership: unresolvedOwnership,
                boundary: boundary,
                status: .failed,
                createdAt: createdAt,
                failureSummary: mapped.message
            )
            do {
                try store.upsert(failed)
            } catch let storeError {
                throw WorkspaceCheckpointError.storeWriteFailed(
                    "Could not persist the checkpoint failure trail. Primary failure: "
                        + mapped.message + " Store failure: " + storeError.localizedDescription
                )
            }
            throw mapped
        }
        let ownership = WorkspaceCheckpointOwnership(
            worktreePath: context.toplevelPath,
            worktreeIdentity: context.worktreeIdentity,
            sessionID: sessionID,
            runID: runID
        )
        var createdSnapshot: SnapshotWrite?

        do {
            try await reconcileFailedCheckpointRefs(git: git, context: context)
            let headOID = try await readHeadCommit(git: git, context: context)
            let trackedDirty = try await hasTrackedDirtiness(git: git, context: context)
            let indexDirty = try await hasIndexDirtiness(git: git, context: context)
            let untracked = try await collectUntrackedMetadata(git: git, context: context)
            let snapshot = try await writeTrackedSnapshot(
                git: git,
                context: context,
                headOID: headOID,
                ownership: ownership,
                boundary: boundary,
                checkpointID: checkpointID
            )
            createdSnapshot = snapshot
            captureTestAfterRef?()
            if captureTestFailAfterRef {
                throw WorkspaceCheckpointError.captureFailed("Injected post-ref capture failure.")
            }
            let revalidatedHead = try await readHeadCommit(git: git, context: context)
            let revalidatedIndex = try await currentIndexTreeOID(git: git, context: context)
            let revalidatedWorktree = try await writeCurrentTrackedTree(git: git, context: context)
            let revalidatedUntracked = try await collectUntrackedMetadata(git: git, context: context)
            let revalidatedTrackedDirty = try await hasTrackedDirtiness(git: git, context: context)
            let revalidatedIndexDirty = try await hasIndexDirtiness(git: git, context: context)
            guard revalidatedHead == headOID,
                  revalidatedIndex == snapshot.sourceIndexTreeOID,
                  revalidatedWorktree == snapshot.treeOID,
                  revalidatedUntracked == untracked,
                  revalidatedTrackedDirty == trackedDirty,
                  revalidatedIndexDirty == indexDirty else {
                throw WorkspaceCheckpointError.captureFailed(
                    "Workspace changed during checkpoint capture; the inconsistent snapshot was discarded."
                )
            }
            let headTree: String?
            if let headOID {
                headTree = try await treeForCommit(git: git, context: context, commit: headOID)
            } else {
                headTree = nil
            }
            let stats = try await changeStats(
                git: git,
                context: context,
                fromTree: headTree,
                toTree: snapshot.treeOID
            )

            let checkpoint = WorkspaceCheckpoint(
                id: checkpointID,
                ownership: ownership,
                boundary: boundary,
                status: .captured,
                createdAt: createdAt,
                headCommitOID: headOID,
                treeOID: snapshot.treeOID,
                snapshotCommitOID: snapshot.commitOID,
                refName: snapshot.refName,
                hasTrackedDirtiness: trackedDirty,
                hasIndexDirtiness: indexDirty,
                untrackedFiles: untracked,
                changeStats: stats,
                failureSummary: nil
            )
            try store.upsert(checkpoint)
            return checkpoint
        } catch let error as WorkspaceCheckpointError {
            try await recordCaptureFailure(
                error,
                snapshot: createdSnapshot,
                git: git,
                context: context,
                checkpointID: checkpointID,
                ownership: ownership,
                boundary: boundary,
                createdAt: createdAt
            )
        } catch {
            try await recordCaptureFailure(
                .captureFailed(error.localizedDescription),
                snapshot: createdSnapshot,
                git: git,
                context: context,
                checkpointID: checkpointID,
                ownership: ownership,
                boundary: boundary,
                createdAt: createdAt
            )
        }
    }

    private func recordCaptureFailure(
        _ primary: WorkspaceCheckpointError,
        snapshot: SnapshotWrite?,
        git: URL,
        context: WorktreeContext,
        checkpointID: UUID,
        ownership: WorkspaceCheckpointOwnership,
        boundary: WorkspaceCheckpointBoundary,
        createdAt: Date
    ) async throws -> Never {
        var cleanupFailure: String?
        if let snapshot {
            do {
                try await deleteCheckpointRef(git: git, context: context, refName: snapshot.refName)
            } catch {
                cleanupFailure = error.localizedDescription
            }
        }
        let summary = cleanupFailure.map {
            primary.message + " Checkpoint ref cleanup failed and will be retried: " + $0
        } ?? primary.message
        let failed = WorkspaceCheckpoint(
            id: checkpointID,
            ownership: ownership,
            boundary: boundary,
            status: .failed,
            createdAt: createdAt,
            treeOID: snapshot?.treeOID,
            snapshotCommitOID: snapshot?.commitOID,
            refName: cleanupFailure == nil ? nil : snapshot?.refName,
            failureSummary: summary
        )
        do {
            try store.upsert(failed)
        } catch {
            throw WorkspaceCheckpointError.storeWriteFailed(
                "Could not persist checkpoint failure/cleanup metadata. Primary failure: "
                    + primary.message + " Store failure: " + error.localizedDescription
            )
        }
        throw primary
    }

    private func reconcileFailedCheckpointRefs(
        git: URL,
        context: WorktreeContext
    ) async throws {
        let candidates = try store.load().checkpoints.filter {
            $0.status == .failed
                && $0.ownership.worktreeIdentity == context.worktreeIdentity
                && $0.refName != nil
        }
        for var checkpoint in candidates {
            guard let refName = checkpoint.refName else { continue }
            do {
                try await deleteCheckpointRef(git: git, context: context, refName: refName)
                checkpoint.refName = nil
                checkpoint.failureSummary = (checkpoint.failureSummary ?? "Checkpoint capture failed.")
                    + " Orphan checkpoint ref cleanup was reconciled."
                try store.upsert(checkpoint)
            } catch {
                // Keep durable ref metadata for a future reconciliation attempt.
                throw WorkspaceCheckpointError.captureFailed(
                    "A prior checkpoint ref still needs cleanup: " + error.localizedDescription
                )
            }
        }
    }

    // MARK: Review notes

    @discardableResult
    public func addReviewNote(
        checkpointID: UUID,
        path: String,
        body: String,
        kind: WorkspaceReviewNoteKind = .note,
        lineRange: WorkspaceReviewLineRange? = nil,
        hunkHeader: String? = nil
    ) throws -> WorkspaceReviewNote {
        let checkpoint = try requireCheckpoint(id: checkpointID)
        let normalizedPath = try WorkspaceCheckpointValidation.validateRepoRelativePath(path)
        try WorkspaceCheckpointValidation.validateLineRange(lineRange)
        let validatedBody = try WorkspaceCheckpointValidation.validateReviewBody(body)
        let note = WorkspaceReviewNote(
            checkpointID: checkpoint.id,
            sessionID: checkpoint.ownership.sessionID,
            runID: checkpoint.ownership.runID,
            path: normalizedPath,
            lineRange: lineRange,
            hunkHeader: hunkHeader,
            kind: kind,
            body: validatedBody
        )
        try store.appendNote(note)
        return note
    }

    public func reviewNotes(
        checkpointID: UUID? = nil,
        sessionID: UUID? = nil,
        runID: UUID? = nil
    ) throws -> [WorkspaceReviewNote] {
        try store.notes(checkpointID: checkpointID, sessionID: sessionID, runID: runID)
    }

}

private actor WorkspaceCheckpointMutationGate {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !held {
            held = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            held = false
        }
    }
}
