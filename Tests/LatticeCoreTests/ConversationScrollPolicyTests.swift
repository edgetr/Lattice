import Foundation
import Testing
@testable import LatticeCore

@Suite("Conversation scroll policy")
struct ConversationScrollPolicyTests {
    private let near = ConversationScrollMetrics(contentOffsetY: 900, containerHeight: 400, contentHeight: 1_300)
    private let browsing = ConversationScrollMetrics(contentOffsetY: 120, containerHeight: 400, contentHeight: 1_300)

    // MARK: - Near-bottom follow

    @Test func nearBottomGeometryMarksFollowingTail() {
        var state = ConversationScrollSessionState(isFollowingTail: false, preservedOffsetY: 40)
        state = ConversationScrollPolicy.ingestGeometry(near, state: state)
        #expect(state.isFollowingTail)
        #expect(state.preservedOffsetY == nil)
        #expect(state.metrics == near)
    }

    @Test func contentGrowthWhileFollowingIssuesFollowTail() {
        let state = ConversationScrollSessionState(
            isFollowingTail: true,
            metrics: near,
            lastContentHeight: near.contentHeight,
            contentSnapshot: ConversationScrollContentSnapshot(
                messageCount: 2,
                lastMessageID: UUID(),
                lastMessageCharacterCount: 10,
                lastMessageIsUser: false
            )
        )
        let nextContent = ConversationScrollContentSnapshot(
            messageCount: 2,
            lastMessageID: state.contentSnapshot?.lastMessageID,
            lastMessageCharacterCount: 48,
            lastMessageIsUser: false
        )
        let result = ConversationScrollPolicy.decideContentChange(
            state: state,
            content: nextContent,
            measuredMetrics: near,
            reduceMotion: false
        )
        #expect(result.command == .followTail(animated: false))
        #expect(result.state.isFollowingTail)
        #expect(result.state.programmaticCorrectionActive)
    }

    @Test func outgoingFollowRespectsReduceMotion() {
        let state = ConversationScrollSessionState(isFollowingTail: false, metrics: browsing)
        let withMotion = ConversationScrollPolicy.decideOutgoingUserAction(state: state, reduceMotion: false)
        let reduced = ConversationScrollPolicy.decideOutgoingUserAction(state: state, reduceMotion: true)
        #expect(withMotion.command == .followTail(animated: true))
        #expect(reduced.command == .followTail(animated: false))
    }

    // MARK: - Outgoing-action follow

    @Test func newUserMessageClassifiedAsOutgoingAction() {
        let previous = ConversationScrollContentSnapshot(
            messageCount: 2,
            lastMessageID: UUID(),
            lastMessageCharacterCount: 20,
            lastMessageIsUser: false
        )
        let current = ConversationScrollContentSnapshot(
            messageCount: 3,
            lastMessageID: UUID(),
            lastMessageCharacterCount: 8,
            lastMessageIsUser: true
        )
        #expect(ConversationScrollPolicy.classifyContentChange(from: previous, to: current) == .outgoingUserAction)
    }

    @Test func explicitOutgoingSequenceWinsWhenAssistantPlaceholderIsLast() {
        let previous = ConversationScrollContentSnapshot(
            messageCount: 2,
            lastMessageID: UUID(),
            lastMessageCharacterCount: 20,
            lastMessageIsUser: false,
            outgoingActionSequence: 4
        )
        let current = ConversationScrollContentSnapshot(
            messageCount: 4,
            lastMessageID: UUID(),
            lastMessageCharacterCount: 0,
            lastMessageIsUser: false,
            outgoingActionSequence: 5
        )
        #expect(ConversationScrollPolicy.classifyContentChange(from: previous, to: current) == .outgoingUserAction)
    }

    @Test func queuedFollowUpIncreaseIsNewTailContentNotOutgoingFollow() {
        let previous = ConversationScrollContentSnapshot(messageCount: 1, queuedFollowUpCount: 0)
        let current = ConversationScrollContentSnapshot(messageCount: 1, queuedFollowUpCount: 1)
        #expect(ConversationScrollPolicy.classifyContentChange(from: previous, to: current) == .bottomTailGrowth)
        let result = ConversationScrollPolicy.decideContentChange(
            state: ConversationScrollSessionState(
                isFollowingTail: false,
                metrics: browsing,
                preservedOffsetY: browsing.contentOffsetY,
                contentSnapshot: previous
            ),
            content: current,
            measuredMetrics: browsing,
            reduceMotion: false
        )
        #expect(result.command == .none)
        #expect(result.state.pendingNewContentCount == 1)
        #expect(!result.state.isFollowingTail)
    }

    @Test func outgoingUserActionForcesFollowEvenWhenBrowsing() {
        let state = ConversationScrollSessionState(
            isFollowingTail: false,
            metrics: browsing,
            preservedOffsetY: browsing.contentOffsetY,
            lastContentHeight: browsing.contentHeight
        )
        let result = ConversationScrollPolicy.decideOutgoingUserAction(state: state, reduceMotion: false)
        #expect(result.state.isFollowingTail)
        #expect(result.state.pendingOutgoingFollow)
        #expect(result.state.preservedOffsetY == nil)
        #expect(result.command == .followTail(animated: true))
    }

