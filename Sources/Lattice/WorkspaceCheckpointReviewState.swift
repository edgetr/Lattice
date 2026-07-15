import Foundation
import LatticeCore

enum WorkspaceCheckpointActivity: Equatable {
    case idle
    case capturingBefore
    case running
    case capturingAfter
    case ready
    case failed

    var label: String {
        switch self {
        case .idle: "No checkpoint"
        case .capturingBefore: "Capturing before run"
        case .running: "Run in progress"
        case .capturingAfter: "Capturing after run"
        case .ready: "Ready for review"
        case .failed: "Checkpoint unavailable"
        }
    }
}

struct WorkspaceCheckpointReviewState: Equatable {
    var sessionID: UUID
    var runID: UUID
    var worktreePath: String
    var activity: WorkspaceCheckpointActivity = .idle
    var beforeCheckpoint: WorkspaceCheckpoint?
    var afterCheckpoint: WorkspaceCheckpoint?
    var changes: WorkspaceCheckpointChangeSet?
    var notes: [WorkspaceReviewNote] = []
    var issue: String?
    var revertPreview: WorkspaceCheckpointRevertPreview?
    var revertStatus: String?
    var isPreparingRevert = false
    var isApplyingRevert = false

    var ownsCompletePair: Bool {
        guard let beforeCheckpoint, let afterCheckpoint else { return false }
        return beforeCheckpoint.status == .captured
            && afterCheckpoint.status == .captured
            && beforeCheckpoint.ownership == afterCheckpoint.ownership
            && beforeCheckpoint.boundary == .beforeRun
            && afterCheckpoint.boundary == .afterRun
    }
}
