import Foundation
import LatticeCore

/// Serializes checkpoint service and durable-store access across UI refreshes and run tasks.
actor WorkspaceCheckpointClient {
    private let service: WorkspaceCheckpointService

    init(service: WorkspaceCheckpointService) {
        self.service = service
    }

    func capture(
        worktreeURL: URL,
        sessionID: UUID,
        runID: UUID,
        boundary: WorkspaceCheckpointBoundary
    ) async throws -> WorkspaceCheckpoint {
        try await service.capture(
            worktreeURL: worktreeURL,
            sessionID: sessionID,
            runID: runID,
            boundary: boundary
        )
    }

    func changes(beforeCheckpointID: UUID, afterCheckpointID: UUID) async throws -> WorkspaceCheckpointChangeSet {
        try await service.changes(
            beforeCheckpointID: beforeCheckpointID,
            afterCheckpointID: afterCheckpointID
        )
    }

    func checkpoints(sessionID: UUID) throws -> [WorkspaceCheckpoint] {
        try service.store.checkpoints(sessionID: sessionID)
    }

    func addReviewNote(
        checkpointID: UUID,
        path: String,
        body: String,
        kind: WorkspaceReviewNoteKind,
        lineRange: WorkspaceReviewLineRange?,
        hunkHeader: String?
    ) throws -> WorkspaceReviewNote {
        try service.addReviewNote(
            checkpointID: checkpointID,
            path: path,
            body: body,
            kind: kind,
            lineRange: lineRange,
            hunkHeader: hunkHeader
        )
    }

    func reviewNotes(checkpointID: UUID) throws -> [WorkspaceReviewNote] {
        try service.reviewNotes(checkpointID: checkpointID)
    }

    func previewRevert(afterCheckpointID: UUID) async throws -> WorkspaceCheckpointRevertPreview {
        try await service.previewRevert(afterCheckpointID: afterCheckpointID)
    }

    func confirmRevert(afterCheckpointID: UUID, confirmationToken: String) async throws -> WorkspaceCheckpointRevertResult {
        try await service.confirmRevert(
            afterCheckpointID: afterCheckpointID,
            confirmationToken: confirmationToken
        )
    }
}
