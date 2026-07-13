import Foundation

// MARK: - Measured geometry

/// Snapshot of scroll-view geometry for one conversation frame.
public struct ConversationScrollMetrics: Equatable, Sendable {
    public var contentOffsetY: Double
    public var containerHeight: Double
    public var contentHeight: Double
    public var isPositionedByUser: Bool

    public init(contentOffsetY: Double, containerHeight: Double, contentHeight: Double, isPositionedByUser: Bool = false) {
        self.contentOffsetY = contentOffsetY
        self.containerHeight = containerHeight
        self.contentHeight = contentHeight
        self.isPositionedByUser = isPositionedByUser
    }

    public var maxContentOffsetY: Double {
        max(0, contentHeight - containerHeight)
    }

    public var distanceFromBottom: Double {
        max(0, contentHeight - containerHeight - contentOffsetY)
    }

    public func isNearBottom(threshold: Double = ConversationScrollPolicy.nearBottomThreshold) -> Bool {
        if contentHeight <= containerHeight + ConversationScrollPolicy.geometryEpsilon {
            return true
        }
        return distanceFromBottom <= threshold
    }
}

// MARK: - Content signature

/// UI-independent summary of conversation tail content that can affect scroll height.
public struct ConversationScrollContentSnapshot: Equatable, Sendable {
    public var messageCount: Int
    public var lastMessageID: UUID?
    public var lastMessageCharacterCount: Int
    public var lastMessageRevision: Int
    public var lastMessageIsUser: Bool
    public var outgoingActionSequence: Int
    public var queuedFollowUpCount: Int
    /// All activity rows (for aggregate height / structural detection).
    public var activityCount: Int
    public var activityCharacterCount: Int
    public var activityRevision: Int
    /// Activity attached to the last message — truly below a browsing reader when the tail is live.
    public var tailActivityCount: Int
    public var tailActivityCharacterCount: Int
    public var tailActivityRevision: Int
    /// Activity attached above the last message — reflow must not count as new tail content.
    public var aboveActivityCount: Int
    public var aboveActivityCharacterCount: Int
    public var aboveActivityRevision: Int
    public var selfEditPreviewCount: Int
    public var selfEditPreviewRevision: Int
    public var hasPermissionNotice: Bool
    public var permissionNoticeID: UUID?
    public var hasVisibleError: Bool
    public var visibleErrorRevision: Int
    public var isStreaming: Bool

    public init(
        messageCount: Int = 0,
        lastMessageID: UUID? = nil,
        lastMessageCharacterCount: Int = 0,
        lastMessageRevision: Int = 0,
        lastMessageIsUser: Bool = false,
        outgoingActionSequence: Int = 0,
        queuedFollowUpCount: Int = 0,
        activityCount: Int = 0,
        activityCharacterCount: Int = 0,
        activityRevision: Int = 0,
        tailActivityCount: Int = 0,
        tailActivityCharacterCount: Int = 0,
        tailActivityRevision: Int = 0,
        aboveActivityCount: Int = 0,
        aboveActivityCharacterCount: Int = 0,
        aboveActivityRevision: Int = 0,
        selfEditPreviewCount: Int = 0,
        selfEditPreviewRevision: Int = 0,
        hasPermissionNotice: Bool = false,
        permissionNoticeID: UUID? = nil,
        hasVisibleError: Bool = false,
        visibleErrorRevision: Int = 0,
        isStreaming: Bool = false
    ) {
        self.messageCount = messageCount
        self.lastMessageID = lastMessageID
        self.lastMessageCharacterCount = lastMessageCharacterCount
        self.lastMessageRevision = lastMessageRevision
        self.lastMessageIsUser = lastMessageIsUser
        self.outgoingActionSequence = outgoingActionSequence
        self.queuedFollowUpCount = queuedFollowUpCount
        self.activityCount = activityCount
        self.activityCharacterCount = activityCharacterCount
        self.activityRevision = activityRevision
        self.tailActivityCount = tailActivityCount
        self.tailActivityCharacterCount = tailActivityCharacterCount
        self.tailActivityRevision = tailActivityRevision
        self.aboveActivityCount = aboveActivityCount
        self.aboveActivityCharacterCount = aboveActivityCharacterCount
        self.aboveActivityRevision = aboveActivityRevision
        self.selfEditPreviewCount = selfEditPreviewCount
        self.selfEditPreviewRevision = selfEditPreviewRevision
        self.hasPermissionNotice = hasPermissionNotice
        self.permissionNoticeID = permissionNoticeID
        self.hasVisibleError = hasVisibleError
        self.visibleErrorRevision = visibleErrorRevision
        self.isStreaming = isStreaming
    }
}

