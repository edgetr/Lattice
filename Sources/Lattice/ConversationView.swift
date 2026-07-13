import Foundation
import SwiftUI
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
                if session.messages.isEmpty {
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
                                max(0, geometry.size.width - (horizontalPadding * 2))
                            )

                            ZStack(alignment: .bottom) {
                                ScrollView {
                                    LazyVStack(alignment: .leading, spacing: 22) {
                                        ForEach(session.messages) { message in
                                            MessageRow(
                                                message: message,
                                                availableWidth: messageRowWidth,
                                                state: state
                                            )
                                            .id(message.id)
                                            let messageActions = session.actions.filter { $0.messageID == message.id }
                                            if !messageActions.isEmpty {
                                                AssistantActivityDisclosure(actions: messageActions)
                                            }
                                        }
                                        ForEach(session.queuedFollowUps) { followUp in
                                            QueuedFollowUpRow(followUp: followUp, sessionIsStreaming: session.isStreaming, state: state)
                                                .id(followUp.id)
                                        }
                                        ForEach(state.visibleSelfEditPreviews(for: session.id)) { preview in
                                            SelfEditPreviewRow(preview: preview, state: state)
                                                .id(preview.id)
                                        }
                                        if let notice = state.harnessPermissionNotice(for: session.id) {
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
                    ComposerView(state: state)
                }
            } else {
                ContentUnavailableView {
                    Label("Start a chat", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Create one from the New chat button in the toolbar.")
                }
            }
        }
        .navigationTitle(state.selectedSession?.title ?? "Chats")
    }

    private func scrollAccessibilityValue(for sessionID: UUID) -> String {
        let following = state.conversationScrollStates[sessionID]?.isFollowingTail ?? true
        return following ? "following-tail" : "browsing-history"
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

/// Compact Jump to Latest control overlaid on the conversation scroll area.
private struct JumpToLatestControl: View {
    let count: Int
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 11, weight: .semibold))
                Text("Jump to Latest")
                    .font(.caption.weight(.semibold))
                Text(ConversationScrollPolicy.displayedPendingCount(count))
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.pink.opacity(0.16), in: Capsule())
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Capsule())
        }
        .buttonStyle(LatticeScaleButtonStyle())
        .latticeGlass(cornerRadius: 20, interactive: true, tint: .pink.opacity(0.10))
        .accessibilityIdentifier(LatticeAccessibilityID.newContentIndicator)
        .accessibilityLabel(ConversationScrollPolicy.jumpToLatestAccessibilityLabel())
        .accessibilityValue(ConversationScrollPolicy.jumpToLatestAccessibilityValue(count: count))
        .accessibilityHint(ConversationScrollPolicy.jumpToLatestAccessibilityHint())
        .accessibilityAddTraits(.isButton)
        .help("Jump to the newest content (\(ConversationScrollPolicy.jumpToLatestAccessibilityValue(count: count)))")
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: count)
    }
}

private struct QueuedFollowUpRow: View {
    let followUp: QueuedFollowUp
    let sessionIsStreaming: Bool
    @ObservedObject var state: AppState

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                .foregroundStyle(.purple)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text("Queued follow-up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(followUp.text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            if !sessionIsStreaming {
                Button("Send now") { state.sendQueuedFollowUp(followUp.id) }
            }
            Button("Remove") { state.removeQueuedFollowUp(followUp.id) }
        }
        .padding(12)
        .latticeGlass(cornerRadius: 14, tint: .purple.opacity(0.08))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Queued follow-up")
    }
}

struct SelfEditPreviewRow: View {
    let preview: LatticeExtensionPreviewRecord
    @ObservedObject var state: AppState

    private var previousManifest: LatticeExtensionManifest? {
        preview.previousManifestData.flatMap { try? JSONDecoder().decode(LatticeExtensionManifest.self, from: $0) }
    }

