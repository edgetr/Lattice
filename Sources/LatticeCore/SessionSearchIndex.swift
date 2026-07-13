import Foundation

public extension LatticeSession {
    func matchesSearch(_ query: String) -> Bool {
        let tokens = query
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0).lowercased() }
        guard !tokens.isEmpty else { return true }

        let messageText = messages.map { message in
            let pinTerms = message.isPinned ? "pinned pin favorite" : ""
            return "\(message.role.rawValue) \(message.text) \(pinTerms)"
        }.joined(separator: "\n")
        let followUpText = queuedFollowUps.map(\.text).joined(separator: "\n")
        let attachmentText = attachments.map { "\($0.name) \($0.path)" }.joined(separator: "\n")
        let actionText = actions.map { action in
            [
                action.kind.rawValue,
                action.toolKind?.rawValue ?? "",
                action.title,
                action.detail,
                action.status.rawValue,
                action.workspaceScoped ? "workspace" : "global"
            ].joined(separator: " ")
        }.joined(separator: "\n")
        let searchableFields: [String] = [
            title,
            backend.displayName,
            backend.harnessName,
            harnessID ?? "",
            privacyMode.displayName,
            privacyMode == .localOnly ? "local-only local only private offline no cloud" : "cloud allowed remote provider",
            workspacePath ?? "",
            isPinned ? "pinned pin favorite" : "",
            messageText,
            followUpText,
            attachmentText,
            actionText
        ]
        let searchableText = searchableFields.joined(separator: "\n").lowercased()

        return tokens.allSatisfy { searchableText.contains($0) }
    }
}