/// Classification of how content changed between two snapshots.
public enum ConversationScrollContentChangeKind: Equatable, Sendable {
    case none
    /// Streaming text or rows appended at the bottom tail.
    case bottomTailGrowth
    /// Deletion or structural change that may alter height above/around the viewport.
    case structuralOrAbove
    /// User sent a message, queued a follow-up, or otherwise initiated outbound content.
    case outgoingUserAction
}

// MARK: - Jump affordance presentation (pure)

/// Compact, session-scoped jump affordance derived from scroll state.
/// UI may publish this when it changes, without re-rendering on every geometry sample.
public struct ConversationJumpAffordance: Equatable, Sendable {
    public var pendingCount: Int
    public var isVisible: Bool

    public init(pendingCount: Int = 0, isVisible: Bool = false) {
        self.pendingCount = pendingCount
        self.isVisible = isVisible
    }

    public static let hidden = ConversationJumpAffordance()
}

// MARK: - Per-session state

/// Measured scroll anchor state for a single chat session.
public struct ConversationScrollSessionState: Equatable, Sendable {
    public var isFollowingTail: Bool
    public var metrics: ConversationScrollMetrics?
    public var preservedOffsetY: Double?
    public var preservedProgress: Double?
    public var lastContentHeight: Double?
    public var contentSnapshot: ConversationScrollContentSnapshot?
    /// Keep following after an outgoing action until geometry confirms near-bottom.
    public var pendingOutgoingFollow: Bool
    /// Suppress user-intent flips while a programmatic correction settles.
    public var programmaticCorrectionActive: Bool
    /// True only while the user is tracking, interacting, or decelerating a scroll.
    public var isUserInteracting: Bool
    /// Content changes are observed before SwiftUI publishes their post-layout height.
    /// Keep the kind until a geometry sample can make the measured correction.
    public var pendingGeometryChange: ConversationScrollContentChangeKind?
    /// Compact logical count of new tail content that arrived while the reader browsed history.
    /// In-memory / app-session only — never durable unread state.
    public var pendingNewContentCount: Int

    public init(
        isFollowingTail: Bool = true,
        metrics: ConversationScrollMetrics? = nil,
        preservedOffsetY: Double? = nil,
        preservedProgress: Double? = nil,
        lastContentHeight: Double? = nil,
        contentSnapshot: ConversationScrollContentSnapshot? = nil,
        pendingOutgoingFollow: Bool = false,
        programmaticCorrectionActive: Bool = false,
        isUserInteracting: Bool = false,
        pendingGeometryChange: ConversationScrollContentChangeKind? = nil,
        pendingNewContentCount: Int = 0
    ) {
        self.isFollowingTail = isFollowingTail
        self.metrics = metrics
        self.preservedOffsetY = preservedOffsetY
        self.preservedProgress = preservedProgress
        self.lastContentHeight = lastContentHeight
        self.contentSnapshot = contentSnapshot
        self.pendingOutgoingFollow = pendingOutgoingFollow
        self.programmaticCorrectionActive = programmaticCorrectionActive
        self.isUserInteracting = isUserInteracting
        self.pendingGeometryChange = pendingGeometryChange
        self.pendingNewContentCount = max(0, pendingNewContentCount)
    }

    public static let fresh = ConversationScrollSessionState()
}

// MARK: - Commands