    @Test func contentChangeDetectsOutgoingUserMessageWhileBrowsing() {
        let previous = ConversationScrollContentSnapshot(
            messageCount: 4,
            lastMessageID: UUID(),
            lastMessageCharacterCount: 40,
            lastMessageIsUser: false
        )
        let state = ConversationScrollSessionState(
            isFollowingTail: false,
            metrics: browsing,
            preservedOffsetY: browsing.contentOffsetY,
            lastContentHeight: browsing.contentHeight,
            contentSnapshot: previous
        )
        let current = ConversationScrollContentSnapshot(
            messageCount: 5,
            lastMessageID: UUID(),
            lastMessageCharacterCount: 12,
            lastMessageIsUser: true
        )
        let result = ConversationScrollPolicy.decideContentChange(
            state: state,
            content: current,
            measuredMetrics: browsing,
            reduceMotion: true
        )
        #expect(result.command == .followTail(animated: false))
        #expect(result.state.pendingOutgoingFollow)
    }

    // MARK: - Browsing-history preservation / height compensation

    @Test func bottomTailGrowthWhileBrowsingDoesNotYank() {
        let messageID = UUID()
        let previous = ConversationScrollContentSnapshot(
            messageCount: 3,
            lastMessageID: messageID,
            lastMessageCharacterCount: 10,
            lastMessageIsUser: false
        )
        let state = ConversationScrollSessionState(
            isFollowingTail: false,
            metrics: browsing,
            preservedOffsetY: browsing.contentOffsetY,
            lastContentHeight: browsing.contentHeight,
            contentSnapshot: previous
        )
        let grown = ConversationScrollMetrics(
            contentOffsetY: browsing.contentOffsetY,
            containerHeight: browsing.containerHeight,
            contentHeight: browsing.contentHeight + 180
        )
        let current = ConversationScrollContentSnapshot(
            messageCount: 3,
            lastMessageID: messageID,
            lastMessageCharacterCount: 220,
            lastMessageIsUser: false
        )
        let result = ConversationScrollPolicy.decideContentChange(
            state: state,
            content: current,
            measuredMetrics: grown,
            reduceMotion: false
        )
        #expect(result.command == .none)
        #expect(!result.state.isFollowingTail)
        #expect(result.state.preservedOffsetY == browsing.contentOffsetY)
    }

    @Test func structuralHeightChangeCompensatesOffsetWhileBrowsing() {
        let beforeDelete = ConversationScrollMetrics(
            contentOffsetY: 200,
            containerHeight: 400,
            contentHeight: 1_000
        )
        let previous = ConversationScrollContentSnapshot(
            messageCount: 5,
            lastMessageID: UUID(),
            lastMessageCharacterCount: 12,
            lastMessageIsUser: false
        )
        let state = ConversationScrollSessionState(
            isFollowingTail: false,
            metrics: beforeDelete,
            preservedOffsetY: 200,
            lastContentHeight: 1_000,
            contentSnapshot: previous
        )
        let afterDelete = ConversationScrollMetrics(
            contentOffsetY: 200,
            containerHeight: 400,
            contentHeight: 850
        )
        let current = ConversationScrollContentSnapshot(
            messageCount: 3,
            lastMessageID: UUID(),
            lastMessageCharacterCount: 12,
            lastMessageIsUser: false
        )
        let contentResult = ConversationScrollPolicy.decideContentChange(
            state: state,
            content: current,
            measuredMetrics: beforeDelete,
            reduceMotion: false
        )
        #expect(contentResult.command == .none)
        #expect(contentResult.state.pendingGeometryChange == .structuralOrAbove)
        let result = ConversationScrollPolicy.decideGeometryChange(
            afterDelete,
            state: contentResult.state
        )
        let expected = ConversationScrollPolicy.compensatedOffset(
            previousOffset: 200,
            previousContentHeight: 1_000,
            newContentHeight: 850,
            newContainerHeight: 400,
            changeKind: .structuralOrAbove
        )
        #expect(result.command == .restoreOffset(y: expected, animated: false))
        #expect(result.state.preservedOffsetY == expected)
        #expect(result.state.programmaticCorrectionActive)
    }

    @Test func unclassifiedDynamicHeightChangeCompensatesAfterLayout() {
        let state = ConversationScrollSessionState(
            isFollowingTail: false,
            metrics: browsing,
            preservedOffsetY: browsing.contentOffsetY,
            lastContentHeight: browsing.contentHeight
        )
        let reflowed = ConversationScrollMetrics(
            contentOffsetY: browsing.contentOffsetY,
            containerHeight: browsing.containerHeight,
            contentHeight: browsing.contentHeight + 80
        )
        let result = ConversationScrollPolicy.decideGeometryChange(reflowed, state: state)
        #expect(result.command == .restoreOffset(y: browsing.contentOffsetY + 80, animated: false))
        #expect(result.state.programmaticCorrectionActive)
    }

