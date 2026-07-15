import Foundation

/// Stable identifiers for assistive technologies and external UI inspection.
/// These are part of the production accessibility surface, not a test fixture.
enum LatticeAccessibilityID {
    static let workspaceRoot = "lattice.workspace.root"
    static let sessionList = "lattice.session.list"
    static let chatSearch = "lattice.session.search"
    static let sessionRowPrefix = "lattice.session.row."
    static let composerDraft = "lattice.composer.draft"
    static let conversationScroll = "lattice.conversation.scroll"
    static let newContentIndicator = "lattice.conversation.new-content"
    static let commandPalette = "lattice.command-palette"
    static let commandPaletteSearch = "lattice.command-palette.search"
    static let commandPaletteItemPrefix = "lattice.command-palette.item."
    static let toolbarCommands = "lattice.toolbar.commands"
    static let toolbarOverlay = "lattice.toolbar.overlay"
    static let overlay = "lattice.overlay"
    static let overlayOpenCommandPalette = "lattice.overlay.open-command-palette"
    static let overlayOpenWorkspace = "lattice.overlay.open-workspace"
    static let overlayExpandChat = "lattice.overlay.expand-chat"
    static let recovery = "lattice.recovery"
    static let recoveryIssuePrefix = "lattice.recovery.issue."
    static let recoveryRetryPrefix = "lattice.recovery.retry."
    static let recoveryResetPrefix = "lattice.recovery.reset."
    static let selfEditReview = "lattice.self-edit.review"
    static let activityTool = "lattice.activity.tool"
    static let activityApproval = "lattice.activity.approval"
    static let permissionNotice = "lattice.permission.notice"
    static let workDock = "lattice.work.dock"
    static let workLog = "lattice.work.log"
    static let workItemPrefix = "lattice.work.item."
    static let workPrimaryActionPrefix = "lattice.work.primary."
    static let workOriginJumpPrefix = "lattice.work.jump."
    static let brandingTitle = "lattice.branding.title"
    static let companionMark = "lattice.companion-mark"
    static let fileBrowser = "lattice.files.browser"
    static let terminalPanel = "lattice.terminal.panel"
    static let terminalCommand = "lattice.terminal.command"
    static let outboxStrip = "lattice.outbox.strip"
    static let approvalStrip = "lattice.approval.strip"

    static func sessionRow(_ id: UUID) -> String { sessionRowPrefix + id.uuidString.lowercased() }
    static func recoveryIssue(_ storeID: String) -> String { recoveryIssuePrefix + storeID }
    static func recoveryRetry(_ storeID: String) -> String { recoveryRetryPrefix + storeID }
    static func recoveryReset(_ storeID: String) -> String { recoveryResetPrefix + storeID }
    static func commandPaletteItem(_ id: String) -> String { commandPaletteItemPrefix + id }
    static func workItem(_ id: UUID) -> String { workItemPrefix + id.uuidString.lowercased() }
    static func workPrimaryAction(_ id: UUID) -> String { workPrimaryActionPrefix + id.uuidString.lowercased() }
    static func workOriginJump(_ id: UUID) -> String { workOriginJumpPrefix + id.uuidString.lowercased() }
}
