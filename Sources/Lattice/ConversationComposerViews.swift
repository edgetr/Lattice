import SwiftUI
import AppKit
import LatticeCore
import UniformTypeIdentifiers

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
            if let session = state.selectedSession,
               session.executionRoute.mode == .code,
               session.executionRoute.runtimeID == "pi",
               session.codePhase.restrictsMutatingTools {
                let canMutatePlan = !session.isStreaming
                    && session.isTranscriptLoaded
                    && session.isArtifactsLoaded
                let unavailablePlanControlHelp = session.isStreaming
                    ? "Stop the current response before changing the plan phase"
                    : "Wait for this chat's conversation and plan details to finish loading"
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet.clipboard")
                    Text(session.codePhase == .planAwaitingApproval
                         ? "Plan awaiting approval — write tools withheld on next send"
                         : "Planning — write tools withheld on next send")
                        .font(.caption.weight(.medium))
                    Spacer(minLength: 4)
                    if session.codePhase == .planAwaitingApproval {
                        Button("Approve") { state.approveCodePlan() }
                            .disabled(!canMutatePlan)
                            .help(canMutatePlan ? "Approve the proposed code plan" : unavailablePlanControlHelp)
                            .accessibilityHint(canMutatePlan ? "Approves the proposed code plan." : unavailablePlanControlHelp)
                        Button("Exit") { state.exitCodePlanPhase() }
                            .disabled(!canMutatePlan)
                            .help(canMutatePlan ? "Exit the code plan phase" : unavailablePlanControlHelp)
                            .accessibilityHint(canMutatePlan ? "Exits the code plan phase." : unavailablePlanControlHelp)
                    } else {
                        Button("Exit plan") { state.exitCodePlanPhase() }
                            .disabled(!canMutatePlan)
                            .help(canMutatePlan ? "Exit the code plan phase" : unavailablePlanControlHelp)
                            .accessibilityHint(canMutatePlan ? "Exits the code plan phase." : unavailablePlanControlHelp)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Code plan phase")
                .accessibilityValue(session.codePhase.displayName)
            }
            composerHeader
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
                onDropImageData: state.addDroppedImageData,
                onPasteImage: state.pasteImageFromClipboard,
                onCaptureRegion: state.captureScreenRegion,
                onCaptureWindow: state.captureAppWindow,
                includeScreenshotContext: $state.includeScreenshotContext,
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

    @ViewBuilder
    private var composerHeader: some View {
        ViewThatFits(in: .horizontal) {
            fullComposerHeader
            compactComposerHeader
            stackedComposerHeader
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.bottom, 2)
    }

    private var fullComposerHeader: some View {
        HStack(spacing: 10) {
            ComposerRouteMenu(state: state)
            routeStatusLabel
            reasoningMenu
            continueButton
            editingBadge
            Spacer(minLength: 8)
            workspaceLabel
        }
    }

    private var compactComposerHeader: some View {
        HStack(spacing: 8) {
            ComposerRouteMenu(state: state)
            if !state.activeReasoningOptions.isEmpty { ReasoningMenu(state: state) }
            if state.canContinueSelectedSession { continueButton }
            if state.editingMessageID != nil { editingBadge }
            Spacer(minLength: 4)
            if let routeStatus = state.activeRouteStatusText {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel(routeStatus)
                    .help(routeStatus)
            }
            workspaceLabel
        }
    }

    private var stackedComposerHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ComposerRouteMenu(state: state)
                Spacer(minLength: 4)
                workspaceLabel
            }
            HStack(spacing: 8) {
                routeStatusLabel
                reasoningMenu
                continueButton
                editingBadge
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var routeStatusLabel: some View {
        if let routeStatus = state.activeRouteStatusText {
            Label(routeStatus, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 220, alignment: .leading)
                .help(routeStatus)
        }
    }

    @ViewBuilder
    private var reasoningMenu: some View {
        if !state.activeReasoningOptions.isEmpty { ReasoningMenu(state: state) }
    }

    @ViewBuilder
    private var continueButton: some View {
        if state.canContinueSelectedSession {
            Button {
                state.continueSelectedResponse()
            } label: {
                Label("Continue", systemImage: "arrow.turn.down.right")
            }
            .buttonStyle(LatticeSecondaryButtonStyle())
            .help("Ask the current chat to continue from the last assistant response")
        }
    }

    @ViewBuilder
    private var editingBadge: some View {
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
    }

    private var workspaceLabel: some View {
        Text(state.selectedSession?.workspacePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No workspace")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 160, alignment: .trailing)
            .help(state.selectedSession?.workspacePath ?? "No workspace")
    }
}

struct AppCommandSuggestionList: View {
    let commands: [LatticeAppCommand]
    let choose: (LatticeAppCommand) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
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
        }
        .scrollIndicators(commands.count > CommandSuggestionLayoutPolicy.maximumVisibleRows ? .visible : .hidden)
        .frame(height: CGFloat(CommandSuggestionLayoutPolicy.height(resultCount: commands.count)))
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
                            if attachment.isImage,
                               !attachment.isMissing,
                               let image = NSImage(contentsOfFile: attachment.path) {
                                Image(nsImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 30, height: 24)
                                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                                    .accessibilityHidden(true)
                            } else {
                                Image(systemName: attachment.isImage ? "photo" : "doc")
                            }
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

struct ComputerFrameCard: View {
    let presentation: ComputerFrameViewerPresentation

    var body: some View {
        if presentation.visibility == .visible {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Provider computer view", systemImage: "display")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    if presentation.isCancelled { Text("Cancelled") }
                    else if presentation.isStopped { Text("Stopped") }
                    else { Text("Live activity") }
                }
                .foregroundStyle(.secondary)
                switch presentation.content {
                case .latestFrameOnly(let frame):
                    if let data = frame.imageData, let image = NSImage(data: data) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 260)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .accessibilityLabel("Latest provider computer frame")
                    } else {
                        unavailable("The latest provider frame file is unavailable.")
                    }
                case .imageUnavailable(let reason): unavailable(reason)
                case .none: EmptyView()
                }
                Text(presentation.controlBoundaryStatement)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .latticeGlass(cornerRadius: 12)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Observable provider computer activity")
        }
    }

    private func unavailable(_ reason: String) -> some View {
        Label(reason, systemImage: "photo.badge.exclamationmark")
            .font(.caption)
            .foregroundStyle(.orange)
    }
}

