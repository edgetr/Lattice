import Foundation

public enum LatticeSessionListOrdering {
    public static func sorted(_ sessions: [LatticeSession]) -> [LatticeSession] {
        sessions.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            if lhs.lastUpdated != rhs.lastUpdated { return lhs.lastUpdated > rhs.lastUpdated }
            let titleComparison = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            if titleComparison != .orderedSame { return titleComparison == .orderedAscending }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
