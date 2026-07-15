import Foundation
import LatticeCore
import Combine

/// Owns run UI state, active run IDs, and scheduler-facing run metadata.
/// Event application still lands in AppState until further reduction extraction.
@MainActor
final class RunOrchestrator: ObservableObject {
    @Published var runUIStates: [UUID: RunUIState] = [:]
    @Published var activeRunIDs: [UUID: UUID] = [:]
    @Published private(set) var threadActivityLanes = ThreadActivityLaneStore()
    @Published private(set) var schedulerGlobalLimit = 4
    @Published private(set) var schedulerWorkspaceLimit = 2

    func clearRun(for sessionID: UUID) {
        activeRunIDs[sessionID] = nil
    }

    func setActiveRunID(_ runID: UUID?, for sessionID: UUID) {
        activeRunIDs[sessionID] = runID
    }
}
