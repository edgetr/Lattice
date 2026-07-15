import Foundation
import LatticeCore
import Combine

/// Owns the session catalog, selection, and lightweight list-level metadata.
/// Run streaming and apply still coordinate through AppState/RunOrchestrator.
@MainActor
final class SessionCatalogStore: ObservableObject {
    @Published var sessions: [LatticeSession] = []
    @Published var selectedSessionID: UUID?
    @Published private(set) var transcriptLoadingSessionID: UUID?

    var selectedSession: LatticeSession? {
        guard let selectedSessionID else { return nil }
        return sessions.first { $0.id == selectedSessionID }
    }

    func index(for id: UUID) -> Int? {
        sessions.firstIndex { $0.id == id }
    }

    func setTranscriptLoadingSessionID(_ id: UUID?) {
        transcriptLoadingSessionID = id
    }
}