/// Programmatic scroll action for the conversation view to apply.
public enum ConversationScrollCommand: Equatable, Sendable {
    case none
    case followTail(animated: Bool)
    case restoreOffset(y: Double, animated: Bool)
}

// MARK: - Policy

/// Pure conversation scroll-anchoring decisions. UI applies returned commands only.
public enum ConversationScrollPolicy {
    /// Stable identity for the bottom-tail sentinel covering every trailing row type.
    public static let tailSentinelID = "lattice.conversation.scroll.tail"

    public static let nearBottomThreshold: Double = 96
    public static let geometryEpsilon: Double = 0.5
    /// Compact badge ceiling so large counts do not break layout.
    public static let pendingCountDisplayCap: Int = 99

    // MARK: Classification

    public static func classifyContentChange(
        from previous: ConversationScrollContentSnapshot?,
        to current: ConversationScrollContentSnapshot
    ) -> ConversationScrollContentChangeKind {
        guard let previous else { return .none }
        if previous == current { return .none }

        if current.outgoingActionSequence > previous.outgoingActionSequence {
            return .outgoingUserAction
        }

        if current.messageCount > previous.messageCount, current.lastMessageIsUser {
            return .outgoingUserAction
        }
        if !previous.isStreaming, current.isStreaming {
            return .outgoingUserAction
        }

        // Stop / streaming-flag-only transitions must not invent new-content growth.
        if isStreamingStateOnlyChange(from: previous, to: current) {
            return .none
        }

        // Above-transcript activity reflow is structural, even if height changes.
        if current.aboveActivityCount != previous.aboveActivityCount
            || current.aboveActivityCharacterCount != previous.aboveActivityCharacterCount
            || current.aboveActivityRevision != previous.aboveActivityRevision {
            return .structuralOrAbove
        }

        // Aggregate activity without a classified tail/above split still counts as structural
        // (legacy / incomplete signatures). Prefer the split fields when they are populated.
        if current.activityCount != previous.activityCount
            || current.activityCharacterCount != previous.activityCharacterCount
            || current.activityRevision != previous.activityRevision {
            let tailChanged =
                current.tailActivityCount != previous.tailActivityCount
                || current.tailActivityCharacterCount != previous.tailActivityCharacterCount
                || current.tailActivityRevision != previous.tailActivityRevision
            let aboveUnchanged =
                current.aboveActivityCount == previous.aboveActivityCount
                && current.aboveActivityCharacterCount == previous.aboveActivityCharacterCount
                && current.aboveActivityRevision == previous.aboveActivityRevision
            if tailChanged && aboveUnchanged {
                return .bottomTailGrowth
            }
            // Fallback: unclassified aggregate activity reflow is structural.
            if !tailChanged {
                return .structuralOrAbove
            }
        }

        if current.messageCount < previous.messageCount {
            return .structuralOrAbove
        }

        // Pure streaming of the same trailing message.
        if previous.messageCount == current.messageCount,
           previous.lastMessageID == current.lastMessageID,
           previous.queuedFollowUpCount == current.queuedFollowUpCount,
           previous.selfEditPreviewCount == current.selfEditPreviewCount,
           previous.selfEditPreviewRevision == current.selfEditPreviewRevision,
           previous.hasPermissionNotice == current.hasPermissionNotice,
           previous.permissionNoticeID == current.permissionNoticeID,
           previous.hasVisibleError == current.hasVisibleError,
           previous.visibleErrorRevision == current.visibleErrorRevision,
           previous.tailActivityCount == current.tailActivityCount,
           previous.tailActivityCharacterCount == current.tailActivityCharacterCount,
           previous.tailActivityRevision == current.tailActivityRevision,
           previous.isStreaming == current.isStreaming,
           (previous.lastMessageCharacterCount != current.lastMessageCharacterCount
                || previous.lastMessageRevision != current.lastMessageRevision) {
            return .bottomTailGrowth
        }

        // Tail activity/status/detail updates for the last message.
        if previous.messageCount == current.messageCount,
           previous.lastMessageID == current.lastMessageID,
           (previous.tailActivityCount != current.tailActivityCount
                || previous.tailActivityCharacterCount != current.tailActivityCharacterCount
                || previous.tailActivityRevision != current.tailActivityRevision) {
            return .bottomTailGrowth
        }

        // Appended assistant/system message or bottom-tail accessory rows.
        if current.messageCount >= previous.messageCount {
            let tailAccessoriesChanged =
                previous.queuedFollowUpCount != current.queuedFollowUpCount
                || previous.selfEditPreviewCount != current.selfEditPreviewCount
                || previous.selfEditPreviewRevision != current.selfEditPreviewRevision
                || previous.hasPermissionNotice != current.hasPermissionNotice
                || previous.permissionNoticeID != current.permissionNoticeID
                || previous.hasVisibleError != current.hasVisibleError
                || previous.visibleErrorRevision != current.visibleErrorRevision
            if current.messageCount > previous.messageCount || tailAccessoriesChanged {
                return .bottomTailGrowth
            }
        }

        return .structuralOrAbove
    }

