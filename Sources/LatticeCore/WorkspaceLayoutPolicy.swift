import Foundation

// MARK: - Workspace split columns

/// Pure breakpoints for adaptive `NavigationSplitView` column management.
///
/// The Lattice window minimum is ~900 pt. At that width, three simultaneous
/// columns (section sidebar + chat list + transcript) leave the transcript too
/// narrow for readable message chrome. These rules prefer hiding the section
/// sidebar first while keeping the chat list available.
public enum LatticeWorkspaceLayoutPolicy: Sendable {
    /// Wide enough that three columns leave a practical transcript.
    public static let comfortableThreeColumnWidth: Double = 1200

    /// Below this width, auto-management prefers chat list + transcript only.
    public static let doubleColumnBreakpoint: Double = 1200

    public enum ColumnMode: String, Sendable, Equatable {
        /// Section sidebar + chat list + transcript.
        case all
        /// Chat list + transcript (section sidebar hidden).
        case doubleColumn
    }

    /// Suggested split mode for a measured workspace width.
    public static func suggestedColumnMode(forWidth width: Double) -> ColumnMode {
        guard width > 0 else { return .all }
        if width < doubleColumnBreakpoint {
            return .doubleColumn
        }
        return .all
    }

    /// Once the window is comfortably wide again, resume automatic column management.
    public static func shouldResumeAutomaticColumnManagement(width: Double) -> Bool {
        width >= comfortableThreeColumnWidth
    }
}

// MARK: - Message row chrome

/// Pure rules for when message action chrome should collapse to an overflow menu.
///
/// Hard message/action width constraints can overflow or squeeze parents at the app
/// minimum width, producing one-character-wide “vertical strip” bubbles. Selection
/// is therefore driven by measured row width, and unknown width defaults to the
/// compact layout so the first layout pass never strips text.
public enum LatticeMessageRowLayoutPolicy: Sendable {
    /// Practical width for discrete user-message actions (edit included) + bubble.
    public static let regularUserActionsMinWidth: Double = 440

    /// Practical width for discrete assistant-message actions + bubble.
    public static let regularAssistantActionsMinWidth: Double = 400

    /// Maximum bubble content width on wide transcripts.
    public static let bubbleMaxWidth: Double = 580

    /// Maximum readable transcript content width on wide detail columns (~72–80ch).
    public static let transcriptMaxWidth: Double = 720

    /// Whether message actions should use a single overflow menu.
    public static func usesCompactActions(availableWidth: Double, isUser: Bool) -> Bool {
        // Unknown / pre-measure: prefer compact so first frames stay readable.
        guard availableWidth > 0 else { return true }
        let threshold = isUser ? regularUserActionsMinWidth : regularAssistantActionsMinWidth
        return availableWidth < threshold
    }

    /// Horizontal inset for the transcript column; tighter at constrained widths.
    public static func transcriptHorizontalPadding(forWidth width: Double) -> Double {
        if width > 0 && width < 520 { return 16 }
        if width > 0 && width < 640 { return 22 }
        return 32
    }
}
