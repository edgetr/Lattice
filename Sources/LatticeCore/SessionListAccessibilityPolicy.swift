import Foundation

/// Accessibility value for chat-list rows.
public enum SessionListAccessibilityPolicy: Sendable {
    public static func value(for session: LatticeSession, activity: ThreadActivityLane = ThreadActivityLane()) -> String {
        let messageCount = session.totalMessageCount
        let messagePart = "\(messageCount) message\(messageCount == 1 ? "" : "s")"
        let activityPart = activity.status == .idle
            ? (session.isStreaming ? "Streaming" : "Idle")
            : activity.status.label
        let pinnedPart = session.isPinned ? "Pinned" : "Not pinned"
        var parts = [messagePart, activityPart, pinnedPart]
        if activity.queuedCount > 0 { parts.append("\(activity.queuedCount) queued") }
        if activity.hasUnreadActivity { parts.append("Unread activity") }
        if activity.requiresAttention { parts.append("Needs attention") }
        return parts.joined(separator: ", ")
    }
}
