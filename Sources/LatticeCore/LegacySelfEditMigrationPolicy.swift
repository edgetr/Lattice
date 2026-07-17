import Foundation

/// Read-compatibility inference for pre-intent self-edit chats. Lazy placeholders are
/// deliberately inconclusive until their transcript is hydrated.
public enum LegacySelfEditMigrationPolicy {
    public static func shouldClassify(_ session: LatticeSession) -> Bool {
        if session.title.range(of: "Lattice self-edit", options: [.caseInsensitive, .anchored]) != nil {
            return true
        }
        guard session.totalMessageCount > 0, session.isTranscriptLoaded else { return false }
        return session.messages.contains { message in
            message.role == .user && looksLikeSelfEditRequest(message.text)
        }
    }

    public static func looksLikeSelfEditRequest(_ text: String) -> Bool {
        let normalized = text.lowercased()
        let mentionsLattice = normalized.contains("lattice")
            || normalized.contains("this app")
            || normalized.contains("the app")
        let looksLikeSelfEdit = [
            "self edit", "self-edit", "change", "make", "restyle", "glassy",
            "liquid glass", "overlay", "sidebar", "chat", "composer", "color",
            "pink", "green", "ui", "interface", "text bubble", "message bubble"
        ].contains { normalized.contains($0) }
        return mentionsLattice && looksLikeSelfEdit
    }
}
