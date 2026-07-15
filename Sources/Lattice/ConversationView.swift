import Foundation
import SwiftUI
import AppKit
import LatticeCore

struct ConversationView: View {
    @ObservedObject var state: AppState
    var showsComposer = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var conversationScrollPosition: Binding<ScrollPosition> {
        Binding(
            get: { state.conversationScrollPosition },
            set: { state.conversationScrollPosition = $0 }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if let session = state.selectedSession {
                if state.isSelectedTranscriptLoading {
                    TranscriptLoadingView()
                } else if session.messages.isEmpty {
                    EmptyConversationView(state: state)
                } else {
                    ScrollViewReader { proxy in
                        GeometryReader { geometry in
                            let horizontalPadding = CGFloat(
                                LatticeMessageRowLayoutPolicy.transcriptHorizontalPadding(
                                    forWidth: Double(geometry.size.width)
                                )
                            )
                            let messageRowWidth = min(
                                CGFloat(LatticeMessageRowLayoutPolicy.transcriptMaxWidth),
                                LatticeTypography.transcriptMaxReadableWidth,
                                max(0, geometry.size.width - (horizontalPadding * 2))
                            )

                            ZStack(alignment: .bottom) {
                                ScrollView {
                                    LazyVStack(alignment: .leading, spacing: 22) {
                                        let hiddenEarlierCount = state.hiddenEarlierMessageCount(for: session)
                                        if hiddenEarlierCount > 0 {
                                            Button {
                                                state.loadEarlierMessages(for: session.id)
                                            } label: {
                                                Label(
                                                    "Load Earlier Messages",
                                                    systemImage: "arrow.up.to.line"
                                                )
                                            }
                                            .buttonStyle(.borderless)
                                            .frame(maxWidth: .infinity)
                                            .accessibilityLabel("Load earlier messages")
                                            .accessibilityValue("\(hiddenEarlierCount) earlier messages")
                                            .help("Show up to \(min(100, hiddenEarlierCount)) earlier messages")
                                        }
                                        ForEach(state.visibleMessages(for: session)) { message in
                                            let messageArtifacts = AssistantArtifactTrail.artifacts(
                                                for: message.id,
                                                in: session.artifacts
                                            )
                                            MessageRow(
                                                message: message,
                                                artifacts: messageArtifacts,
                                                isSessionStreaming: session.isStreaming,
                                                availableWidth: messageRowWidth,
                                                state: state
                                            )
                                            .id(message.id)
                                            let messageActions = session.actions.filter { $0.messageID == message.id }
                                            if session.executionRoute.mode != .work, !messageActions.isEmpty {
                                                AssistantActivityDisclosure(actions: messageActions, state: state)
                                            }
                                        }
                                        if session.executionRoute.mode == .work {
                                            let projectedActionIDs = Set(state.workProjection(for: session).log.map(\.actionID))
                                            let workLogActions = session.actions.filter { projectedActionIDs.contains($0.id) }
                                            if !workLogActions.isEmpty {
                                                WorkLogDisclosure(actions: workLogActions) { target in
                                                    state.workOriginJumpTarget = target
                                                }
                                            }
                                        }
                                        ForEach(session.queuedFollowUps) { followUp in
                                            QueuedFollowUpRow(
                                                followUp: followUp,
                                                isFIFOHead: session.queuedFollowUps.first?.id == followUp.id,
                                                sessionIsStreaming: session.isStreaming,
                                                state: state
                                            )
                                                .id(followUp.id)
                                        }
                                        ForEach(state.visibleSelfEditPreviews(for: session.id)) { preview in
                                            SelfEditPreviewRow(preview: preview, state: state)
                                                .id(preview.id)
                                        }
                                        if session.executionRoute.mode != .work,
                                           let notice = state.harnessPermissionNotice(for: session.id) {
                                            HarnessPermissionNoticeRow(notice: notice, state: state)
                                                .id(notice.id)
                                        }
                                        if let error = state.visibleErrorMessage(for: session.id) {
                                            ErrorRow(message: error, canRetry: state.canRetrySelectedSession) {
                                                state.retrySelectedSession()
                                            }
                                                .id("lattice.conversation.error.\(session.id.uuidString)")
                                        }
                                        // Stable bottom sentinel for every tail row type (messages, follow-ups, previews, permission, error).
                                        Color.clear
                                            .frame(height: 1)
                                            .id(ConversationScrollPolicy.tailSentinelID)
                                            .accessibilityHidden(true)
                                    }
                                    .scrollTargetLayout()
                                    .frame(maxWidth: CGFloat(LatticeMessageRowLayoutPolicy.transcriptMaxWidth))
                                    .padding(.horizontal, horizontalPadding)
                                    .padding(.vertical, 28)
                                    .frame(maxWidth: .infinity)
                                }
                                .scrollPosition(conversationScrollPosition)
                                .defaultScrollAnchor(.bottom, for: .initialOffset)
                                .accessibilityIdentifier(LatticeAccessibilityID.conversationScroll)
                                .accessibilityLabel("Conversation transcript")
                                .accessibilityValue(scrollAccessibilityValue(for: session.id))
                                .onScrollPhaseChange { _, phase in
                                    let isUserInteracting: Bool
                                    switch phase {
                                    case .tracking, .interacting, .decelerating:
                                        isUserInteracting = true
                                    case .idle, .animating:
                                        isUserInteracting = false
                                    }
                                    let sessionID = session.id
                                    guard state.selectedSessionID == sessionID else { return }
                                    let current = state.conversationScrollStates[sessionID] ?? .fresh
                                    state.applyConversationScrollState(
                                        ConversationScrollPolicy.setUserInteraction(isUserInteracting, state: current),
                                        for: sessionID
                                    )
                                }
                                .onScrollGeometryChange(for: ConversationScrollMetrics.self) { geometry in
                                    ConversationScrollMetrics(
                                        contentOffsetY: geometry.contentOffset.y,
                                        containerHeight: geometry.containerSize.height,
                                        contentHeight: geometry.contentSize.height,
                                        isPositionedByUser: state.conversationScrollPosition.isPositionedByUser
                                    )
                                } action: { _, metrics in
                                    let sessionID = session.id
                                    guard state.selectedSessionID == sessionID else { return }
                                    let result = ConversationScrollPolicy.decideGeometryChange(
                                        metrics,
                                        state: state.conversationScrollStates[sessionID] ?? .fresh
                                    )
                                    state.applyConversationScrollState(result.state, for: sessionID)
                                    applyScrollCommand(result.command, proxy: proxy)
                                }
                                .onChange(of: contentSignature(for: session)) { _, _ in
                                    handleContentChange(session: session, proxy: proxy)
                                }
                                .onChange(of: session.id) { _, newID in
                                    handleSessionActivation(sessionID: newID, proxy: proxy)
                                    scheduleSessionActivation(sessionID: newID, proxy: proxy)
                                }
                                .onAppear {
                                    handleContentChange(session: session, proxy: proxy)
                                    handleSessionActivation(sessionID: session.id, proxy: proxy)
                                    scheduleSessionActivation(sessionID: session.id, proxy: proxy)
                                }
                                .onChange(of: state.workOriginJumpTarget) { _, target in
                                    handleWorkOriginJump(target, proxy: proxy)
                                }

                                if let affordance = state.conversationJumpAffordances[session.id],
                                   affordance.isVisible,
                                   state.selectedSessionID == session.id {
                                    JumpToLatestControl(count: affordance.pendingCount) {
                                        handleJumpToLatest(sessionID: session.id, proxy: proxy)
                                    }
                                    .padding(.bottom, 14)
                                    .transition(jumpControlTransition)
                                    .zIndex(1)
                                }
                            }
                            .animation(jumpControlAnimation, value: state.conversationJumpAffordances[session.id]?.isVisible == true)
                        }
                    }
                }
                if showsComposer {
                    if let sessionID = state.selectedSessionID {
                        ComputerFrameCard(presentation: state.computerFramePresentation(for: sessionID))
                            .padding(.horizontal)
                            .padding(.top, 8)
                    }
                    if session.executionRoute.mode == .work {
                        WorkActionDock(session: session, state: state) { target in
                            state.workOriginJumpTarget = target
                        }
                    }
                    if session.executionRoute.mode == .code,
                       let review = state.selectedCheckpointReview,
                       review.activity == .ready,
                       review.changes != nil {
                        CodeCheckpointReviewStrip(state: state, review: review)
                    }
                    ComposerView(state: state)
                }
            } else if state.isTransientNewChat {
                NewChatShellView(state: state)
                if showsComposer {
                    ComposerView(state: state)
                }
            } else {
                LatticeEmptyState(
                    title: "Start a chat",
                    message: "Create one from the New chat button in the toolbar.",
                    systemImage: "bubble.left.and.bubble.right",
                    primaryActionTitle: "New chat",
                    primaryAction: { state.newSession() }
                )
            }
        }
        .navigationTitle(state.selectedSession?.title ?? "Chats")
    }