    private var review: LatticeExtensionChangeReview {
        LatticeExtensionChangeReviewBuilder.review(current: preview.manifest, previous: previousManifest)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(.pink)
                    .frame(width: 22)
                Text("Review Lattice change")
                    .fontWeight(.semibold)
                Spacer()
                Text(previousManifest == nil ? "New" : "Update")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.pink.opacity(0.14), in: Capsule())
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("If you apply this")
                    .font(.caption.weight(.semibold))
                Text(review.acceptanceSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(review.changes.enumerated()), id: \.offset) { _, change in
                    Label(change, systemImage: "arrow.right.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.primary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(presentation.accessibilityLabel)
            .accessibilityValue(presentation.accessibilityValue ?? presentation.headline)
            .padding(10)
            .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack {
                Text("Ask for a revision in the composer, or apply exactly the changes shown above.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Discard") { state.discardSelfEditPreview(preview) }
                Button("Apply") { state.acceptSelfEditPreview(preview) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!review.hasChanges)
                    .help(review.hasChanges ? "Apply this Lattice change" : "There are no changes to apply")
            }
        }
        .padding(14)
        .latticeGlass(cornerRadius: 16, tint: .pink.opacity(0.08))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(LatticeAccessibilityID.selfEditReview)
        .accessibilityLabel("Review Lattice change")
    }
}

