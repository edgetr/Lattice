import Foundation

public enum SessionTranscriptMutation {
    public static func canMutateContent(in session: LatticeSession) -> Bool {
        !session.isStreaming && session.isTranscriptLoaded && session.isArtifactsLoaded
    }

    public static func branchFromMessage(
        messageID: UUID,
        in session: LatticeSession,
        at date: Date = .now
    ) -> LatticeSession? {
        guard canMutateContent(in: session),
              let messageIndex = session.messages.firstIndex(where: { $0.id == messageID }) else {
            return nil
        }

        let retainedMessages = Array(session.messages[session.messages.startIndex...messageIndex])
        let keptIDs = Set(retainedMessages.map(\.id))
        var retainedActions = session.actions
        SessionActionTrail.prune(in: &retainedActions, keepingMessageIDs: keptIDs)
        var retainedArtifacts = session.artifacts
        AssistantArtifactTrail.prune(in: &retainedArtifacts, keepingMessageIDs: keptIDs)
        // Branch starts with an empty ordinary draft (does not copy the source chat's unsent text).
        return LatticeSession(
            title: branchTitle(for: session.title),
            messages: retainedMessages,
            artifacts: retainedArtifacts,
            isArtifactsLoaded: true,
            isArtifactsDirty: true,
            backend: session.backend,
            executionRoute: session.executionRoute,
            harnessID: session.harnessID,
            reasoningEffort: session.reasoningEffort,
            harnessThreadID: nil,
            workspacePath: session.workspacePath,
            attachments: session.attachments,
            policy: session.policy,
            privacyMode: session.privacyMode,
            intent: session.intent,
            actions: retainedActions,
            queuedFollowUps: [],
            draft: "",
            isPinned: false,
            isStreaming: false,
            lastUpdated: date
        )
    }

    @discardableResult
    public static func deleteMessageAndFollowing(
        messageID: UUID,
        in session: inout LatticeSession,
        at date: Date = .now
    ) -> Bool {
        guard canMutateContent(in: session),
              let messageIndex = session.messages.firstIndex(where: { $0.id == messageID }) else {
            return false
        }

        session.messages.removeSubrange(messageIndex..<session.messages.endIndex)
        let keptIDs = Set(session.messages.map(\.id))
        SessionActionTrail.prune(in: &session.actions, keepingMessageIDs: keptIDs)
        AssistantArtifactTrail.prune(in: &session.artifacts, keepingMessageIDs: keptIDs)
        session.harnessThreadID = nil
        session.lastUpdated = date

        if !session.messages.contains(where: { $0.role == .user }) {
            session.title = "New chat"
            session.intent = nil
        }

        return true
    }

    private static func branchTitle(for title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "New chat" : trimmed
        let prefixed = base.localizedCaseInsensitiveContains("branch:") && base.lowercased().hasPrefix("branch:")
            ? base
            : "Branch: \(base)"
        return String(prefixed.prefix(72))
    }
}