    @Test func compensatedOffsetPreservesBrowsePositionForBottomGrowth() {
        let value = ConversationScrollPolicy.compensatedOffset(
            previousOffset: 150,
            previousContentHeight: 800,
            newContentHeight: 1_200,
            newContainerHeight: 400,
            changeKind: .bottomTailGrowth
        )
        #expect(value == 150)
    }

    @Test func compensatedOffsetShiftsForStructuralGrowthAbove() {
        let value = ConversationScrollPolicy.compensatedOffset(
            previousOffset: 150,
            previousContentHeight: 800,
            newContentHeight: 1_000,
            newContainerHeight: 400,
            changeKind: .structuralOrAbove
        )
        #expect(value == 350)
    }

    @Test func permissionAndErrorTailChangesAreBottomGrowth() {
        let base = ConversationScrollContentSnapshot(messageCount: 2, lastMessageIsUser: false)
        let withPermission = ConversationScrollContentSnapshot(
            messageCount: 2,
            lastMessageIsUser: false,
            hasPermissionNotice: true
        )
        let withError = ConversationScrollContentSnapshot(
            messageCount: 2,
            lastMessageIsUser: false,
            hasVisibleError: true
        )
        let withSelfEdit = ConversationScrollContentSnapshot(
            messageCount: 2,
            lastMessageIsUser: false,
            selfEditPreviewCount: 1
        )
        #expect(ConversationScrollPolicy.classifyContentChange(from: base, to: withPermission) == .bottomTailGrowth)
        #expect(ConversationScrollPolicy.classifyContentChange(from: base, to: withError) == .bottomTailGrowth)
        #expect(ConversationScrollPolicy.classifyContentChange(from: base, to: withSelfEdit) == .bottomTailGrowth)
    }

    @Test func activityRowMutationIsStructural() {
        let previous = ConversationScrollContentSnapshot(
            messageCount: 3,
            activityCount: 1,
            activityCharacterCount: 20
        )
        let current = ConversationScrollContentSnapshot(
            messageCount: 3,
            activityCount: 1,
            activityCharacterCount: 80
        )
        #expect(ConversationScrollPolicy.classifyContentChange(from: previous, to: current) == .structuralOrAbove)
    }

    // MARK: - Session restoration

    @Test func sessionActivationRestoresFollowWhenPinned() {
        let state = ConversationScrollSessionState(isFollowingTail: true, metrics: near)
        let result = ConversationScrollPolicy.decideSessionActivation(state: state, reduceMotion: false)
        #expect(result.command == .followTail(animated: false))
        #expect(result.state.programmaticCorrectionActive)
    }

    @Test func sessionActivationRestoresPreservedOffsetWhenBrowsing() {
        let state = ConversationScrollSessionState(
            isFollowingTail: false,
            metrics: browsing,
            preservedOffsetY: 222
        )
        let result = ConversationScrollPolicy.decideSessionActivation(state: state, reduceMotion: true)
        #expect(result.command == .restoreOffset(y: 222, animated: false))
    }

    @Test func sessionActivationDefaultsToFollowWhenNoMetrics() {
        let result = ConversationScrollPolicy.decideSessionActivation(state: .fresh, reduceMotion: false)
        #expect(result.command == .followTail(animated: false))
        #expect(result.state.isFollowingTail)
    }

    // MARK: - Insignificant / no-op geometry

    @Test func insignificantGeometryChangeIsNoOpForIntent() {
        let state = ConversationScrollSessionState(
            isFollowingTail: false,
            metrics: browsing,
            preservedOffsetY: browsing.contentOffsetY,
            lastContentHeight: browsing.contentHeight
        )
        let jitter = ConversationScrollMetrics(
            contentOffsetY: browsing.contentOffsetY + 0.2,
            containerHeight: browsing.containerHeight,
            contentHeight: browsing.contentHeight + 0.1
        )
        #expect(ConversationScrollPolicy.isInsignificantGeometryChange(from: browsing, to: jitter))
        let next = ConversationScrollPolicy.ingestGeometry(jitter, state: state)
        #expect(!next.isFollowingTail)
        #expect(next.preservedOffsetY == browsing.contentOffsetY)
    }

    @Test func identicalContentSnapshotYieldsNoCommand() {
        let snapshot = ConversationScrollContentSnapshot(
            messageCount: 2,
            lastMessageID: UUID(),
            lastMessageCharacterCount: 9,
            lastMessageIsUser: false
        )
        let state = ConversationScrollSessionState(
            isFollowingTail: true,
            metrics: near,
            contentSnapshot: snapshot
        )
        let result = ConversationScrollPolicy.decideContentChange(
            state: state,
            content: snapshot,
            measuredMetrics: near,
            reduceMotion: false
        )
        #expect(result.command == .none)
        #expect(result.state == state)
    }

    @Test func nonScrollableContentCountsAsNearBottom() {
        let metrics = ConversationScrollMetrics(contentOffsetY: 0, containerHeight: 600, contentHeight: 240)
        #expect(metrics.isNearBottom())
        #expect(metrics.distanceFromBottom == 0)
    }

