import Foundation

public extension LatticeSession {
    func matchesSearch(_ query: String) -> Bool {
        let tokens = query
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0).lowercased() }
        guard !tokens.isEmpty else { return true }

        let searchableText = [
            title,
            backend.displayName,
            backend.harnessName,
            harnessID ?? "",
            privacyMode.displayName,
            privacyMode == .localOnly ? "local-only local only private offline no cloud" : "cloud allowed remote provider",
            workspacePath ?? "",
            isPinned ? "pinned pin favorite" : "",
            messages.map { "\($0.role.rawValue) \($0.text) \($0.isPinned ? "pinned pin favorite" : "")" }.joined(separator: "\n"),
            queuedFollowUps.map(\.text).joined(separator: "\n"),
            attachments.map { "\($0.name) \($0.path)" }.joined(separator: "\n"),
            actions.map { action in
                [
                    action.kind.rawValue,
                    action.toolKind?.rawValue ?? "",
                    action.title,
                    action.detail,
                    action.status.rawValue,
                    action.workspaceScoped ? "workspace" : "global"
                ].joined(separator: " ")
            }.joined(separator: "\n")
        ].joined(separator: "\n").lowercased()

        return tokens.allSatisfy { searchableText.contains($0) }
    }
}
