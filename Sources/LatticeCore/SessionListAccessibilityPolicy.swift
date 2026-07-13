import Foundation

/// Accessibility value for chat-list rows.
public enum SessionListAccessibilityPolicy: Sendable {
    public static func value(for session: LatticeSession) -> String {
        let messageCount = session.messages.count
        let messagePart = "\(messageCount) message\(messageCount == 1 ? "" : "s")"
        let streamingPart = session.isStreaming ? "Streaming" : "Idle"
        let pinnedPart = session.isPinned ? "Pinned" : "Not pinned"
        return [messagePart, streamingPart, pinnedPart].joined(separator: ", ")
    }
}