    @Test func programmaticCorrectionDoesNotFlipToBrowseOnNearBottomSettle() {
        var state = ConversationScrollSessionState(
            isFollowingTail: true,
            metrics: browsing,
            pendingOutgoingFollow: true,
            programmaticCorrectionActive: true
        )
        state = ConversationScrollPolicy.ingestGeometry(near, state: state)
        #expect(state.isFollowingTail)
        #expect(!state.pendingOutgoingFollow)
        #expect(!state.programmaticCorrectionActive)
    }

    @Test func userScrollInterruptsProgrammaticFollow() {
        let userBrowse = ConversationScrollMetrics(
            contentOffsetY: 240,
            containerHeight: 400,
            contentHeight: 1_300,
            isPositionedByUser: true
        )
        var state = ConversationScrollSessionState(
            isFollowingTail: true,
            metrics: near,
            pendingOutgoingFollow: true,
            programmaticCorrectionActive: true,
            isUserInteracting: true
        )
        state = ConversationScrollPolicy.ingestGeometry(userBrowse, state: state)
        #expect(!state.isFollowingTail)
        #expect(!state.pendingOutgoingFollow)
        #expect(!state.programmaticCorrectionActive)
        #expect(state.preservedOffsetY == 240)
    }

    @Test func userGestureWinsOverConcurrentStructuralHeightChange() {
        let previous = ConversationScrollMetrics(contentOffsetY: 500, containerHeight: 400, contentHeight: 1_500)
        let userSample = ConversationScrollMetrics(
            contentOffsetY: 180,
            containerHeight: 400,
            contentHeight: 1_650,
            isPositionedByUser: true
        )
        let state = ConversationScrollSessionState(
            isFollowingTail: false,
            metrics: previous,
            preservedOffsetY: 500,
            isUserInteracting: true,
            pendingGeometryChange: .structuralOrAbove
        )
        let result = ConversationScrollPolicy.decideGeometryChange(userSample, state: state)
        #expect(result.command == .none)
        #expect(result.state.preservedOffsetY == 180)
        #expect(result.state.pendingGeometryChange == nil)
    }

    @Test func interactionPhaseCancelsSettlingFollowAndCapturesOffset() {
        let state = ConversationScrollSessionState(
            isFollowingTail: true,
            metrics: browsing,
            pendingOutgoingFollow: true,
            programmaticCorrectionActive: true
        )
        let interacting = ConversationScrollPolicy.setUserInteraction(true, state: state)
        #expect(interacting.isUserInteracting)
        #expect(!interacting.isFollowingTail)
        #expect(!interacting.pendingOutgoingFollow)
        #expect(!interacting.programmaticCorrectionActive)
        #expect(interacting.preservedOffsetY == browsing.contentOffsetY)
        let idle = ConversationScrollPolicy.setUserInteraction(false, state: interacting)
        #expect(!idle.isUserInteracting)
        #expect(idle.preservedOffsetY == browsing.contentOffsetY)
    }

    @Test func lazyHeightGrowthKeepsAnExistingFollowerAtTail() {
        let initial = ConversationScrollMetrics(contentOffsetY: 600, containerHeight: 400, contentHeight: 1_000)
        let realized = ConversationScrollMetrics(contentOffsetY: 600, containerHeight: 400, contentHeight: 1_500)
        let state = ConversationScrollSessionState(
            isFollowingTail: true,
            metrics: initial,
            programmaticCorrectionActive: true
        )
        let result = ConversationScrollPolicy.decideGeometryChange(realized, state: state)
        #expect(result.command == .followTail(animated: false))
        #expect(result.state.isFollowingTail)
        #expect(result.state.programmaticCorrectionActive)
    }

    @Test func lazyHeightGrowthRetriesSavedSessionOffset() {
        let partial = ConversationScrollMetrics(contentOffsetY: 80, containerHeight: 400, contentHeight: 900)
        let realized = ConversationScrollMetrics(contentOffsetY: 80, containerHeight: 400, contentHeight: 1_500)
        let state = ConversationScrollSessionState(
            isFollowingTail: false,
            metrics: partial,
            preservedOffsetY: 240,
            programmaticCorrectionActive: true
        )
        let result = ConversationScrollPolicy.decideGeometryChange(realized, state: state)
        #expect(result.command == .restoreOffset(y: 240, animated: false))
        #expect(result.state.preservedOffsetY == 240)
        #expect(result.state.programmaticCorrectionActive)
    }

    @Test func lazySessionRestoreUsesMeasuredProgressAsContentRealizes() {
        let partial = ConversationScrollMetrics(contentOffsetY: 80, containerHeight: 400, contentHeight: 900)
        let realized = ConversationScrollMetrics(contentOffsetY: 80, containerHeight: 400, contentHeight: 1_500)
        let state = ConversationScrollSessionState(
            isFollowingTail: false,
            metrics: partial,
            preservedOffsetY: 240,
            preservedProgress: 0.5,
            programmaticCorrectionActive: true
        )
        let result = ConversationScrollPolicy.decideGeometryChange(realized, state: state)
        #expect(result.command == .restoreOffset(y: 550, animated: false))
        #expect(result.state.preservedProgress == 0.5)
    }