    /// Compact logical update count for new tail content. Not character count or reflow count.
    /// Returns 0 for initial snapshot establishment, following-tail contexts are handled by callers.
    public static func logicalNewContentIncrement(
        from previous: ConversationScrollContentSnapshot?,
        to current: ConversationScrollContentSnapshot,
        changeKind: ConversationScrollContentChangeKind
    ) -> Int {
        guard changeKind != .none, changeKind != .outgoingUserAction, let previous else { return 0 }

        var increment = 0

        if current.messageCount > previous.messageCount {
            // Appended messages (assistant/system). User appends are outgoing, not bottomTailGrowth.
            increment += current.messageCount - previous.messageCount
        } else if previous.lastMessageID == current.lastMessageID,
                  (previous.lastMessageCharacterCount != current.lastMessageCharacterCount
                    || previous.lastMessageRevision != current.lastMessageRevision) {
            // One logical update per streamed delta batch, not per character.
            increment += 1
        }

        if current.tailActivityCount > previous.tailActivityCount {
            increment += current.tailActivityCount - previous.tailActivityCount
        } else if current.tailActivityCount == previous.tailActivityCount,
                  (current.tailActivityCharacterCount != previous.tailActivityCharacterCount
                    || current.tailActivityRevision != previous.tailActivityRevision) {
            // Status/detail update on an existing tail tool/action row.
            increment += 1
        }

        if current.selfEditPreviewCount > previous.selfEditPreviewCount {
            increment += current.selfEditPreviewCount - previous.selfEditPreviewCount
        } else if current.selfEditPreviewCount == previous.selfEditPreviewCount,
                  current.selfEditPreviewCount > 0,
                  current.selfEditPreviewRevision != previous.selfEditPreviewRevision {
            increment += 1
        }

        if current.hasPermissionNotice {
            if !previous.hasPermissionNotice || current.permissionNoticeID != previous.permissionNoticeID {
                increment += 1
            }
        }

        if current.hasVisibleError {
            if !previous.hasVisibleError || current.visibleErrorRevision != previous.visibleErrorRevision {
                increment += 1
            }
        }

        // Queued follow-up rows that appear without being classified as outgoing (defensive).
        // Normal queueing is outgoingUserAction and clears pending instead.
        if current.queuedFollowUpCount > previous.queuedFollowUpCount {
            increment += current.queuedFollowUpCount - previous.queuedFollowUpCount
        }

        return max(0, increment)
    }

    /// Desired content offset while browsing history after a measured height change.
    public static func compensatedOffset(
        previousOffset: Double,
        previousContentHeight: Double,
        newContentHeight: Double,
        newContainerHeight: Double,
        changeKind: ConversationScrollContentChangeKind
    ) -> Double {
        let maxOffset = max(0, newContentHeight - newContainerHeight)
        switch changeKind {
        case .none, .bottomTailGrowth, .outgoingUserAction:
            // Bottom growth must not yank a reader who has scrolled up.
            return min(max(0, previousOffset), maxOffset)
        case .structuralOrAbove:
            let delta = newContentHeight - previousContentHeight
            return min(max(0, previousOffset + delta), maxOffset)
        }
    }

