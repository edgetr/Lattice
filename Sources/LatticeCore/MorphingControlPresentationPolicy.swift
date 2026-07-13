import Foundation

/// Pure presentation tokens for the shared composer control.
///
/// Workspace and overlay both render `MorphingControl` from the same state enum.
/// This policy keeps icons, labels, help, control sizing intent, disabled rules,
/// progress treatment, and semantic roles consistent across those surfaces.
public enum MorphingControlPresentationPolicy: Sendable {
    public enum Phase: String, Equatable, Sendable {
        case compact
        case expanded
        case context
        case progress
        case approval
        case success
        case failure
    }

    /// Semantic color role — views map these to system colors.
    public enum Semantic: String, Equatable, Sendable {
        case neutral
        case accent
        case success
        case warning
        case danger
    }

    public enum ActionKind: String, Equatable, Sendable {
        case send
        case queueFollowUp
        case stop
        case retry
        case addContext
        case dismissContext
    }

    public struct ActionChrome: Equatable, Sendable {
        public let kind: ActionKind
        public let systemImage: String
        public let accessibilityLabel: String
        public let help: String
        public let semantic: Semantic
        /// All primary composer actions use the same prominent icon chrome.
        public let isProminent: Bool
        /// When true, the action is disabled while the draft is empty/whitespace.
        public let requiresNonEmptyDraft: Bool

        public init(
            kind: ActionKind,
            systemImage: String,
            accessibilityLabel: String,
            help: String,
            semantic: Semantic,
            isProminent: Bool = true,
            requiresNonEmptyDraft: Bool = false
        ) {
            self.kind = kind
            self.systemImage = systemImage
            self.accessibilityLabel = accessibilityLabel
            self.help = help
            self.semantic = semantic
            self.isProminent = isProminent
            self.requiresNonEmptyDraft = requiresNonEmptyDraft
        }
    }

    public struct Presentation: Equatable, Sendable {
        public let phase: Phase
        /// Stable animation identity — ignores progress fraction and failure copy.
        public let animationIdentity: String
        public let statusTitle: String?
        public let statusSystemImage: String?
        public let statusSemantic: Semantic?
        public let progressFraction: Double?
        /// True when the run has not reported progress yet (spinner, not determinate bar).
        public let showsIndeterminateProgress: Bool
        public let draftPlaceholder: String?
        public let primaryAction: ActionChrome?
        public let secondaryAction: ActionChrome?
        public let usesInteractiveGlass: Bool

        public init(
            phase: Phase,
            animationIdentity: String,
            statusTitle: String? = nil,
            statusSystemImage: String? = nil,
            statusSemantic: Semantic? = nil,
            progressFraction: Double? = nil,
            showsIndeterminateProgress: Bool = false,
            draftPlaceholder: String? = nil,
            primaryAction: ActionChrome? = nil,
            secondaryAction: ActionChrome? = nil,
            usesInteractiveGlass: Bool = true
        ) {
            self.phase = phase
            self.animationIdentity = animationIdentity
            self.statusTitle = statusTitle
            self.statusSystemImage = statusSystemImage
            self.statusSemantic = statusSemantic
            self.progressFraction = progressFraction
            self.showsIndeterminateProgress = showsIndeterminateProgress
            self.draftPlaceholder = draftPlaceholder
            self.primaryAction = primaryAction
            self.secondaryAction = secondaryAction
            self.usesInteractiveGlass = usesInteractiveGlass
        }
    }

    public static let sendAction = ActionChrome(
        kind: .send,
        systemImage: "arrow.up",
        accessibilityLabel: "Send",
        help: "Send",
        semantic: .accent,
        requiresNonEmptyDraft: true
    )

    public static let queueFollowUpAction = ActionChrome(
        kind: .queueFollowUp,
        systemImage: "text.badge.plus",
        accessibilityLabel: "Queue follow-up",
        help: "Queue follow-up",
        semantic: .accent,
        requiresNonEmptyDraft: true
    )

    public static let stopAction = ActionChrome(
        kind: .stop,
        systemImage: "stop.fill",
        accessibilityLabel: "Stop",
        help: "Stop",
        semantic: .danger
    )

    public static let retryAction = ActionChrome(
        kind: .retry,
        systemImage: "arrow.clockwise",
        accessibilityLabel: "Retry",
        help: "Retry",
        semantic: .warning
    )

    public static let addContextAction = ActionChrome(
        kind: .addContext,
        systemImage: "paperclip",
        accessibilityLabel: "Add context",
        help: "Add context",
        semantic: .neutral
    )

    public static let dismissContextAction = ActionChrome(
        kind: .dismissContext,
        systemImage: "xmark",
        accessibilityLabel: "Close context picker",
        help: "Close context picker",
        semantic: .neutral
    )

    public static func presentation(for state: MorphingControlState) -> Presentation {
        switch state {
        case .compact:
            return Presentation(
                phase: .compact,
                animationIdentity: Phase.compact.rawValue,
                usesInteractiveGlass: true
            )
        case .expanded:
            return Presentation(
                phase: .expanded,
                animationIdentity: Phase.expanded.rawValue,
                draftPlaceholder: nil,
                primaryAction: sendAction,
                secondaryAction: addContextAction,
                usesInteractiveGlass: false
            )
        case .context:
            return Presentation(
                phase: .context,
                animationIdentity: Phase.context.rawValue,
                statusTitle: "Add context",
                statusSystemImage: "paperclip",
                statusSemantic: .neutral,
                secondaryAction: dismissContextAction,
                usesInteractiveGlass: false
            )
        case .progress(let fraction):
            let clamped = min(max(fraction, 0), 1)
            let started = fraction > 0
            return Presentation(
                phase: .progress,
                animationIdentity: Phase.progress.rawValue,
                statusTitle: started ? "Working…" : "Starting…",
                statusSemantic: .neutral,
                progressFraction: clamped,
                showsIndeterminateProgress: !started,
                draftPlaceholder: "Queue follow-up…",
                primaryAction: queueFollowUpAction,
                secondaryAction: stopAction,
                usesInteractiveGlass: true
            )
        case .approval:
            return Presentation(
                phase: .approval,
                animationIdentity: Phase.approval.rawValue,
                statusTitle: "Approval needed",
                statusSystemImage: "hand.raised.fill",
                statusSemantic: .warning,
                secondaryAction: stopAction,
                usesInteractiveGlass: true
            )
        case .success:
            return Presentation(
                phase: .success,
                animationIdentity: Phase.success.rawValue,
                statusTitle: "Done",
                statusSystemImage: "checkmark.circle.fill",
                statusSemantic: .success,
                usesInteractiveGlass: true
            )
        case .failure(let message):
            let title = message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Something went wrong"
                : message
            return Presentation(
                phase: .failure,
                animationIdentity: Phase.failure.rawValue,
                statusTitle: title,
                statusSystemImage: "exclamationmark.triangle.fill",
                statusSemantic: .danger,
                primaryAction: retryAction,
                usesInteractiveGlass: true
            )
        }
    }

    /// Whether a draft-gated action should be enabled for the given text.
    public static func isDraftActionEnabled(text: String, requiresNonEmptyDraft: Bool) -> Bool {
        guard requiresNonEmptyDraft else { return true }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