    @Test func tailSentinelIDIsStable() {
        #expect(ConversationScrollPolicy.tailSentinelID == "lattice.conversation.scroll.tail")
    }

    // MARK: - Pending new-content awareness

    @Test func initialSnapshotDoesNotIncrementPending() {
        let content = ConversationScrollContentSnapshot(
            messageCount: 4,
            lastMessageID: UUID(),
            lastMessageCharacterCount: 40,
            lastMessageIsUser: false
        )
        let result = ConversationScrollPolicy.decideContentChange(
            state: ConversationScrollSessionState(isFollowingTail: false, metrics: browsing),
            content: content,
            measuredMetrics: browsing,
            reduceMotion: false
        )
        #expect(result.command == .none)
        #expect(result.state.pendingNewContentCount == 0)
        #expect(result.state.contentSnapshot == content)
    }

    @Test func streamingWhileBrowsingIncrementsOncePerDeltaAndDoesNotMoveViewport() {
        let messageID = UUID()
        let previous = ConversationScrollContentSnapshot(
            messageCount: 3,
            lastMessageID: messageID,
            lastMessageCharacterCount: 10,
            lastMessageRevision: 1,
            lastMessageIsUser: false,
            isStreaming: true
        )
        var state = ConversationScrollSessionState(
            isFollowingTail: false,
            metrics: browsing,
            preservedOffsetY: browsing.contentOffsetY,
            lastContentHeight: browsing.contentHeight,
            contentSnapshot: previous,
            pendingNewContentCount: 0
        )
        let mid = ConversationScrollContentSnapshot(
            messageCount: 3,
            lastMessageID: messageID,
            lastMessageCharacterCount: 80,
            lastMessageRevision: 2,
            lastMessageIsUser: false,
            isStreaming: true
        )
        let first = ConversationScrollPolicy.decideContentChange(
            state: state,
            content: mid,
            measuredMetrics: browsing,
            reduceMotion: false
        )
        #expect(first.command == .none)
        #expect(first.state.pendingNewContentCount == 1)
        #expect(!first.state.isFollowingTail)
        #expect(first.state.preservedOffsetY == browsing.contentOffsetY)

        let late = ConversationScrollContentSnapshot(
            messageCount: 3,
            lastMessageID: messageID,
            lastMessageCharacterCount: 240,
            lastMessageRevision: 3,
            lastMessageIsUser: false,
            isStreaming: true
        )
        let second = ConversationScrollPolicy.decideContentChange(
            state: first.state,
            content: late,
            measuredMetrics: browsing,
            reduceMotion: false
        )
        #expect(second.command == .none)
        #expect(second.state.pendingNewContentCount == 2)
        #expect(ConversationScrollPolicy.logicalNewContentIncrement(
            from: previous,
            to: mid,
            changeKind: .bottomTailGrowth
        ) == 1)
    }

    @Test func streamingWhileFollowingDoesNotIncrementPending() {
        let messageID = UUID()
        let previous = ConversationScrollContentSnapshot(
            messageCount: 2,
            lastMessageID: messageID,
            lastMessageCharacterCount: 10,
            lastMessageIsUser: false,
            isStreaming: true
        )
        let state = ConversationScrollSessionState(
            isFollowingTail: true,
            metrics: near,
            contentSnapshot: previous
        )
        let next = ConversationScrollContentSnapshot(
            messageCount: 2,
            lastMessageID: messageID,
            lastMessageCharacterCount: 90,
            lastMessageIsUser: false,
            isStreaming: true
        )
        let result = ConversationScrollPolicy.decideContentChange(
            state: state,
            content: next,
            measuredMetrics: near,
            reduceMotion: false
        )
        #expect(result.command == .followTail(animated: false))
        #expect(result.state.pendingNewContentCount == 0)
    }

    @Test func assistantAndTailAccessoryArrivalsIncrementWhileBrowsing() {
        let base = ConversationScrollContentSnapshot(messageCount: 2, lastMessageIsUser: false)
        let browsingState = ConversationScrollSessionState(
            isFollowingTail: false,
            metrics: browsing,
            preservedOffsetY: browsing.contentOffsetY,
            contentSnapshot: base
        )

        let withAssistant = ConversationScrollContentSnapshot(
            messageCount: 3,
            lastMessageID: UUID(),
            lastMessageCharacterCount: 12,
            lastMessageIsUser: false
        )
        let assistant = ConversationScrollPolicy.decideContentChange(
            state: browsingState,
            content: withAssistant,
            measuredMetrics: browsing,
            reduceMotion: false
        )
        #expect(assistant.command == .none)
        #expect(assistant.state.pendingNewContentCount == 1)

        let withPermission = ConversationScrollContentSnapshot(
            messageCount: 2,
            lastMessageIsUser: false,
            hasPermissionNotice: true,
            permissionNoticeID: UUID()
        )
        #expect(ConversationScrollPolicy.decideContentChange(
            state: browsingState,
            content: withPermission,
            measuredMetrics: browsing,
            reduceMotion: false
        ).state.pendingNewContentCount == 1)

        let withError = ConversationScrollContentSnapshot(
            messageCount: 2,
            lastMessageIsUser: false,
            hasVisibleError: true,
            visibleErrorRevision: 7
        )
        #expect(ConversationScrollPolicy.decideContentChange(
            state: browsingState,
            content: withError,
            measuredMetrics: browsing,
            reduceMotion: false
        ).state.pendingNewContentCount == 1)

        let withSelfEdit = ConversationScrollContentSnapshot(
            messageCount: 2,
            lastMessageIsUser: false,
            selfEditPreviewCount: 1,
            selfEditPreviewRevision: 3
        )
        #expect(ConversationScrollPolicy.decideContentChange(
            state: browsingState,
            content: withSelfEdit,
            measuredMetrics: browsing,
            reduceMotion: false
        ).state.pendingNewContentCount == 1)
    }

    @Test func tailActivityArrivalsCountWhileAboveActivityDoesNot() {
        let previous = ConversationScrollContentSnapshot(
            messageCount: 3,
            lastMessageID: UUID(),
            lastMessageIsUser: false,
            activityCount: 1,
            activityCharacterCount: 20,
            activityRevision: 1,
            tailActivityCount: 0,
            aboveActivityCount: 1,
            aboveActivityCharacterCount: 20,
            aboveActivityRevision: 1
        )
        let browsingState = ConversationScrollSessionState(
            isFollowingTail: false,
            metrics: browsing,
            contentSnapshot: previous,
            pendingNewContentCount: 0
        )

        let tailArrival = ConversationScrollContentSnapshot(
            messageCount: 3,
            lastMessageID: previous.lastMessageID,
            lastMessageIsUser: false,
            activityCount: 2,
            activityCharacterCount: 50,
            activityRevision: 2,
            tailActivityCount: 1,
            tailActivityCharacterCount: 30,
            tailActivityRevision: 2,
            aboveActivityCount: 1,
            aboveActivityCharacterCount: 20,
            aboveActivityRevision: 1
        )
        #expect(ConversationScrollPolicy.classifyContentChange(from: previous, to: tailArrival) == .bottomTailGrowth)
        let counted = ConversationScrollPolicy.decideContentChange(
            state: browsingState,
            content: tailArrival,
            measuredMetrics: browsing,
            reduceMotion: false
        )
        #expect(counted.command == .none)
        #expect(counted.state.pendingNewContentCount == 1)

        let aboveUpdate = ConversationScrollContentSnapshot(
            messageCount: 3,
            lastMessageID: previous.lastMessageID,
            lastMessageIsUser: false,
            activityCount: 1,
            activityCharacterCount: 80,
            activityRevision: 9,
            tailActivityCount: 0,
            aboveActivityCount: 1,
            aboveActivityCharacterCount: 80,
            aboveActivityRevision: 9
        )
        #expect(ConversationScrollPolicy.classifyContentChange(from: previous, to: aboveUpdate) == .structuralOrAbove)
        let structural = ConversationScrollPolicy.decideContentChange(
            state: browsingState,
            content: aboveUpdate,
            measuredMetrics: browsing,
            reduceMotion: false
        )
        #expect(structural.state.pendingNewContentCount == 0)
        #expect(structural.command == .none)
    }

    @Test func tailActivityStatusUpdateIncrementsWhileBrowsing() {
        let previous = ConversationScrollContentSnapshot(
            messageCount: 2,
            lastMessageID: UUID(),
            activityCount: 1,
            activityCharacterCount: 10,
            activityRevision: 1,
            tailActivityCount: 1,
            tailActivityCharacterCount: 10,
            tailActivityRevision: 1
        )
        let current = ConversationScrollContentSnapshot(
            messageCount: 2,
            lastMessageID: previous.lastMessageID,
            activityCount: 1,
            activityCharacterCount: 40,
            activityRevision: 2,
            tailActivityCount: 1,
            tailActivityCharacterCount: 40,
            tailActivityRevision: 2
        )
        #expect(ConversationScrollPolicy.classifyContentChange(from: previous, to: current) == .bottomTailGrowth)
        #expect(ConversationScrollPolicy.logicalNewContentIncrement(
            from: previous,
            to: current,
            changeKind: .bottomTailGrowth
        ) == 1)
    }

    @Test func pureReflowDoesNotIncrementPending() {
        let state = ConversationScrollSessionState(
            isFollowingTail: false,
            metrics: browsing,
            preservedOffsetY: browsing.contentOffsetY,
            lastContentHeight: browsing.contentHeight,
            pendingNewContentCount: 2
        )
        let reflowed = ConversationScrollMetrics(
            contentOffsetY: browsing.contentOffsetY,
            containerHeight: browsing.containerHeight,
            contentHeight: browsing.contentHeight + 80
        )
        let result = ConversationScrollPolicy.decideGeometryChange(reflowed, state: state)
        #expect(result.state.pendingNewContentCount == 2)
        #expect(result.command == .restoreOffset(y: browsing.contentOffsetY + 80, animated: false))
    }

    @Test func nearBottomManuallyClearsPending() {
        var state = ConversationScrollSessionState(
            isFollowingTail: false,
            metrics: browsing,
            preservedOffsetY: browsing.contentOffsetY,
            pendingNewContentCount: 4
        )
        state = ConversationScrollPolicy.ingestGeometry(near, state: state)
        #expect(state.isFollowingTail)
        #expect(state.pendingNewContentCount == 0)
        #expect(!ConversationScrollPolicy.shouldShowJumpToLatest(state: state))
    }

    @Test func jumpToLatestClearsPendingAndFollowsOnce() {
        let state = ConversationScrollSessionState(
            isFollowingTail: false,
            metrics: browsing,
            preservedOffsetY: browsing.contentOffsetY,
            pendingNewContentCount: 5
        )
        let withMotion = ConversationScrollPolicy.decideJumpToLatest(state: state, reduceMotion: false)
        #expect(withMotion.command == .followTail(animated: true))
        #expect(withMotion.state.pendingNewContentCount == 0)
        #expect(withMotion.state.isFollowingTail)
        #expect(!withMotion.state.pendingOutgoingFollow)
        #expect(!ConversationScrollPolicy.shouldShowJumpToLatest(state: withMotion.state))

        let reduced = ConversationScrollPolicy.decideJumpToLatest(state: state, reduceMotion: true)
        #expect(reduced.command == .followTail(animated: false))
        #expect(reduced.state.pendingNewContentCount == 0)
    }

    @Test func outgoingActionClearsPendingAndFollows() {
        let state = ConversationScrollSessionState(
            isFollowingTail: false,
            metrics: browsing,
            preservedOffsetY: browsing.contentOffsetY,
            pendingNewContentCount: 3
        )
        let result = ConversationScrollPolicy.decideOutgoingUserAction(state: state, reduceMotion: false)
        #expect(result.state.pendingNewContentCount == 0)
        #expect(result.state.isFollowingTail)
        #expect(result.command == .followTail(animated: true))
    }

    @Test func sessionSwitchPreservesPendingCount() {
        let state = ConversationScrollSessionState(
            isFollowingTail: false,
            metrics: browsing,
            preservedOffsetY: 180,
            pendingNewContentCount: 7
        )
        let result = ConversationScrollPolicy.decideSessionActivation(state: state, reduceMotion: false)
        #expect(result.state.pendingNewContentCount == 7)
        #expect(result.command == .restoreOffset(y: 180, animated: false))
        #expect(ConversationScrollPolicy.shouldShowJumpToLatest(state: result.state))
    }

    @Test func freshBranchStateHasZeroPendingAndFollowsTail() {
        let branch = ConversationScrollPolicy.freshBranchState()
        #expect(branch.pendingNewContentCount == 0)
        #expect(branch.isFollowingTail)
        #expect(branch == .fresh)
    }

    @Test func messageDeletionClearsStalePendingCount() {
        let previous = ConversationScrollContentSnapshot(
            messageCount: 6,
            lastMessageID: UUID(),
            lastMessageCharacterCount: 20,
            lastMessageIsUser: false
        )
        let state = ConversationScrollSessionState(
            isFollowingTail: false,
            metrics: browsing,
            preservedOffsetY: browsing.contentOffsetY,
            contentSnapshot: previous,
            pendingNewContentCount: 4
        )
        let truncated = ConversationScrollContentSnapshot(
            messageCount: 2,
            lastMessageID: UUID(),
            lastMessageCharacterCount: 8,
            lastMessageIsUser: false
        )
        let result = ConversationScrollPolicy.decideContentChange(
            state: state,
            content: truncated,
            measuredMetrics: browsing,
            reduceMotion: false
        )
        #expect(result.command == .none)
        #expect(result.state.pendingNewContentCount == 0)
        #expect(result.state.pendingGeometryChange == .structuralOrAbove)
    }

    @Test func stopOnlyStreamingTransitionDoesNotInventPending() {
        let messageID = UUID()
        let streaming = ConversationScrollContentSnapshot(
            messageCount: 2,
            lastMessageID: messageID,
            lastMessageCharacterCount: 40,
            lastMessageRevision: 4,
            lastMessageIsUser: false,
            isStreaming: true
        )
        let stopped = ConversationScrollContentSnapshot(
            messageCount: 2,
            lastMessageID: messageID,
            lastMessageCharacterCount: 40,
            lastMessageRevision: 4,
            lastMessageIsUser: false,
            isStreaming: false
        )
        #expect(ConversationScrollPolicy.classifyContentChange(from: streaming, to: stopped) == .none)
        let state = ConversationScrollSessionState(
            isFollowingTail: false,
            metrics: browsing,
            contentSnapshot: streaming,
            pendingNewContentCount: 2
        )
        let result = ConversationScrollPolicy.decideContentChange(
            state: state,
            content: stopped,
            measuredMetrics: browsing,
            reduceMotion: false
        )
        #expect(result.command == .none)
        #expect(result.state.pendingNewContentCount == 2)
    }

    @Test func jumpAffordanceVisibilityAndDisplayCap() {
        let hidden = ConversationScrollSessionState(isFollowingTail: true, pendingNewContentCount: 3)
        #expect(!ConversationScrollPolicy.shouldShowJumpToLatest(state: hidden))
        #expect(ConversationScrollPolicy.jumpAffordance(for: hidden) == .hidden)

        let visible = ConversationScrollSessionState(isFollowingTail: false, pendingNewContentCount: 1)
        #expect(ConversationScrollPolicy.shouldShowJumpToLatest(state: visible))
        let affordance = ConversationScrollPolicy.jumpAffordance(for: visible)
        #expect(affordance.isVisible && affordance.pendingCount == 1)
        #expect(ConversationScrollPolicy.jumpToLatestAccessibilityValue(count: 1) == "1 new update")
        #expect(ConversationScrollPolicy.jumpToLatestAccessibilityValue(count: 3) == "3 new updates")
        #expect(ConversationScrollPolicy.displayedPendingCount(99) == "99")
        #expect(ConversationScrollPolicy.displayedPendingCount(100) == "99+")
        #expect(ConversationScrollPolicy.jumpToLatestAccessibilityValue(count: 120) == "99+ new updates")
        #expect(ConversationScrollPolicy.jumpToLatestAccessibilityLabel() == "Jump to Latest")
    }

    @Test func contentGrowthWhileBrowsingPreservesViewportCommandNone() {
        let messageID = UUID()
        let previous = ConversationScrollContentSnapshot(
            messageCount: 3,
            lastMessageID: messageID,
            lastMessageCharacterCount: 10,
            lastMessageIsUser: false
        )
        let state = ConversationScrollSessionState(
            isFollowingTail: false,
            metrics: browsing,
            preservedOffsetY: browsing.contentOffsetY,
            lastContentHeight: browsing.contentHeight,
            contentSnapshot: previous,
            pendingNewContentCount: 0
        )
        let grown = ConversationScrollContentSnapshot(
            messageCount: 3,
            lastMessageID: messageID,
            lastMessageCharacterCount: 400,
            lastMessageIsUser: false
        )
        let contentResult = ConversationScrollPolicy.decideContentChange(
            state: state,
            content: grown,
            measuredMetrics: browsing,
            reduceMotion: false
        )
        #expect(contentResult.command == .none)
        #expect(contentResult.state.pendingNewContentCount == 1)

        let taller = ConversationScrollMetrics(
            contentOffsetY: browsing.contentOffsetY,
            containerHeight: browsing.containerHeight,
            contentHeight: browsing.contentHeight + 220
        )
        let geometry = ConversationScrollPolicy.decideGeometryChange(taller, state: contentResult.state)
        #expect(geometry.command == .none)
        #expect(geometry.state.pendingNewContentCount == 1)
        #expect(!geometry.state.isFollowingTail)
        #expect(geometry.state.preservedOffsetY == browsing.contentOffsetY)
    }

    @Test func simultaneousAboveReflowAndTailGrowthStillCountsTail() {
        let messageID = UUID()
        let previous = ConversationScrollContentSnapshot(
            messageCount: 3,
            lastMessageID: messageID,
            lastMessageCharacterCount: 20,
            lastMessageRevision: 1,
            activityCount: 1,
            activityCharacterCount: 10,
            activityRevision: 1,
            aboveActivityCount: 1,
            aboveActivityCharacterCount: 10,
            aboveActivityRevision: 1,
            isStreaming: true
        )
        let current = ConversationScrollContentSnapshot(
            messageCount: 3,
            lastMessageID: messageID,
            lastMessageCharacterCount: 60,
            lastMessageRevision: 2,
            activityCount: 1,
            activityCharacterCount: 30,
            activityRevision: 2,
            aboveActivityCount: 1,
            aboveActivityCharacterCount: 30,
            aboveActivityRevision: 2,
            isStreaming: true
        )
        let result = ConversationScrollPolicy.decideContentChange(
            state: ConversationScrollSessionState(
                isFollowingTail: false,
                metrics: browsing,
                contentSnapshot: previous
            ),
            content: current,
            measuredMetrics: browsing,
            reduceMotion: false
        )
        #expect(result.command == .none)
        #expect(result.state.pendingGeometryChange == .structuralOrAbove)
        #expect(result.state.pendingNewContentCount == 1)
    }

    @Test func removingUnreadTailAccessoryReconcilesPendingCount() {
        let noticeID = UUID()
        let previous = ConversationScrollContentSnapshot(
            messageCount: 2,
            hasPermissionNotice: true,
            permissionNoticeID: noticeID
        )
        let current = ConversationScrollContentSnapshot(messageCount: 2)
        let result = ConversationScrollPolicy.decideContentChange(
            state: ConversationScrollSessionState(
                isFollowingTail: false,
                metrics: browsing,
                contentSnapshot: previous,
                pendingNewContentCount: 1
            ),
            content: current,
            measuredMetrics: browsing,
            reduceMotion: false
        )
        #expect(result.command == .none)
        #expect(result.state.pendingNewContentCount == 0)
    }
}