    public static func isInsignificantGeometryChange(
        from previous: ConversationScrollMetrics?,
        to current: ConversationScrollMetrics
    ) -> Bool {
        guard let previous else { return false }
        return abs(previous.contentOffsetY - current.contentOffsetY) <= geometryEpsilon
            && abs(previous.containerHeight - current.containerHeight) <= geometryEpsilon
            && abs(previous.contentHeight - current.contentHeight) <= geometryEpsilon
            && previous.isPositionedByUser == current.isPositionedByUser
    }

    // MARK: Jump affordance

    public static func shouldShowJumpToLatest(state: ConversationScrollSessionState) -> Bool {
        state.pendingNewContentCount > 0
            && !state.isFollowingTail
            && !state.pendingOutgoingFollow
    }

    public static func jumpAffordance(for state: ConversationScrollSessionState) -> ConversationJumpAffordance {
        guard shouldShowJumpToLatest(state: state) else { return .hidden }
        return ConversationJumpAffordance(
            pendingCount: state.pendingNewContentCount,
            isVisible: true
        )
    }

    /// Accessible name for the control (stable).
    public static func jumpToLatestAccessibilityLabel() -> String {
        "Jump to Latest"
    }

    /// Spoken value describing the pending logical update count.
    public static func jumpToLatestAccessibilityValue(count: Int) -> String {
        let display = displayedPendingCount(count)
        if count <= 0 { return "No new updates" }
        if count == 1 { return "1 new update" }
        if count > pendingCountDisplayCap {
            return "\(pendingCountDisplayCap)+ new updates"
        }
        return "\(display) new updates"
    }

    public static func jumpToLatestAccessibilityHint() -> String {
        "Scrolls to the newest content in this chat and clears the new-content count"
    }

    /// Compact visible badge text (`1`…`99`, then `99+`).
    public static func displayedPendingCount(_ count: Int) -> String {
        if count <= 0 { return "0" }
        if count > pendingCountDisplayCap { return "\(pendingCountDisplayCap)+" }
        return String(count)
    }

    // MARK: Geometry ingest

    /// Apply a measured geometry sample. Does not emit scroll commands (avoids feedback loops).
    public static func ingestGeometry(
        _ metrics: ConversationScrollMetrics,
        state: ConversationScrollSessionState
    ) -> ConversationScrollSessionState {
        var next = state

        if isInsignificantGeometryChange(from: state.metrics, to: metrics) {
            next.metrics = metrics
            return next
        }

        next.metrics = metrics
        next.lastContentHeight = metrics.contentHeight
        let near = metrics.isNearBottom()

        if state.programmaticCorrectionActive {
            if state.isUserInteracting, !near {
                next.pendingOutgoingFollow = false
                next.isFollowingTail = false
                next.programmaticCorrectionActive = false
                next.pendingGeometryChange = nil
                next.preservedOffsetY = metrics.contentOffsetY
                return next
            }
            if state.pendingOutgoingFollow || state.isFollowingTail {
                if near {
                    next.pendingOutgoingFollow = false
                    next.isFollowingTail = true
                    next.programmaticCorrectionActive = false
                    next.preservedOffsetY = nil
                    next.preservedProgress = nil
                    next.pendingNewContentCount = 0
                }
            } else if let target = state.preservedOffsetY,
                      abs(metrics.contentOffsetY - target) <= geometryEpsilon * 4 {
                next.programmaticCorrectionActive = false
                next.isFollowingTail = false
                next.preservedOffsetY = metrics.contentOffsetY
                next.preservedProgress = progress(for: metrics)
            }
            return next
        }

        if state.pendingOutgoingFollow {
            next.isFollowingTail = true
            if near {
                next.pendingOutgoingFollow = false
                next.preservedOffsetY = nil
                next.preservedProgress = nil
                next.pendingNewContentCount = 0
            }
            return next
        }

        next.isFollowingTail = near
        if near {
            next.preservedOffsetY = nil
            next.preservedProgress = nil
            next.pendingNewContentCount = 0
        } else {
            next.preservedOffsetY = metrics.contentOffsetY
            next.preservedProgress = progress(for: metrics)
        }
        return next
    }

