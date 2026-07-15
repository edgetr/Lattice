import CryptoKit
import Foundation

// MARK: - Service

/// Git-backed workspace checkpoint capture, review diff, notes, and guarded revert.
///
/// Snapshots use a temporary alternate index (`git add -u`, `write-tree`, `commit-tree`,
/// `update-ref`) under a Lattice-specific ref namespace. Untracked contents are never
/// written into Git objects or the durable store. Revert is preview-gated and uses
/// binary reverse patches with `git apply --check` / `git apply`.
public struct WorkspaceCheckpointService: Sendable {
    public var store: WorkspaceCheckpointStore
    public var gitExecutableURL: URL?
    public var deadline: TimeInterval
    public var maximumOutputBytes: Int

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
        let git = try resolveGit()
        let context = try await resolveWorktreeContext(git: git, worktreeURL: worktreeURL)
        let ownership = WorkspaceCheckpointOwnership(
            worktreePath: context.toplevelPath,
            worktreeIdentity: context.worktreeIdentity,
            sessionID: sessionID,
            runID: runID
        )
        let checkpointID = UUID()
        let createdAt = Date()

        do {
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
            let failed = WorkspaceCheckpoint(
                id: checkpointID,
                ownership: ownership,
                boundary: boundary,
                status: .failed,
                createdAt: createdAt,
                failureSummary: error.message
            )
            try? store.upsert(failed)
            throw error
        } catch {
            let failed = WorkspaceCheckpoint(
                id: checkpointID,
                ownership: ownership,
                boundary: boundary,
                status: .failed,
                createdAt: createdAt,
                failureSummary: error.localizedDescription
            )
            try? store.upsert(failed)
            throw WorkspaceCheckpointError.captureFailed(error.localizedDescription)
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
