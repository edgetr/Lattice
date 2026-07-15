import Foundation

public struct LatticeAppCommand: Identifiable, Hashable, Sendable {
    public let id: String
    public let invocation: String
    public let title: String
    public let detail: String
    public let replacementText: String?

    public init(id: String, invocation: String, title: String, detail: String, replacementText: String? = nil) {
        self.id = id
        self.invocation = invocation
        self.title = title
        self.detail = detail
        self.replacementText = replacementText
    }
}

public enum LatticeAppCommandCatalog {
    public static let selfEdit = LatticeAppCommand(
        id: "self-edit",
        invocation: LatticeSelfEditCommand.name,
        title: "Edit Lattice",
        detail: "Create a user-owned extension"
    )

    public static let all: [LatticeAppCommand] = [selfEdit]

    public static func uniqueByInvocation(_ commands: [LatticeAppCommand]) -> [LatticeAppCommand] {
        var seen = Set<String>()
        var unique: [LatticeAppCommand] = []
        for command in commands {
            let key = command.invocation.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            unique.append(command)
        }
        return unique
    }

    public static func suggestions(for draft: String, commands: [LatticeAppCommand] = all) -> [LatticeAppCommand] {
        let leadingTrimmed = String(draft.drop(while: \.isWhitespace))
        guard leadingTrimmed.hasPrefix("/") else { return [] }
        let commandToken = leadingTrimmed.dropFirst()
        guard !commandToken.contains(where: \.isWhitespace) else { return [] }
        let query = String(commandToken)
        let uniqueCommands = uniqueByInvocation(commands)
        guard !query.isEmpty else { return uniqueCommands }
        return uniqueCommands.filter { command in
            let token = String(command.invocation.dropFirst())
            return token.localizedCaseInsensitiveContains(query)
        }
    }

    public static func completion(for draft: String, commands: [LatticeAppCommand] = all) -> LatticeAppCommand? {
        let matches = suggestions(for: draft, commands: commands)
        return matches.count == 1 ? matches[0] : nil
    }
}

/// Keeps slash-command discovery useful without allowing a large catalog to
/// consume the conversation viewport. Results remain scrollable, not truncated.
public enum CommandSuggestionLayoutPolicy {
    public static let maximumVisibleRows = 7
    public static let estimatedRowHeight = 54.0

    public static func height(resultCount: Int) -> Double {
        guard resultCount > 0 else { return 0 }
        return Double(min(resultCount, maximumVisibleRows)) * estimatedRowHeight
    }
}

public struct LatticeCommandPaletteItem: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case command
        case chat(UUID)
    }

    public let id: String
    public let title: String
    public let detail: String
    public let keywords: [String]
    public let isEnabled: Bool
    public let disabledReason: String?
    public let kind: Kind
    public let chatState: LatticeCommandPaletteChatState?

    public init(
        id: String,
        title: String,
        detail: String = "",
        keywords: [String] = [],
        isEnabled: Bool = true,
        disabledReason: String? = nil,
        kind: Kind = .command,
        chatState: LatticeCommandPaletteChatState? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.keywords = keywords
        self.isEnabled = isEnabled
        self.disabledReason = disabledReason
        self.kind = kind
        self.chatState = chatState
    }
}

public struct LatticeCommandPaletteChatState: Hashable, Sendable {
    public let activityStatus: ThreadActivityStatus
    public let queuedCount: Int
    public let hasUnreadActivity: Bool
    public let requiresAttention: Bool
    public let isCurrent: Bool

    public init(
        activityStatus: ThreadActivityStatus,
        queuedCount: Int = 0,
        hasUnreadActivity: Bool = false,
        requiresAttention: Bool = false,
        isCurrent: Bool = false
    ) {
        self.activityStatus = activityStatus
        self.queuedCount = max(0, queuedCount)
        self.hasUnreadActivity = hasUnreadActivity
        self.requiresAttention = requiresAttention
        self.isCurrent = isCurrent
    }
}

public enum LatticeCommandPaletteMatcher {
    public static func filtered(_ items: [LatticeCommandPaletteItem], query: String) -> [LatticeCommandPaletteItem] {
        let tokens = query
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !tokens.isEmpty else { return items }
        return items.filter { item in
            let searchable = ([item.title, item.detail] + item.keywords).joined(separator: " ").lowercased()
            return tokens.allSatisfy { searchable.contains($0) }
        }
    }

    public static func firstEnabled(in items: [LatticeCommandPaletteItem], query: String) -> LatticeCommandPaletteItem? {
        filtered(items, query: query).first(where: \.isEnabled)
    }
}

/// Shared mouse/keyboard selection policy for the command palette.
public enum LatticeCommandPaletteSelection: Sendable {
    /// Prefer the current enabled selection; otherwise select the first enabled item (or `nil` when none).
    public static func clampedSelection(selectedID: String?, in items: [LatticeCommandPaletteItem]) -> String? {
        if let selectedID, items.contains(where: { $0.id == selectedID && $0.isEnabled }) {
            return selectedID
        }
        return items.first(where: \.isEnabled)?.id
    }

    /// Hover adopts an enabled row as the shared selection.
    /// Returns `nil` for missing/disabled rows so callers leave selection unchanged (mouse exit must not clear).
    public static func selectionAfterHover(hoveredID: String, in items: [LatticeCommandPaletteItem]) -> String? {
        guard items.contains(where: { $0.id == hoveredID && $0.isEnabled }) else { return nil }
        return hoveredID
    }

    /// Move the selection by `delta` among enabled visible rows, continuing from the current shared selection.
    public static func movedSelection(selectedID: String?, in items: [LatticeCommandPaletteItem], delta: Int) -> String? {
        let enabledItems = items.filter(\.isEnabled)
        guard !enabledItems.isEmpty else { return nil }
        guard delta != 0 else { return clampedSelection(selectedID: selectedID, in: enabledItems) }
        let currentIndex = selectedID.flatMap { id in enabledItems.firstIndex(where: { $0.id == id }) } ?? -1
        let nextIndex: Int
        if currentIndex < 0 {
            nextIndex = delta > 0 ? 0 : enabledItems.count - 1
        } else {
            nextIndex = min(max(currentIndex + delta, 0), enabledItems.count - 1)
        }
        return enabledItems[nextIndex].id
    }

    /// Return/click only execute enabled selections.
    public static func executableSelection(selectedID: String?, in items: [LatticeCommandPaletteItem]) -> LatticeCommandPaletteItem? {
        guard let selectedID else { return nil }
        return items.first(where: { $0.id == selectedID && $0.isEnabled })
    }
}