    /// Complete content/layout anchoring once SwiftUI publishes post-layout geometry.
    /// This separate phase is essential because content observation normally precedes layout.
    public static func decideGeometryChange(
        _ metrics: ConversationScrollMetrics,
        state: ConversationScrollSessionState
    ) -> (state: ConversationScrollSessionState, command: ConversationScrollCommand) {
        if isInsignificantGeometryChange(from: state.metrics, to: metrics) {
            var next = state
            next.metrics = metrics
            return (next, .none)
        }

        let previousMetrics = state.metrics
        let pendingChange = state.pendingGeometryChange

        // Programmatic scroll samples are acknowledgements, not new user intent.
        if state.programmaticCorrectionActive {
            var settled = ingestGeometry(metrics, state: state)
            if !settled.programmaticCorrectionActive {
                settled.pendingGeometryChange = nil
            }
            let heightChanged = state.metrics.map {
                abs($0.contentHeight - metrics.contentHeight) > geometryEpsilon
            } ?? false
            let restorationTarget = state.preservedProgress.map { $0 * metrics.maxContentOffsetY }
                ?? state.preservedOffsetY
            if heightChanged,
               (state.isFollowingTail || state.pendingOutgoingFollow),
               !metrics.isNearBottom(),
               !state.isUserInteracting {
                settled.isFollowingTail = true
                settled.programmaticCorrectionActive = true
                return (settled, .followTail(animated: false))
            }
            if heightChanged,
               !state.isFollowingTail,
               !state.pendingOutgoingFollow,
               let target = restorationTarget,
               abs(metrics.contentOffsetY - target) > geometryEpsilon,
               !state.isUserInteracting {
                settled.isFollowingTail = false
                settled.preservedOffsetY = target
                settled.preservedProgress = state.preservedProgress
                settled.programmaticCorrectionActive = true
                return (settled, .restoreOffset(y: target, animated: false))
            }
            return (settled, .none)
        }

        // Never fight an active wheel/trackpad/scrollbar gesture, even when content height
        // changes in the same frame. The user's newly measured position becomes the anchor.
        if state.isUserInteracting {
            var userPosition = ingestGeometry(metrics, state: state)
            userPosition.pendingGeometryChange = nil
            return (userPosition, .none)
        }

        var next = ingestGeometry(metrics, state: state)
        let didGrowWhileFollowing = state.isFollowingTail
            && !metrics.isNearBottom()
            && state.metrics.map { abs($0.contentHeight - metrics.contentHeight) > geometryEpsilon } == true
        if didGrowWhileFollowing {
            next.isFollowingTail = true
            next.programmaticCorrectionActive = true
            next.pendingNewContentCount = 0
            return (next, .followTail(animated: false))
        }
        guard !state.isFollowingTail,
              !state.pendingOutgoingFollow,
              let previousMetrics else {
            next.pendingGeometryChange = nil
            return (next, .none)
        }

        let heightChanged = abs(metrics.contentHeight - previousMetrics.contentHeight) > geometryEpsilon
        guard heightChanged else {
            // Offset-only samples are user scrolling. Preserve a pending layout change until
            // its content-height sample arrives.
            next.pendingGeometryChange = pendingChange
            return (next, .none)
        }

        let changeKind = pendingChange ?? .structuralOrAbove
        let target = compensatedOffset(
            previousOffset: state.preservedOffsetY ?? previousMetrics.contentOffsetY,
            previousContentHeight: previousMetrics.contentHeight,
            newContentHeight: metrics.contentHeight,
            newContainerHeight: metrics.containerHeight,
            changeKind: changeKind
        )
        next.pendingGeometryChange = nil
        next.preservedOffsetY = target
        next.preservedProgress = metrics.maxContentOffsetY > geometryEpsilon
            ? target / metrics.maxContentOffsetY
            : next.preservedProgress
        next.lastContentHeight = metrics.contentHeight
        next.isFollowingTail = false

        guard abs(target - metrics.contentOffsetY) > geometryEpsilon else {
            return (next, .none)
        }
        next.programmaticCorrectionActive = true
        return (next, .restoreOffset(y: target, animated: false))
    }