struct EmptyConversationView: View {
    @ObservedObject var state: AppState
    var body: some View {
        ZStack(alignment: .topLeading) {
            LatticeIdentityAnchor()
                .padding(.leading, 24)
                .padding(.top, 22)

            VStack(spacing: 10) {
                Text(state.copyText(for: .emptyChatTitle, fallback: "What can I help with?"))
                    .font(.title2)
                    .fontWeight(.semibold)
                    .accessibilityAddTraits(.isHeader)
                Text(state.activeBackend.displayName).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ComposerView: View {
    @ObservedObject var state: AppState
    private var composerBinding: Binding<MorphingControlState> {
        Binding(
            get: { state.selectedSession.map { state.visibleComposerState(for: $0.id) } ?? state.composerState },
            set: { state.setVisibleComposerState($0, for: state.selectedSession?.id) }
        )
    }
    private var commandSuggestions: [LatticeAppCommand] {
        state.appCommandSuggestions(for: state.draft)
    }

    var body: some View {
        VStack(spacing: state.composerSpacing()) {
            HStack(spacing: 10) {
                BackendMenu(state: state)
                if state.availableExecutionRoutes.count > 1 {
                    HarnessMenu(state: state)
                }
                if let routeStatus = state.activeRouteStatusText {
                    Label(routeStatus, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .help(routeStatus)
                }
                if !state.activeReasoningOptions.isEmpty { ReasoningMenu(state: state) }
                if state.canContinueSelectedSession {
                    Button {
                        state.continueSelectedResponse()
                    } label: {
                        Label("Continue", systemImage: "arrow.turn.down.right")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Ask the current chat to continue from the last assistant response")
                }
                if state.editingMessageID != nil {
                    HStack(spacing: 6) {
                        Text("Editing")
                        Button(action: state.cancelEditingMessage) { Image(systemName: "xmark") }
                            .buttonStyle(LatticeIconButtonStyle(size: .compact))
                            .accessibilityLabel("Cancel edit")
                            .help("Cancel edit")
                    }
                    .font(.caption)
                    .padding(.leading, 9)
                    .padding(.trailing, 4)
                    .padding(.vertical, 4)
                    .latticeGlass(cornerRadius: 20, interactive: true)
                }
                Spacer()
                Text(state.selectedSession?.workspacePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No workspace")
                    .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
            if !commandSuggestions.isEmpty {
                AppCommandSuggestionList(commands: commandSuggestions) { command in
                    state.insertAppCommand(command)
                }
            }
            MorphingControl(
                state: composerBinding,
                text: $state.draft,
                compactTitle: state.copyText(for: .askButton, fallback: "Ask Lattice"),
                expandedPlaceholder: state.copyText(for: .promptPlaceholder, fallback: "What do you need?"),
                onSubmit: state.sendDraft,
                onStop: state.stop,
                onChooseFiles: state.chooseAttachments,
                onDropFiles: state.addAttachments,
                onDismissContext: {
                    // MorphingControl owns phase animation and honors Reduce Motion.
                    state.setVisibleComposerState(.expanded, for: state.selectedSession?.id)
                },
                isSubmitEnabled: state.canSendDraft,
                isStopEnabled: state.canStopSelectedSession,
                submitDisabledHelp: state.composerSubmitDisabledHelp,
                stopDisabledHelp: "No response is running",
                surfaceTint: state.tintColor(for: .composer),
                surfaceCornerRadius: state.cornerRadius(for: .composer, default: 16)
            )
        }
        .frame(maxWidth: state.composerMaxWidth())
        .padding(.horizontal, state.composerHorizontalPadding())
        .padding(.vertical, state.composerVerticalPadding())
        .frame(maxWidth: .infinity)
    }
}

struct AppCommandSuggestionList: View {
    let commands: [LatticeAppCommand]
    let choose: (LatticeAppCommand) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(commands) { command in
                Button { choose(command) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "slash.circle")
                            .foregroundStyle(.pink)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(command.invocation)
                                .font(.system(.caption, design: .monospaced, weight: .semibold))
                            Text(command.title)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Text(command.detail)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(command.invocation), \(command.title)")
            }
        }
        .latticeGlass(cornerRadius: 12, tint: .pink.opacity(0.12))
    }
}

struct AttachmentStrip: View {
    @ObservedObject var state: AppState

    var body: some View {
        if !state.attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(state.attachments) { attachment in
                        HStack(spacing: 6) {
                            Image(systemName: attachment.isImage ? "photo" : "doc")
                            Text(attachment.isMissing ? "Missing: \(attachment.name)" : attachment.name)
                                .lineLimit(1)
                                .foregroundStyle(attachment.isMissing ? .secondary : .primary)
                            Button { state.removeAttachment(attachment.id) } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(LatticeIconButtonStyle(size: .compact))
                            .accessibilityLabel("Remove \(attachment.name)")
                            .help("Remove \(attachment.name)")
                        }
                        .font(.caption)
                        .padding(.leading, 8)
                        .padding(.trailing, 2)
                        .padding(.vertical, 2)
                        .latticeGlass(cornerRadius: 14, interactive: true)
                    }
                }
            }
        }
    }
}

struct BackendMenu: View {
    @ObservedObject var state: AppState
    var body: some View {
        Group {
            if state.isSelectedSessionRouteLocked {
                Label(state.activeBackend.displayName, systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
                    .help("Start a new chat to switch model or provider")
            } else {
                Menu {
                    if !state.visibleCodexModels.isEmpty {
                        Section("Codex") {
                            ForEach(state.visibleCodexModels) { model in
                                let backend = ChatBackend.codex(model: model.id)
                                Button(model.name) { state.setBackend(backend) }
                                    .disabled(!state.canUseBackendInNewChat(backend))
                            }
                        }
                    }
                    if !state.visibleGrokModels.isEmpty {
                        Section("Grok") {
                            ForEach(state.visibleGrokModels) { model in
                                let backend = ChatBackend.grok(model: model.id)
                                Button(model.name) { state.setBackend(backend) }
                                    .disabled(!state.canUseBackendInNewChat(backend))
                            }
                        }
                    }
                    if !state.visibleOpenCodeModels.isEmpty {
                        Section("OpenCode") {
                            ForEach(state.visibleOpenCodeModels) { model in
                                let backend = ChatBackend.openCode(model: model.id)
                                Button(model.name) { state.setBackend(backend) }
                                    .disabled(!state.canUseBackendInNewChat(backend))
                            }
                        }
                    }
                    if !state.visibleAntigravityModels.isEmpty {
                        Section("Antigravity") {
                            ForEach(state.visibleAntigravityModels) { model in
                                let backend = ChatBackend.antigravity(model: model.id)
                                Button(model.name) { state.setBackend(backend) }
                                    .disabled(!state.canUseBackendInNewChat(backend))
                            }
                        }
                    }
                    if state.appleIntelligenceReady {
                        Section("On this Mac") {
                            let backend = ChatBackend.appleIntelligence
                            Button("Apple Intelligence") { state.setBackend(backend) }
                                .disabled(!state.canUseBackendInNewChat(backend))
                        }
                    }
                    if !state.ollamaModels.isEmpty {
                        Section("Local models") {
                            ForEach(state.ollamaModels) { model in
                                let backend = ChatBackend.ollama(model: model.name)
                                Button(model.name) { state.setBackend(backend) }
                                    .disabled(!state.canUseBackendInNewChat(backend))
                            }
                        }
                    }
                } label: {
                    Text(state.activeBackend.displayName)
                }
                .menuStyle(.borderlessButton)
            }
        }
        .fixedSize()
    }
}

struct ReasoningMenu: View {
    @ObservedObject var state: AppState
    var body: some View {
        Menu {
            ForEach(state.activeReasoningOptions) { option in
                Button {
                    state.setReasoningEffort(option.effort)
                } label: {
                    if state.activeReasoningEffort == option.effort { Label(option.effort.displayName, systemImage: "checkmark") }
                    else { Text(option.effort.displayName) }
                }
            }
        } label: {
            Label(state.activeReasoningEffort?.displayName ?? "Reasoning", systemImage: "brain")
        }
        .menuStyle(.borderlessButton).fixedSize().help("Reasoning effort")
    }
}

struct HarnessMenu: View {
    @ObservedObject var state: AppState

    var body: some View {
        Group {
            if state.isSelectedSessionRouteLocked {
                Label(state.activeHarnessID.capitalized, systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
                    .help("Start a new chat to switch execution harness")
            } else {
                Menu {
                    ForEach(state.availableExecutionRoutes) { route in
                        Button {
                            state.setExecutionRoute(engineID: route.engineID, harnessID: route.harnessID)
                        } label: {
                            if state.activeHarnessID == route.harnessID {
                                Label(route.title, systemImage: "checkmark")
                            } else {
                                Text(route.title)
                            }
                        }
                    }
                } label: {
                    Label(state.activeHarnessID.capitalized, systemImage: "arrow.triangle.branch")
                }
                .menuStyle(.borderlessButton)
                .help("Choose the execution harness for this model")
                .accessibilityLabel("Execution harness")
                .accessibilityValue(state.activeHarnessID)
            }
        }
        .fixedSize()
    }
}

struct MessageRow: View {
    let message: ChatMessage
    let availableWidth: CGFloat
    @ObservedObject var state: AppState

    private var bubbleMaxWidth: CGFloat {
        CGFloat(LatticeMessageRowLayoutPolicy.bubbleMaxWidth)
    }

    /// Session route for provenance — read live from session state, never duplicated onto the message.
    private var routeSession: LatticeSession? {
        state.selectedSession
    }

    var body: some View {
        let compactActions = LatticeMessageRowLayoutPolicy.usesCompactActions(
            availableWidth: Double(availableWidth),
            isUser: message.role == .user
        )

        Group {
            if message.role == .user {
                userLayout(compactActions: compactActions)
            } else {
                assistantLayout(compactActions: compactActions)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            MessageTimestampPresentationPolicy.accessibilityMetadata(
                role: message.role,
                date: message.date,
                isGenerating: message.role == .assistant && message.text.isEmpty
            )
        )
    }

    @ViewBuilder
    private func userLayout(compactActions: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Soft leading inset only — never a hard minWidth that can squeeze the bubble.
            Spacer(minLength: compactActions ? 16 : 48)
            MessageActionControls(
                message: message,
                state: state,
                includesEdit: true,
                usesCompactControls: compactActions
            )
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .trailing, spacing: 4) {
                VStack(alignment: .leading, spacing: 6) {
                    if message.isPinned { PinnedMessageBadge() }
                    // Leading alignment inside multi-line user bubbles (bubble itself stays trailing).
                    MessageContentView(text: message.text, isUser: true)
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
                .latticeGlass(cornerRadius: 18, interactive: false, tint: message.isPinned ? .pink.opacity(0.08) : nil)
                // Max only — no minWidth floor. Text wraps within the measured row width.
                .frame(maxWidth: bubbleMaxWidth, alignment: .leading)
                .layoutPriority(1)

                MessageTimestampCaption(date: message.date)
                    .padding(.trailing, 4)
            }
        }
    }

    @ViewBuilder
    private func assistantLayout(compactActions: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if message.text.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.vertical, 5)
                        .accessibilityHidden(true)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        if message.isPinned { PinnedMessageBadge() }
                        if message.role == .assistant, let session = routeSession {
                            AssistantRouteProvenanceCaption(
                                backend: session.backend,
                                sessionHarnessID: session.harnessID
                            )
                        }
                        MessageContentView(text: message.text, isUser: false)
                            .foregroundStyle(message.role == .system ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        MessageTimestampCaption(date: message.date)
                    }
                }
            }
            // Flexible fill — no minWidth floor that can force one-character wrapping.
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            if !message.text.isEmpty {
                MessageActionControls(
                    message: message,
                    state: state,
                    includesEdit: false,
                    usesCompactControls: compactActions
                )
                .fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}

/// Shared message actions for user and assistant rows.
/// At comfortable widths, renders discrete icon buttons; at compact widths, collapses into one accessible overflow menu.
private struct MessageActionControls: View {
    let message: ChatMessage
    @ObservedObject var state: AppState
    var includesEdit: Bool
    var usesCompactControls: Bool

    private var copyLabel: String {
        state.copiedMessageID == message.id ? "Copied" : "Copy"
    }

    private var copySymbol: String {
        state.copiedMessageID == message.id ? "checkmark" : "doc.on.doc"
    }

    private var pinLabel: String {
        message.isPinned ? "Unpin message" : "Pin message"
    }

    private var pinSymbol: String {
        message.isPinned ? "pin.slash" : "pin"
    }

    private var canBranch: Bool {
        state.canBranchFromMessage(message)
    }

    private var compactAccessibilityHint: String {
        var actions = ["copy", "pin"]
        if canBranch { actions.append("branch") }
        if includesEdit { actions.append("edit") }
        actions.append("delete")
        return "Contains message actions: \(actions.joined(separator: ", "))"
    }

    var body: some View {
        if usesCompactControls {
            Menu {
                Button {
                    state.copyMessage(message)
                } label: {
                    Label(copyLabel, systemImage: copySymbol)
                }
                .help(copyLabel)
                .accessibilityLabel(copyLabel)

                Button {
                    state.togglePinnedMessage(message)
                } label: {
                    Label(pinLabel, systemImage: pinSymbol)
                }
                .help(pinLabel)
                .accessibilityLabel(pinLabel)

                if canBranch {
                    Button {
                        state.branchFromMessage(message)
                    } label: {
                        Label("Branch from here", systemImage: "arrow.triangle.branch")
                    }
                    .help("Branch from here")
                    .accessibilityLabel("Branch from here")
                }

                if includesEdit {
                    Button {
                        state.beginEditingMessage(message)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .help("Edit")
                    .accessibilityLabel("Edit")
                }

                Button(role: .destructive) {
                    state.requestDeleteMessage(message)
                } label: {
                    Label("Delete from here", systemImage: "trash")
                }
                .help("Delete from here")
                .accessibilityLabel("Delete from here")
                .accessibilityHint("Removes this message and everything after it")
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(LatticeIconButtonStyle(size: .compact))
            .fixedSize()
            .accessibilityLabel("Message actions")
            .accessibilityHint(compactAccessibilityHint)
            .help("Message actions")
        } else {
            // Spacing keeps ≥40×40 interaction frames from overlapping (visual chrome stays compact).
            HStack(alignment: .center, spacing: 0) {
                MessageActionButton(systemImage: copySymbol, label: copyLabel) {
                    state.copyMessage(message)
                }
                MessageActionButton(systemImage: pinSymbol, label: pinLabel) {
                    state.togglePinnedMessage(message)
                }
                if canBranch {
                    MessageActionButton(systemImage: "arrow.triangle.branch", label: "Branch from here") {
                        state.branchFromMessage(message)
                    }
                }
                if includesEdit {
                    MessageActionButton(systemImage: "pencil", label: "Edit") {
                        state.beginEditingMessage(message)
                    }
                }
                MessageActionButton(systemImage: "trash", label: "Delete from here", isDestructive: true) {
                    state.requestDeleteMessage(message)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }
}

private struct PinnedMessageBadge: View {
    var body: some View {
        Label("Pinned", systemImage: "pin.fill")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.pink)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.pink.opacity(0.12), in: Capsule())
            .accessibilityLabel("Pinned message")
    }
}

private struct MessageActionButton: View {
    let systemImage: String
    let label: String
    var isDestructive = false
    let action: () -> Void

    var body: some View {
        Button(role: isDestructive ? .destructive : nil, action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(LatticeIconButtonStyle(size: .compact, isDestructive: isDestructive))
        .accessibilityLabel(label)
        .help(label)
    }
}

struct AssistantActivityDisclosure: View {
    let actions: [SessionAction]

    private var summaryTitle: String {
        if actions.count == 1 { return actions[0].title }
        return "\(actions.count) model activities"
    }

    private var summaryStatus: (label: String, color: Color) {
        if actions.contains(where: { $0.status == .waiting }) { return ("Waiting", .orange) }
        if actions.contains(where: { $0.status == .running }) { return ("Working", .blue) }
        if actions.contains(where: { $0.status == .failed || $0.status == .denied }) { return ("Needs attention", .red) }
        if actions.contains(where: { $0.status == .cancelled || $0.status == .interrupted }) { return ("Incomplete", .secondary) }
        return ("Done", .green)
    }

    private var summaryIcon: String {
        if actions.contains(where: { $0.kind == .diagnostic }) { return "exclamationmark.triangle" }
        if actions.contains(where: { $0.kind == .reasoning }) { return "brain" }
        if actions.contains(where: { $0.kind == .plan }) { return "list.bullet.clipboard" }
        return "checklist"
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(actions) { action in
                    SessionActionDetailRow(action: action)
                    if action.id != actions.last?.id { Divider() }
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: summaryIcon)
                    .foregroundStyle(summaryStatus.color)
                    .frame(width: 18)
                Text(summaryTitle)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(summaryStatus.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(summaryStatus.color)
                    .monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .padding(11)
        .latticeGlass(cornerRadius: 12, interactive: true)
        .accessibilityLabel("Model activity, \(summaryTitle), \(summaryStatus.label)")
        .accessibilityHint("Expand or collapse model activity and reasoning summaries")
        .accessibilityIdentifier(
            actions.contains(where: { $0.kind == .approval })
                ? LatticeAccessibilityID.activityApproval
                : LatticeAccessibilityID.activityTool
        )
    }
}

private struct SessionActionDetailRow: View {
    let action: SessionAction

    private var icon: String {
        switch action.kind {
        case .approval: return action.status == .waiting ? "hand.raised.fill" : "checkmark.shield"
        case .plan: return "list.bullet.clipboard"
        case .reasoning: return "brain"
        case .diagnostic: return "exclamationmark.triangle"
        case .tool: break
        }
        switch action.toolKind {
        case .write: return "pencil"
        case .command: return "terminal"
        case .network: return "bolt.horizontal"
        case .automation: return "cursorarrow.motionlines"
        case .credential: return "key"
        case .destructive: return "exclamationmark.triangle"
        case .unknown: return "questionmark.circle"
        case .read, .none: return "doc.text.magnifyingglass"
        }
    }

    private var statusLabel: String {
        switch action.status {
        case .running: "Running"
        case .waiting: "Waiting"
        case .completed: "Completed"
        case .failed: "Failed"
        case .allowed: "Allowed"
        case .denied: "Denied"
        case .cancelled: "Cancelled"
        case .interrupted: "Incomplete"
        }
    }

    private var statusColor: Color {
        switch action.status {
        case .completed, .allowed: .green
        case .failed, .denied: .red
        case .cancelled, .interrupted: .secondary
        case .running: .blue
        case .waiting: .orange
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(statusColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(action.title).fontWeight(.medium)
                    Text(statusLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(statusColor.opacity(0.12), in: Capsule())
                }
                if !action.detail.isEmpty {
                    Text(action.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if action.workspaceScoped {
                    Label("Workspace scoped", systemImage: "folder.badge.checkmark")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(
            action.kind == .approval
                ? LatticeAccessibilityID.activityApproval
                : LatticeAccessibilityID.activityTool
        )
        .accessibilityLabel("\(action.title), \(statusLabel)")
        .accessibilityValue(action.detail)
    }
}

struct HarnessPermissionNoticeRow: View {
    let notice: HarnessPermissionNotice
    @ObservedObject var state: AppState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 5) {
                Text(notice.request.title).fontWeight(.semibold)
                Text(notice.request.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text("\(notice.providerName) is paused until you choose.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            let options = state.availableHarnessPermissionOptions(for: notice)
            let rejects = options.filter(\.isReject)
            let allows = options.filter(\.isAllow)
            if let reject = rejects.first {
                Button(reject.name) { state.respondToHarnessPermission(notice, option: reject) }
            } else {
                Button("Stop", action: state.stop)
            }
            if allows.count == 1, let allow = allows.first {
                Button(allow.name) { state.respondToHarnessPermission(notice, option: allow) }
                    .buttonStyle(.borderedProminent)
            } else if !allows.isEmpty {
                Menu("Allow") {
                    ForEach(allows) { option in
                        Button(option.name) { state.respondToHarnessPermission(notice, option: option) }
                    }
                }
                .menuStyle(.button)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .latticeGlass(cornerRadius: 14, interactive: true)
        .accessibilityIdentifier(LatticeAccessibilityID.permissionNotice)
        .accessibilityLabel("\(notice.request.title), pending approval")
        .accessibilityValue(notice.request.detail)
    }
}

struct ErrorRow: View {
    let message: String
    let canRetry: Bool
    let onRetry: () -> Void

    private var presentation: ConversationErrorPresentation {
        ConversationErrorPresentationPolicy.presentation(for: message)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.headline)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = presentation.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if canRetry {
                Button("Retry", action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityLabel("Retry request")
            }
        }
        .padding(12)
        .latticeGlass(cornerRadius: 12, tint: .red.opacity(0.08))
        .accessibilityElement(children: .contain)
    }
}