struct ComposerRouteMenu: View {
    @ObservedObject var state: AppState

    private var selectedMode: ConversationMode? { state.activeConversationMode }
    private var selectedBackend: ChatBackend? { state.activeComposerBackend }

    var body: some View {
        Button {
            state.composerRoutePopoverPresented = true
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(selectedMode?.displayName ?? "Choose mode")
                        .font(.callout.weight(.medium))
                    Text(selectedBackend?.displayName ?? "Choose model")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } icon: {
                Image(systemName: modeIcon(selectedMode))
            }
        }
        .buttonStyle(.plain)
        .disabled(state.isComposerRouteLocked)
        .opacity(state.isComposerRouteLocked ? 0.62 : 1)
        .help(state.isComposerRouteLocked ? "Mode and model locked after first message" : "Choose mode and model")
        .accessibilityLabel("Mode and model")
        .accessibilityValue("\(selectedMode?.displayName ?? "Not selected"), \(selectedBackend?.displayName ?? "No model")")
        .popover(isPresented: $state.composerRoutePopoverPresented, arrowEdge: .bottom) {
            ComposerRoutePopover(state: state, dismiss: { state.composerRoutePopoverPresented = false })
        }
    }

    private func modeIcon(_ mode: ConversationMode?) -> String {
        switch mode {
        case .code: "hammer"
        case .work: "briefcase"
        case .local: "lock.shield"
        case nil: "slider.horizontal.3"
        }
    }
}

struct ComposerRoutePopover: View {
    @ObservedObject var state: AppState
    let dismiss: () -> Void

