import Foundation
import LatticeCore
import Combine

/// Owns the live session catalog: sessions array and catalog mutations.
/// Selection coordination (`selectedSessionID` side effects) stays on AppState;
/// this store is the sole owner of the `[LatticeSession]` array.
@MainActor
final class SessionCatalogStore: ObservableObject {
    @Published var sessions: [LatticeSession] = []

    func replaceAll(_ newSessions: [LatticeSession]) {
        sessions = newSessions
    }

    func session(id: UUID) -> LatticeSession? {
        sessions.first(where: { $0.id == id })
    }

    func index(of id: UUID) -> Int? {
        sessions.firstIndex(where: { $0.id == id })
    }

    @discardableResult
    func update(id: UUID, _ body: (inout LatticeSession) -> Void) -> Bool {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return false }
        body(&sessions[index])
        return true
    }

    func append(_ session: LatticeSession) {
        sessions.append(session)
    }

    @discardableResult
    func remove(id: UUID) -> LatticeSession? {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return nil }
        return sessions.remove(at: index)
    }

    func sortedByRecency() -> [LatticeSession] {
        LatticeSessionListOrdering.sorted(sessions)
    }
}