    private func scrollAccessibilityValue(for sessionID: UUID) -> String {
        let following = state.conversationScrollStates[sessionID]?.isFollowingTail ?? true
        return following ? "Following latest messages" : "Reading earlier messages"
    }

    private func handleWorkOriginJump(_ target: UUID?, proxy: ScrollViewProxy) {
        guard let target else { return }
        proxy.scrollTo(target, anchor: .center)
        state.workOriginJumpTarget = nil
    }

    // MARK: - Scroll anchoring

    private var jumpControlAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.16)
    }

    private var jumpControlTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .opacity.combined(with: .move(edge: .bottom).combined(with: .scale(scale: 0.96)))
    }

    private func contentSignature(for session: LatticeSession) -> ConversationScrollContentSnapshot {
        let last = session.messages.last
        let lastMessageID = last?.id
        let previews = state.visibleSelfEditPreviews(for: session.id)
        let permission = state.harnessPermissionNotice(for: session.id)
        let error = state.visibleErrorMessage(for: session.id)
        let activityCharacterCount = session.actions.reduce(into: 0) { total, action in
            total += action.title.count + action.detail.count + action.status.rawValue.count
        }
        let tailActions = session.actions.filter { $0.messageID == lastMessageID }
        let aboveActions = session.actions.filter { $0.messageID != lastMessageID }
        let tailActivityCharacterCount = tailActions.reduce(into: 0) { total, action in
            total += action.title.count + action.detail.count + action.status.rawValue.count
        }
        let aboveActivityCharacterCount = aboveActions.reduce(into: 0) { total, action in
            total += action.title.count + action.detail.count + action.status.rawValue.count
        }
        return ConversationScrollContentSnapshot(
            messageCount: session.messages.count,
            lastMessageID: lastMessageID,
            lastMessageCharacterCount: last?.text.count ?? 0,
            lastMessageRevision: last?.text.hashValue ?? 0,
            lastMessageIsUser: last?.role == .user,
            outgoingActionSequence: state.conversationOutgoingActionSequence[session.id, default: 0],
            queuedFollowUpCount: session.queuedFollowUps.count,
            activityCount: session.actions.count,
            activityCharacterCount: activityCharacterCount,
            activityRevision: session.actions.hashValue,
            tailActivityCount: tailActions.count,
            tailActivityCharacterCount: tailActivityCharacterCount,
            tailActivityRevision: tailActions.hashValue,
            aboveActivityCount: aboveActions.count,
            aboveActivityCharacterCount: aboveActivityCharacterCount,
            aboveActivityRevision: aboveActions.hashValue,
            selfEditPreviewCount: previews.count,
            selfEditPreviewRevision: previews.hashValue,
            hasPermissionNotice: permission != nil,
            permissionNoticeID: permission?.id,
            hasVisibleError: error != nil,
            visibleErrorRevision: error?.hashValue ?? 0,
            isStreaming: session.isStreaming
        )
    }

    private func handleContentChange(session: LatticeSession, proxy: ScrollViewProxy) {
        let sessionID = session.id
        guard state.selectedSessionID == sessionID else { return }
        let content = contentSignature(for: session)
        let current = state.conversationScrollStates[sessionID] ?? .fresh
        let result = ConversationScrollPolicy.decideContentChange(
            state: current,
            content: content,
            measuredMetrics: current.metrics,
            reduceMotion: reduceMotion
        )
        state.applyConversationScrollState(result.state, for: sessionID)
        applyScrollCommand(result.command, proxy: proxy)
    }

    private func handleSessionActivation(sessionID: UUID, proxy: ScrollViewProxy) {
        let current = state.conversationScrollStates[sessionID] ?? .fresh
        let result = ConversationScrollPolicy.decideSessionActivation(
            state: current,
            reduceMotion: reduceMotion
        )
        state.applyConversationScrollState(result.state, for: sessionID)
        applyScrollCommand(result.command, proxy: proxy)
    }

    private func handleJumpToLatest(sessionID: UUID, proxy: ScrollViewProxy) {
        guard state.selectedSessionID == sessionID else { return }
        let current = state.conversationScrollStates[sessionID] ?? .fresh
        let result = ConversationScrollPolicy.decideJumpToLatest(
            state: current,
            reduceMotion: reduceMotion
        )
        state.applyConversationScrollState(result.state, for: sessionID)
        applyScrollCommand(result.command, proxy: proxy)
    }

    private func scheduleSessionActivation(sessionID: UUID, proxy: ScrollViewProxy) {
        Task { @MainActor in
            await Task.yield()
            guard state.selectedSessionID == sessionID else { return }
            handleSessionActivation(sessionID: sessionID, proxy: proxy)
        }
    }

    private func applyScrollCommand(_ command: ConversationScrollCommand, proxy: ScrollViewProxy) {
        switch command {
        case .none:
            return
        case .followTail(let animated):
            let scroll = {
                var position = state.conversationScrollPosition
                position.scrollTo(id: ConversationScrollPolicy.tailSentinelID, anchor: .bottom)
                state.conversationScrollPosition = position
                proxy.scrollTo(ConversationScrollPolicy.tailSentinelID, anchor: .bottom)
            }
            if animated && !reduceMotion {
                withAnimation(.easeOut(duration: 0.18), scroll)
            } else {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction, scroll)
            }
            let sessionID = state.selectedSessionID
            if sessionID.flatMap({ state.conversationScrollStates[$0] })?.pendingOutgoingFollow == true {
                Task { @MainActor in
                    await Task.yield()
                    guard state.selectedSessionID == sessionID else { return }
                    var transaction = Transaction()
                    transaction.disablesAnimations = reduceMotion || !animated
                    withTransaction(transaction) {
                        proxy.scrollTo(ConversationScrollPolicy.tailSentinelID, anchor: .bottom)
                    }
                }
            }
        case .restoreOffset(let y, let animated):
            let scroll = {
                var position = state.conversationScrollPosition
                position.scrollTo(y: CGFloat(y))
                state.objectWillChange.send()
                state.conversationScrollPosition = position
            }
            if animated && !reduceMotion {
                withAnimation(.easeOut(duration: 0.18), scroll)
            } else {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction, scroll)
            }
        }
    }
}