    private var selectedMode: ConversationMode? { state.activeConversationMode }
    private var filteredOptions: [ComposerModelOption] {
        guard let selectedMode else { return [] }
        let query = state.composerModelSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return state.composerModelOptions(for: selectedMode).filter { option in
            query.isEmpty || option.title.localizedCaseInsensitiveContains(query) || option.providerTitle.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose mode")
                .font(.headline)
            VStack(spacing: 4) {
                ForEach(ConversationMode.allCases) { mode in
                    Button {
                        state.selectComposerMode(mode)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: modeIcon(mode))
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode.displayName)
                                    .font(.body.weight(.medium))
                                Text(modeDetail(mode))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selectedMode == mode {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .disabled(state.isComposerRouteLocked)
                    .accessibilityLabel("\(mode.displayName), \(modeDetail(mode))")
                    .accessibilityValue(selectedMode == mode ? "Selected" : "")
                }
            }

            if let selectedMode {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search models", text: $state.composerModelSearchText)
                        .textFieldStyle(.plain)
                    if !state.composerModelSearchText.isEmpty {
                        Button { state.composerModelSearchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear model search")
                    }
                }
                .padding(9)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.secondary.opacity(0.22)))
                .accessibilityIdentifier("lattice.composer.model.search")

                Text("Models")
                    .font(.headline)
                if state.isRefreshingConnections {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Refreshing discovered models…")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Refreshing discovered models")
                }
                if filteredOptions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        if !state.isRefreshingConnections {
                            Text(state.composerModelSearchText.isEmpty ? "No models were discovered for this mode." : "No models match search.")
                            if state.composerModelSearchText.isEmpty {
                                Button("Open Connections") {
                                    state.composerRoutePopoverPresented = false
                                    state.openConnectionsFromComposer()
                                }
                                .buttonStyle(.link)
                            }
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                        ForEach(groupedOptions, id: \.provider) { group in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(group.provider)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                                ForEach(group.options) { option in
                                    ModelChooserRow(state: state, option: option, selectedMode: selectedMode, dismiss: dismiss)
                                }
                            }
                        }
                        }
                    }
                    .frame(maxHeight: 300)
                }
            } else {
                Text("Select mode to see its discovered models.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            }
        }
        .padding(16)
        .frame(width: 370)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mode and model chooser")
    }

    private var groupedOptions: [(provider: String, options: [ComposerModelOption])] {
        let grouped = Dictionary(grouping: filteredOptions, by: \.providerTitle)
        return grouped.keys.sorted().map { ($0, grouped[$0] ?? []) }
    }

    private func modeIcon(_ mode: ConversationMode) -> String {
        switch mode {
        case .code: "hammer"
        case .work: "briefcase"
        case .local: "lock.shield"
        }
    }

    private func modeDetail(_ mode: ConversationMode) -> String {
        switch mode {
        case .code: "Build, debug, and ship"
        case .work: "Research, browse, and act"
        case .local: "Private models on this Mac"
        }
    }
}

struct ModelChooserRow: View {
    @ObservedObject var state: AppState
    let option: ComposerModelOption
    let selectedMode: ConversationMode
    let dismiss: () -> Void

    private var isSelected: Bool {
        state.activeConversationMode == selectedMode && state.activeComposerBackend == option.backend
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                state.selectComposerModel(option)
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: providerIcon)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.title)
                            .font(.body)
                            .lineLimit(1)
                        if let reason = option.reason {
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        } else if let reasoning = option.reasoningSummary {
                            Text(reasoning)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
                .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .disabled(!option.isAvailable || state.isComposerRouteLocked)
            .opacity(option.isAvailable ? 1 : 0.62)
            .accessibilityLabel("\(option.providerTitle), \(option.title)")
            .accessibilityValue(option.reason ?? (isSelected ? "Selected" : "Available"))
            if option.reason != nil {
                Button("Open Connections") {
                    state.composerRoutePopoverPresented = false
                    state.openConnectionsFromComposer()
                }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(state.isComposerRouteLocked)
                .help("Open Connections to make this route available")
            }
        }
    }

    private var providerIcon: String {
        switch option.route.providerID {
        case "apple", "ollama": "cpu"
        case "codex": "sparkles"
        case "grok": "cloud"
        case "opencode": "chevron.left.forwardslash.chevron.right"
        case "antigravity": "airplane"
        default: "circle"
        }
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