    // MARK: Content / session decisions

    /// Content rows changed (messages, follow-ups, permission/error/self-edit tails).
    public static func decideContentChange(
        state: ConversationScrollSessionState,
        content: ConversationScrollContentSnapshot,
        measuredMetrics: ConversationScrollMetrics?,
        reduceMotion: Bool
    ) -> (state: ConversationScrollSessionState, command: ConversationScrollCommand) {
        var next = state
        let previousContent = state.contentSnapshot
        let changeKind = classifyContentChange(from: previousContent, to: content)
        next.contentSnapshot = content

        if changeKind == .none {
            return (next, .none)
        }

        _ = measuredMetrics // Post-layout metrics arrive through decideGeometryChange.

        if changeKind == .outgoingUserAction {
            return markOutgoingFollow(state: next, reduceMotion: reduceMotion)
        }

        if next.pendingOutgoingFollow || next.isFollowingTail {
            next.pendingNewContentCount = 0
            next.pendingGeometryChange = changeKind
            next.programmaticCorrectionActive = true
            // Streaming and live row-height updates settle directly at the tail. Repeated
            // animations lag behind layout and can create a scroll feedback loop.
            return (next, .followTail(animated: false))
        }

        // Browsing history: never move the viewport for content alone.
        switch changeKind {
        case .bottomTailGrowth:
            let increment = logicalNewContentIncrement(
                from: previousContent,
                to: content,
                changeKind: changeKind
            )
            if let previousContent, tailContentWasRemoved(from: previousContent, to: content) {
                next.pendingNewContentCount = 0
            }
            next.pendingNewContentCount = addingPendingCount(increment, to: next.pendingNewContentCount)
            next.pendingGeometryChange = changeKind
            return (next, .none)
        case .structuralOrAbove:
            // Structural/above changes can share a frame with genuine tail growth. Count only
            // the independently measured tail delta while retaining structural compensation.
            let increment = logicalNewContentIncrement(
                from: previousContent,
                to: content,
                changeKind: changeKind
            )
            if let previousContent, tailContentWasRemoved(from: previousContent, to: content) {
                next.pendingNewContentCount = 0
            }
            next.pendingNewContentCount = addingPendingCount(increment, to: next.pendingNewContentCount)
            next.pendingGeometryChange = changeKind
            return (next, .none)
        case .none, .outgoingUserAction:
            return (next, .none)
        }
    }

    /// Explicit outgoing user action (send, queue follow-up, continue).
    public static func decideOutgoingUserAction(
        state: ConversationScrollSessionState,
        reduceMotion: Bool
    ) -> (state: ConversationScrollSessionState, command: ConversationScrollCommand) {
        markOutgoingFollow(state: state, reduceMotion: reduceMotion)
    }

    /// User activated Jump to Latest: one intentional tail-follow, clear pending count.
    public static func decideJumpToLatest(
        state: ConversationScrollSessionState,
        reduceMotion: Bool
    ) -> (state: ConversationScrollSessionState, command: ConversationScrollCommand) {
        var next = state
        next.isFollowingTail = true
        next.pendingOutgoingFollow = false
        next.pendingNewContentCount = 0
        next.preservedOffsetY = nil
        next.preservedProgress = nil
        next.programmaticCorrectionActive = true
        next.isUserInteracting = false
        next.pendingGeometryChange = nil
        return (next, .followTail(animated: !reduceMotion))
    }

