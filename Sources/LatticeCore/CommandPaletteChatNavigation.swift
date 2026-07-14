import Foundation

/// Pure catalog and visibility policy for navigating durable chats from the command palette.
/// Chat search intentionally uses metadata only; opening the palette never hydrates transcripts.
public enum LatticeCommandPaletteChatNavigation: Sendable {
    public static let recentLimit = 6

    public static func items(
        sessions: [LatticeSession],
        activityLanes: ThreadActivityLaneStore,
        selectedSessionID: UUID?
    ) -> [LatticeCommandPaletteItem] {
        LatticeSessionListOrdering.sorted(sessions).map { session in
            let lane = activityLanes.lane(for: session.id)
            let status: ThreadActivityStatus = lane.status == .idle && session.isStreaming
                ? .running
                : lane.status
            let state = LatticeCommandPaletteChatState(
                activityStatus: status,
                queuedCount: lane.queuedCount,
                hasUnreadActivity: lane.hasUnreadActivity,
                requiresAttention: lane.requiresAttention,
                isCurrent: selectedSessionID == session.id
            )
            let workspaceName = session.workspacePath.flatMap(workspaceDisplayName)

            return LatticeCommandPaletteItem(
                id: "chat:\(session.id.uuidString.lowercased())",
                title: session.title,
                detail: detail(workspaceName: workspaceName, state: state),
                keywords: [
                    "chat", "thread", "conversation", "session",
                    workspaceName ?? "",
                    session.workspacePath ?? "",
                    session.executionRoute.mode.displayName,
                    session.backend.displayName,
                    status.label
                ],
                kind: .chat(session.id),
                chatState: state
            )
        }
    }

    /// Empty search keeps the palette compact while still exposing recent/pinned chats.
    /// A query searches every chat plus every command, preserving deterministic catalog order.
    public static func visibleItems(
        chats: [LatticeCommandPaletteItem],
        commands: [LatticeCommandPaletteItem],
        query: String,
        recentLimit: Int = recentLimit
    ) -> [LatticeCommandPaletteItem] {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Array(chats.prefix(max(0, recentLimit))) + commands
        }
        return LatticeCommandPaletteMatcher.filtered(chats + commands, query: query)
    }

    private static func workspaceDisplayName(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let name = URL(fileURLWithPath: trimmed).lastPathComponent
        return name.isEmpty ? trimmed : name
    }

    private static func detail(
        workspaceName: String?,
        state: LatticeCommandPaletteChatState
    ) -> String {
        var parts: [String] = []
        if state.isCurrent { parts.append("Current chat") }
        if state.activityStatus != .idle { parts.append(state.activityStatus.label) }
        if state.queuedCount > 0 { parts.append("\(state.queuedCount) queued") }
        if state.hasUnreadActivity { parts.append("Unread activity") }
        if state.requiresAttention { parts.append("Needs attention") }
        if let workspaceName { parts.append(workspaceName) }
        return parts.isEmpty ? "Open chat" : parts.joined(separator: " · ")
    }
}