    /// Update the measured user-interaction phase without emitting a scroll command.
    public static func setUserInteraction(
        _ isActive: Bool,
        state: ConversationScrollSessionState
    ) -> ConversationScrollSessionState {
        var next = state
        next.isUserInteracting = isActive
        if isActive {
            next.isFollowingTail = false
            next.pendingOutgoingFollow = false
            next.programmaticCorrectionActive = false
            next.pendingGeometryChange = nil
            next.preservedOffsetY = state.metrics?.contentOffsetY ?? state.preservedOffsetY
            next.preservedProgress = state.metrics.flatMap(progress(for:)) ?? state.preservedProgress
        }
        return next
    }

    /// Session became visible again; restore its measured viewport or follow the tail.
    /// Pending new-content count is preserved across switches (per-session app-session awareness).
    public static func decideSessionActivation(
        state: ConversationScrollSessionState,
        reduceMotion: Bool
    ) -> (state: ConversationScrollSessionState, command: ConversationScrollCommand) {
        var next = state
        _ = reduceMotion // Activation restores without animation to avoid cross-session jank.
        if next.pendingOutgoingFollow || next.isFollowingTail {
            next.programmaticCorrectionActive = true
            return (next, .followTail(animated: false))
        }
        if let y = next.preservedProgress.flatMap({ progress in
            next.metrics.map { progress * $0.maxContentOffsetY }
        }) ?? next.preservedOffsetY ?? next.metrics?.contentOffsetY {
            next.programmaticCorrectionActive = true
            return (next, .restoreOffset(y: y, animated: false))
        }
        next.isFollowingTail = true
        next.programmaticCorrectionActive = true
        return (next, .followTail(animated: false))
    }

    /// Fresh state for a newly branched chat (independent of the source session).
    public static func freshBranchState() -> ConversationScrollSessionState {
        .fresh
    }

    // MARK: Private

    private static func isStreamingStateOnlyChange(
        from previous: ConversationScrollContentSnapshot,
        to current: ConversationScrollContentSnapshot
    ) -> Bool {
        var strippedPrevious = previous
        var strippedCurrent = current
        strippedPrevious.isStreaming = false
        strippedCurrent.isStreaming = false
        return strippedPrevious == strippedCurrent && previous.isStreaming != current.isStreaming
    }

    private static func tailContentWasRemoved(
        from previous: ConversationScrollContentSnapshot,
        to current: ConversationScrollContentSnapshot
    ) -> Bool {
        current.messageCount < previous.messageCount
            || (current.messageCount <= previous.messageCount
                && previous.lastMessageID != nil
                && current.lastMessageID != previous.lastMessageID)
            || current.queuedFollowUpCount < previous.queuedFollowUpCount
            || current.tailActivityCount < previous.tailActivityCount
            || current.selfEditPreviewCount < previous.selfEditPreviewCount
            || (previous.hasPermissionNotice
                && (!current.hasPermissionNotice || previous.permissionNoticeID != current.permissionNoticeID))
            || (previous.hasVisibleError && !current.hasVisibleError)
    }

    private static func addingPendingCount(_ increment: Int, to count: Int) -> Int {
        guard increment > 0 else { return count }
        guard count <= Int.max - increment else { return Int.max }
        return count + increment
    }

    private static func markOutgoingFollow(
        state: ConversationScrollSessionState,
        reduceMotion: Bool
    ) -> (state: ConversationScrollSessionState, command: ConversationScrollCommand) {
        var next = state
        next.isFollowingTail = true
        next.pendingOutgoingFollow = true
        next.pendingNewContentCount = 0
        next.preservedOffsetY = nil
        next.preservedProgress = nil
        next.programmaticCorrectionActive = true
        next.isUserInteracting = false
        next.pendingGeometryChange = nil
        return (next, .followTail(animated: !reduceMotion))
    }

    private static func progress(for metrics: ConversationScrollMetrics) -> Double? {
        guard metrics.maxContentOffsetY > geometryEpsilon else { return nil }
        return min(1, max(0, metrics.contentOffsetY / metrics.maxContentOffsetY))
    }
}
