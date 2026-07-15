import SwiftUI
import AppKit
import LatticeCore

struct WorkspaceView: View {
    @ObservedObject var state: AppState
    @ObservedObject var layout: WorkspaceWindowLayout

    var body: some View {
        AnyView(
            workspaceLayout
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: WorkspaceWidthPreferenceKey.self, value: proxy.size.width)
                }
            }
            .onPreferenceChange(WorkspaceWidthPreferenceKey.self) { width in
                layout.noteWorkspaceWidth(width)
            }
            .onChange(of: layout.columnVisibility) { _, newValue in
                layout.noteColumnVisibilityChanged(newValue)
            }
        )
        .onChange(of: layout.selectedSection) { _, section in
            noteSelectedSectionChanged(section)
        }
        .accessibilityIdentifier(LatticeAccessibilityID.workspaceRoot)
        .toolbar {
            ToolbarItemGroup {
                if layout.selectedSection == .conversations {
                    Button { state.newSession() } label: { Label("New chat", systemImage: "square.and.pencil") }
                    Button { state.toggleFileBrowser() } label: {
                        Label("Files", systemImage: state.showFileBrowser ? "folder.fill" : "folder")
                    }
                    .help(state.showFileBrowser ? "Hide workspace files" : "Show workspace files")
                    Button { state.toggleWorkspaceTerminal() } label: {
                        Label(
                            "Terminal",
                            systemImage: terminalToolbarSymbol
                        )
                    }
                    .help(terminalToolbarHelp)
                    Button { layout.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                        .help(layout.showInspector ? "Hide chat inspector" : "Show chat inspector")
                    workspaceActionsMenu
                } else {
                    workspaceActionsMenu
                }
            }
        }
        .sheet(isPresented: $state.showCommandPalette) {
            CommandPaletteView(state: state)
        }
        .sheet(item: $state.pendingRuntimeConfirmation, onDismiss: {
            if state.pendingRuntimeConfirmation != nil { state.cancelRuntimeAction() }
        }) { request in
            RuntimeConfirmationSheet(state: state, request: request)
        }
        .alert("Delete chat?", isPresented: $state.showDeleteChatConfirmation) {
            Button("Cancel", role: .cancel) { state.cancelPendingChatDeletion() }
            Button("Delete", role: .destructive) { state.confirmPendingChatDeletion() }
        } message: {
            Text("This removes the conversation from this Mac.")
        }
        .alert("Delete from here?", isPresented: $state.showDeleteMessageConfirmation) {
            Button("Cancel", role: .cancel) { state.cancelPendingMessageDeletion() }
            Button("Delete", role: .destructive) { state.confirmPendingMessageDeletion() }
        } message: {
            Text("This removes this message and everything after it. This cannot be undone.")
        }
        .alert("Delete extension?", isPresented: $state.showDeleteExtensionConfirmation) {
            Button("Cancel", role: .cancel) { state.cancelPendingExtensionDeletion() }
            Button("Delete", role: .destructive) { state.confirmPendingExtensionDeletion() }
        } message: {
            let name = state.pendingDeleteExtensionRecord?.name ?? "this extension"
            Text("This removes \(name) from Lattice’s managed Extensions folder and removes any skills owned by that extension.")
        }
        .alert("Delete skill?", isPresented: $state.showDeleteSkillConfirmation) {
            Button("Cancel", role: .cancel) { state.cancelPendingSkillDeletion() }
            Button("Delete", role: .destructive) { state.confirmPendingSkillDeletion() }
        } message: {
            if state.pendingDeleteSkillRecord?.source == .importedGlobal {
                Text("This removes Lattice’s managed copy of this imported global skill. The original global skill file is left alone, and Lattice will remember not to import it again automatically.")
            } else {
                Text("This removes this generated skill from Lattice’s managed Skills folder. Extensions that own their own skills can recreate them when applied again.")
            }
        }
        .alert("Delete local model?", isPresented: $state.showDeleteLocalModelConfirmation) {
            Button("Cancel", role: .cancel) { state.cancelPendingLocalModelDeletion() }
            Button("Delete", role: .destructive) { state.confirmPendingLocalModelDeletion() }
        } message: {
            Text("This removes \(state.pendingDeleteLocalModelName ?? "the model") from Ollama on this Mac. Existing chat history remains, but that route will be unavailable until reinstalled.")
        }
        .alert(
            "Download \(state.pendingCLIInstallProvider.map(Self.cliDisplayName) ?? "CLI")?",
            isPresented: Binding(
                get: { state.pendingCLIInstallProvider != nil },
                set: { if !$0 { state.cancelCLIInstall() } }
            )
        ) {
            Button("Cancel", role: .cancel) { state.cancelCLIInstall() }
            Button("Download and Install") { state.confirmCLIInstall() }
        } message: {
            Text("Lattice will use the provider-owned installer or package source shown by that provider. Availability is checked after installation; provenance and hash verification depend on the source.")
        }
        .alert(
            "Provider tools bypass Lattice's broker",
            isPresented: Binding(
                get: { state.pendingUnsafeProviderRouteAcknowledgement != nil },
                set: { if !$0 { state.dismissUnsafeProviderRouteAcknowledgement() } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                state.dismissUnsafeProviderRouteAcknowledgement()
            }
            Button("Acknowledge") {
                state.acknowledgeUnsafeProviderRoute()
            }
        } message: {
            if let pending = state.pendingUnsafeProviderRouteAcknowledgement {
                Text("\(pending.providerName) · \(pending.modelName)\n\n\(pending.detail)\n\nAcknowledge, then send again. Consent lasts until Lattice exits.")
            } else {
                Text("Provider-owned tool calls are not brokered by Lattice.")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            LatticeGlassGroup(spacing: 10) {
                VStack(spacing: 8) {
                    // Non-blocking save-failure status; load-recovery modal remains the exclusive recovery surface when present.
                    if state.needsSessionSaveFailureAttention, !state.needsPersistenceRecovery {
                        SessionSaveFailureView(state: state)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if let status = state.exportChatStatusMessage {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(status)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                            Button("Dismiss") {
                                state.exportChatStatusMessage = nil
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Dismiss export or import status")
                        }
                        .padding(12)
                        .latticeGlass(cornerRadius: 14, tint: Color.green.opacity(0.08))
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Export or import status")
                        .accessibilityValue(status)
                        .accessibilityIdentifier("export-import-status")
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 4)
        }
        .overlay {
            if state.needsPersistenceRecovery {
                PersistenceRecoveryView(state: state)
            }
        }
        .alert("Reset this store?", isPresented: $state.showPersistenceResetConfirmation) {
            Button("Cancel", role: .cancel) {
                state.cancelPersistenceStoreReset()
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Cancel reset")
            .accessibilityHint("Leaves the original file unchanged")
            Button("Reset Store", role: .destructive) {
                state.confirmPersistenceStoreReset()
            }
            .accessibilityLabel("Confirm reset store")
            .accessibilityHint("Backs up the original, then creates a new empty store")
        } message: {
            if let issue = state.pendingPersistenceResetIssue {
                Text("The original “\(issue.storeName)” file will be preserved as a collision-safe backup next to \(issue.fileURL.lastPathComponent). Lattice will then create a new empty store in its place. The original bytes are never deleted before that backup succeeds. This cannot be undone from inside Lattice.")
            } else {
                Text("The original file will be backed up and preserved first. Only after that backup succeeds will Lattice create a new empty store.")
            }
        }
        .sheet(isPresented: $state.showExportChatSheet) {
            ExportChatSheet(state: state)
        }
        .sheet(isPresented: $state.showImportChatPreview) {
            ImportChatPreviewSheet(state: state)
        }
        .alert("Chat export/import", isPresented: $state.showImportChatError) {
            Button("OK", role: .cancel) {
                state.importChatErrorMessage = nil
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel("Dismiss export or import error")
        } message: {
            Text(state.importChatErrorMessage ?? "Something went wrong. Existing chats were not changed.")
        }
    }

    private var workspaceActionsMenu: some View {
        Menu {
            Button { state.openCommandPalette() } label: {
                Label("Commands", systemImage: "command")
            }
            .accessibilityIdentifier(LatticeAccessibilityID.toolbarCommands)
            Button {
                state.overlayMode = .prompt
                state.showOverlayAction?()
            } label: {
                Label("Show Overlay", systemImage: "rectangle.on.rectangle")
            }
            .accessibilityIdentifier(LatticeAccessibilityID.toolbarOverlay)
            .disabled(state.showOverlayAction == nil)
            Divider()
            Menu {
                Picker("Global limit", selection: Binding(
                    get: { state.schedulerGlobalLimit },
                    set: { state.setSchedulerGlobalLimit($0) }
                )) {
                    ForEach(1...8, id: \.self) { value in
                        Text("\(value)").tag(value)
                    }
                }
                Picker("Per-workspace limit", selection: Binding(
                    get: { state.schedulerWorkspaceLimit },
                    set: { state.setSchedulerWorkspaceLimit($0) }
                )) {
                    ForEach(1...8, id: \.self) { value in
                        Text("\(value)").tag(value)
                    }
                }
            } label: {
                Label("Concurrent Tasks", systemImage: "rectangle.3.group")
            }
            .help("Limit simultaneous agent tasks globally and within each workspace")
        } label: {
            Label("More workspace actions", systemImage: "ellipsis.circle")
        }
        .help("Commands, overlay, and task scheduling")
        .accessibilityLabel("More workspace actions")
    }

    private func noteSelectedSectionChanged(_ section: WorkspaceSection) {
        guard section == .conversations else { return }
        layout.applyAdaptiveColumnVisibilityIfNeeded()
    }

    private var terminalToolbarSymbol: String {
        if state.showWorkspaceTerminal, state.workspaceTerminalLayoutSuppressed {
            return "terminal"
        }
        return state.showWorkspaceTerminal ? "terminal.fill" : "terminal"
    }

    private var terminalToolbarHelp: String {
        if state.showWorkspaceTerminal, state.workspaceTerminalLayoutSuppressed {
            return "Terminal hidden — window too short to show dock without crushing chat"
        }
        return state.showWorkspaceTerminal ? "Hide workspace terminal" : "Show workspace terminal"
    }

    @ViewBuilder private var workspaceLayout: some View {
        if layout.selectedSection == .conversations {
            ConversationWorkspaceLayout(state: state, layout: layout)
        } else {
            SectionWorkspaceLayout(state: state, layout: layout, detail: sectionDetail)
        }
    }

    private static func cliDisplayName(_ provider: String) -> String {
        switch provider {
        case "codex": "Codex CLI"
        case "grok": "Grok CLI"
        case "opencode": "OpenCode CLI"
        case "antigravity": "Antigravity CLI"
        case "pi": "Pi CLI"
        case "hermes": "Hermes CLI"
        default: "CLI"
        }
    }

    @ViewBuilder private var sectionDetail: some View {
        switch layout.selectedSection {
        case .conversations: EmptyView()
        case .projects: ProjectsView(state: state)
        case .models: ModelsView(state: state)
        case .connections: ConnectionsView(state: state)
        case .extensions: ExtensionsView(state: state)
        }
    }
}

private struct RuntimeConfirmationSheet: View {
    @ObservedObject var state: AppState
    let request: RuntimeConfirmationRequest

    private var descriptor: RuntimeInstallDescriptor { request.descriptor }
    private var actionTitle: String {
        RuntimeLifecyclePresentationPolicy.actionTitle(
            for: request.action,
            installedVersion: request.runtime == .pi ? state.piCLIVersion : state.hermesCLIInfo.currentVersion,
            targetVersion: descriptor.immutableVersion
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: request.runtime == .pi ? "terminal" : "shippingbox")
                    .font(.title2)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(actionTitle) \(descriptor.displayName)").font(.title3.weight(.semibold))
                    Text("Agent runtime").font(.caption).foregroundStyle(.secondary)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow { Text("Version").foregroundStyle(.secondary); Text(descriptor.immutableVersion).textSelection(.enabled) }
                GridRow { Text("Source").foregroundStyle(.secondary); Text(descriptor.source).textSelection(.enabled) }
                GridRow {
                    Text("Size").foregroundStyle(.secondary)
                    Text(descriptor.estimatedSizeBytes.map {
                        ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
                    } ?? "Not reported upstream")
                }
                GridRow { Text("Verification").foregroundStyle(.secondary); Text(descriptor.verificationLabel) }
                GridRow { Text("Profile").foregroundStyle(.secondary); Text(descriptor.profileDirectory).textSelection(.enabled) }
            }
            .font(.caption)

            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions").font(.caption.weight(.semibold))
                ForEach(descriptor.permissions.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { permission in
                    Label(permissionLabel(permission), systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Text(request.action == .uninstall ? descriptor.uninstall : descriptor.rollback)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Cancel", role: .cancel) { state.cancelRuntimeAction() }
                Spacer()
                Button(actionTitle, role: request.action == .uninstall ? .destructive : nil) {
                    state.confirmRuntimeAction()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .accessibilityElement(children: .contain)
    }

    private func permissionLabel(_ permission: RuntimeInstallPermission) -> String {
        switch permission {
        case .network: "Download from the listed source"
        case .executeRuntime: "Execute the installed runtime"
        case .writeLatticeProfile: "Write Lattice-owned profile files"
        case .writeUserToolDirectory: "Write to the user tool directory"
        case .readKeychainOpenCodeCredential: "Read the OpenCode key only for explicitly enabled routes"
        }
    }
}

private struct ConversationWorkspaceLayout: View {
    @ObservedObject var state: AppState
    @ObservedObject var layout: WorkspaceWindowLayout

    var body: some View {
        NavigationSplitView(columnVisibility: $layout.columnVisibility) {
            SidebarView(layout: layout)
                .navigationSplitViewColumnWidth(
                    min: layout.sidebarExpanded ? 170 : 56,
                    ideal: layout.sidebarExpanded ? min(max(layout.sidebarWidth, 170), 220) : 56,
                    max: layout.sidebarExpanded ? 220 : 56
                )
                .reportWorkspaceWidth(layout.measureSidebar)
        } content: {
            SessionListView(state: state)
                .navigationSplitViewColumnWidth(min: 220, ideal: min(max(layout.primarySplitWidth, 220), 340), max: 340)
                .reportWorkspaceWidth(layout.measurePrimarySplit)
        } detail: {
            if state.isOverlayVisible {
                Color.clear
            } else {
                ConversationDetailShell(state: state)
                    .inspector(isPresented: $layout.showInspector) {
                        InspectorView(state: state)
                            .inspectorColumnWidth(min: 300, ideal: min(max(layout.inspectorWidth, 300), 420), max: 420)
                            .reportWorkspaceWidth(layout.measureInspector)
                    }
            }
        }
        // Prefer a usable transcript over keeping every column open at narrow widths.
        .navigationSplitViewStyle(.prominentDetail)
    }
}

/// Transcript-first detail with optional file browser and workspace terminal docks.
private struct ConversationDetailShell: View {
    @ObservedObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let minimumTranscriptHeight: CGFloat = 220

    var body: some View {
        GeometryReader { geometry in
            let terminalHeight: CGFloat = state.showWorkspaceTerminal
                ? min(320, max(140, geometry.size.height * 0.28))
                : 0
            let availableForTranscript = geometry.size.height - terminalHeight
            // Prefer transcript plane: if both docks would crush chat, collapse terminal first.
            let showTerminal = state.showWorkspaceTerminal && availableForTranscript >= minimumTranscriptHeight
            let suppressed = state.showWorkspaceTerminal && !showTerminal

            VStack(spacing: 0) {
                Group {
                    if state.showFileBrowser {
                        HSplitView {
                            ConversationView(state: state)
                                .frame(minWidth: 360, minHeight: minimumTranscriptHeight)
                            FileBrowserPanel(state: state)
                                .frame(minWidth: 280, idealWidth: 360, maxWidth: 520)
                        }
                    } else {
                        ConversationView(state: state)
                            .frame(minHeight: minimumTranscriptHeight)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if showTerminal {
                    Divider()
                    TerminalPanelView(state: state)
                        .frame(height: terminalHeight)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if suppressed {
                    Divider()
                    HStack(spacing: 8) {
                        Image(systemName: "terminal")
                            .foregroundStyle(.secondary)
                        Text("Terminal hidden — window too short")
                            .font(LatticeTypography.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Button("Hide") { state.toggleWorkspaceTerminal() }
                            .buttonStyle(LatticeGhostButtonStyle())
                            .accessibilityLabel("Hide terminal preference")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Terminal dock suppressed because the window is too short")
                }
            }
            .onAppear {
                state.setWorkspaceTerminalLayoutSuppressed(suppressed)
            }
            .onChange(of: suppressed) { _, value in
                state.setWorkspaceTerminalLayoutSuppressed(value)
            }
            .onChange(of: state.showWorkspaceTerminal) { _, _ in
                state.setWorkspaceTerminalLayoutSuppressed(suppressed)
            }
        }
        .animation(LatticeMotion.panelSpring(reduceMotion: reduceMotion), value: state.showFileBrowser)
        .animation(LatticeMotion.panelSpring(reduceMotion: reduceMotion), value: state.showWorkspaceTerminal)
    }
}

private struct SectionWorkspaceLayout<Detail: View>: View {
    @ObservedObject var state: AppState
    @ObservedObject var layout: WorkspaceWindowLayout
    let detail: Detail

    var body: some View {
        NavigationSplitView(columnVisibility: $layout.columnVisibility) {
            SidebarView(layout: layout)
                .navigationSplitViewColumnWidth(
                    min: layout.sidebarExpanded ? 170 : 56,
                    ideal: layout.sidebarExpanded ? min(max(layout.sidebarWidth, 170), 220) : 56,
                    max: layout.sidebarExpanded ? 220 : 56
                )
                .reportWorkspaceWidth(layout.measureSidebar)
        } detail: {
            detail
        }
    }
}

private struct WorkspaceWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct SidebarView: View {
    @ObservedObject var layout: WorkspaceWindowLayout
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isExpanded: Bool { layout.sidebarExpanded }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                if isExpanded {
                    Text("Lattice")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                }
                Spacer()
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { layout.sidebarExpanded.toggle() }
                } label: {
                    Image(systemName: isExpanded ? "sidebar.left" : "sidebar.right")
                }
                .buttonStyle(LatticeIconButtonStyle(size: .compact))
                .accessibilityLabel(isExpanded ? "Collapse sidebar" : "Expand sidebar")
                .help(isExpanded ? "Collapse sidebar" : "Expand sidebar")
            }
            .padding(.horizontal, isExpanded ? 12 : 8)
            .padding(.top, 8)

            List(selection: $layout.selectedSection) {
                ForEach(WorkspaceSection.allCases) { section in
                    Group {
                        if isExpanded {
                            Label(section.displayName, systemImage: section.icon)
                        } else {
                            Image(systemName: section.icon)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .tag(section)
                    .help(section.displayName)
                    .accessibilityLabel(section.displayName)
                    .accessibilityHint("Open \(section.displayName)")
                }
            }
            .listStyle(.sidebar)
        }
        .accessibilityIdentifier(LatticeAccessibilityID.brandingTitle)
    }
}

struct SessionListView: View {
    @ObservedObject var state: AppState
    var filtered: [LatticeSession] {
        state.filteredSessions
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            sessionList
        }
        .navigationTitle("Chats")
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            chatSearchField
            if !state.searchText.isEmpty {
                Button { state.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(LatticeIconButtonStyle(size: .compact))
                    .accessibilityLabel("Clear chat search")
                    .help("Clear chat search")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, state.searchText.isEmpty ? 12 : 4)
        .padding(.vertical, state.searchText.isEmpty ? 8 : 3)
        .background(
            Color.primary.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var chatSearchField: some View {
        TextField("Search chats", text: $state.searchText)
            .textFieldStyle(.plain)
            .foregroundStyle(.primary)
            .tint(.pink)
            .accessibilityIdentifier(LatticeAccessibilityID.chatSearch)
    }

    private var sessionList: some View {
        Group {
            if state.sessions.isEmpty {
                sessionListEmptyState
            } else if filtered.isEmpty {
                sessionListNoSearchMatches
            } else {
                List(selection: $state.selectedSessionID) {
                    ForEach(filtered) { session in
                        let lane = state.threadActivityLane(for: session.id)
                        SessionRow(
                            session: session,
                            selected: state.selectedSessionID == session.id,
                            activityLane: lane,
                            onCancel: { state.cancelThreadActivity(session.id) },
                            onAttention: { state.focusThreadAttention(session.id) },
                            onPriorityChange: { state.setThreadPriority($0, sessionID: session.id) }
                        )
                        .tag(session.id)
                        .accessibilityIdentifier(LatticeAccessibilityID.sessionRow(session.id))
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(session.title)
                        .accessibilityValue(SessionListAccessibilityPolicy.value(for: session, activity: lane))
                        .contextMenu { sessionContextMenu(for: session) }
                    }
                }
                .accessibilityIdentifier(LatticeAccessibilityID.sessionList)
            }
        }
    }

    private var sessionListEmptyState: some View {
        LatticeEmptyState(
            title: "No chats",
            message: "Use New chat in the toolbar to start your first conversation.",
            systemImage: "bubble.left.and.bubble.right",
            primaryActionTitle: "New chat",
            primaryAction: { state.newSession() }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 12)
        .accessibilityIdentifier(LatticeAccessibilityID.sessionList)
    }

    private var sessionListNoSearchMatches: some View {
        LatticeEmptyState(
            title: "No matches",
            message: "No chats match your search.",
            systemImage: "magnifyingglass",
            primaryActionTitle: "Clear search",
            primaryAction: { state.searchText = "" }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 12)
        .accessibilityIdentifier(LatticeAccessibilityID.sessionList)
    }

    @ViewBuilder
    private func sessionContextMenu(for session: LatticeSession) -> some View {
        Button { state.togglePinnedSession(session.id) } label: {
            Label(session.isPinned ? "Unpin Chat" : "Pin Chat", systemImage: session.isPinned ? "pin.slash" : "pin")
        }
        Button {
            state.requestExportSession(session.id)
        } label: {
            Label("Export Chat…", systemImage: "square.and.arrow.up")
        }
        .disabled(session.isStreaming)
        .help(session.isStreaming ? "Stop the current response before exporting this chat" : "Export this chat as a portable archive or Markdown")
        .accessibilityHint(session.isStreaming ? "Stop the current response before exporting this chat." : "Export this chat as a portable archive or Markdown")
        Button {
            state.requestImportChat()
        } label: {
            Label("Import Chat…", systemImage: "square.and.arrow.down")
        }
        .disabled(!state.canImportChat)
        .help(state.canImportChat ? "Import a Lattice JSON archive as a new chat" : "Resolve chat store recovery before importing")
        .accessibilityHint(state.canImportChat ? "Import a Lattice JSON archive as a new chat" : "Resolve chat store recovery before importing")
        Button(role: .destructive) { state.requestDeleteSession(session.id) } label: {
            Label("Delete Chat", systemImage: "trash")
        }
        .disabled(session.isStreaming)
        .help(session.isStreaming ? "Stop the current response before deleting this chat" : "Delete this chat after confirmation")
    }
}

struct SessionRow: View {
    let session: LatticeSession
    let selected: Bool
    let activityLane: ThreadActivityLane
    let onCancel: () -> Void
    let onAttention: () -> Void
    let onPriorityChange: (AgentTaskPriority) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if session.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.pink)
                            .accessibilityHidden(true)
                    }
                    Text(session.title)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .accessibilityHidden(true)
                    Spacer(minLength: 4)
                    if activityLane.hasUnreadActivity {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                    }
                }
                Text(metadata)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if activityLane.status != .idle {
                    HStack(spacing: 6) {
                        Image(systemName: activityLane.status.latticeSystemImage)
                            .foregroundStyle(statusColor)
                        Text(statusText)
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        Menu {
                            ForEach(AgentTaskPriority.allCases.reversed(), id: \.self) { priority in
                                Button {
                                    onPriorityChange(priority)
                                } label: {
                                    if priority == activityLane.priority {
                                        Label(priority.label, systemImage: "checkmark")
                                    } else {
                                        Text(priority.label)
                                    }
                                }
                            }
                        } label: {
                            Text(activityLane.priority.label)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .accessibilityLabel("Priority for \(session.title)")
                        .accessibilityValue(activityLane.priority.label)
                        .help("Change queued task priority")
                        if activityLane.status.canCancel {
                            Button(action: onCancel) {
                                Image(systemName: "stop.fill")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Cancel activity for \(session.title)")
                            .help("Cancel this chat only")
                        }
                        if activityLane.requiresAttention {
                            Button(action: onAttention) {
                                Image(systemName: "arrow.right.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Review activity for \(session.title)")
                            .help("Review this chat")
                        }
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(statusText)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var metadata: String {
        if let preview = session.lastMessagePreview, !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return preview.replacingOccurrences(of: "\n", with: " ")
        }
        return "\(session.executionRoute.mode.displayName) · \(session.backend.displayName)"
    }

    private var statusText: String {
        var value = activityLane.status.label
        if activityLane.queuedCount > 0 {
            value += " · \(activityLane.queuedCount) queued"
        }
        if let queuePosition = activityLane.queuePosition {
            value += " · position \(queuePosition)"
        }
        value += " · \(activityLane.priority.label) priority"
        return value
    }

    private var statusColor: Color {
        switch activityLane.status {
        case .waitingForApproval, .queued: .orange
        case .failed: .red
        case .completed: .green
        case .running: .blue
        case .idle, .cancelled: .secondary
        }
    }
}

private extension ThreadActivityStatus {
    var latticeSystemImage: String {
        switch self {
        case .idle: "circle"
        case .queued: "clock"
        case .running: "waveform"
        case .waitingForApproval: "hand.raised.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .completed: "checkmark.circle.fill"
        case .cancelled: "stop.circle"
        }
    }
}

/// Native macOS surface for the currently selected workspace.
/// Reads only in-memory AppState / LatticeSession fields; does not scan the filesystem or invent metrics.
struct ProjectsView: View {
    @ObservedObject var state: AppState
    @Environment(\.colorScheme) private var colorScheme

    private var trimmedWorkspacePath: String {
        state.selectedWorkspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasWorkspace: Bool { !trimmedWorkspacePath.isEmpty }

    /// Standardized form used for path equality against session.workspacePath.
    private var standardizedWorkspacePath: String? {
        guard hasWorkspace else { return nil }
        return URL(fileURLWithPath: trimmedWorkspacePath).standardizedFileURL.path
    }

    private var workspaceDisplayName: String {
        guard let path = standardizedWorkspacePath else { return "No Workspace" }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    /// Sessions whose workspace matches the current selection via standardized path equality.
    private var relatedSessions: [LatticeSession] {
        guard let path = standardizedWorkspacePath else { return [] }
        let matched = state.sessions.filter { session in
            guard let raw = session.workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                return false
            }
            return URL(fileURLWithPath: raw).standardizedFileURL.path == path
        }
        return LatticeSessionListOrdering.sorted(matched)
    }

    private var recentSessions: [LatticeSession] {
        Array(relatedSessions.prefix(8))
    }

    private var streamingCount: Int {
        relatedSessions.filter(\.isStreaming).count
    }

    private var messageCount: Int {
        relatedSessions.reduce(0) { $0 + $1.totalMessageCount }
    }

    private var activeActionCount: Int {
        relatedSessions.reduce(0) { partial, session in
            partial + session.actions.filter { $0.status == .running || $0.status == .waiting }.count
        }
    }

    private var selectedRelatedSession: LatticeSession? {
        guard let id = state.selectedSessionID else { return nil }
        return relatedSessions.first { $0.id == id }
    }

    var body: some View {
        GeometryReader { proxy in
            let hostWidth = proxy.size.width
            let horizontalPadding: CGFloat = hostWidth > 0 && hostWidth < 720 ? 20 : (hostWidth > 0 && hostWidth < 1100 ? 32 : 40)
            // Prefer measured width; fall back so first layout pass is readable before GeometryReader reports size.
            let contentMax: CGFloat = hostWidth > 0
                ? min(max(hostWidth - horizontalPadding * 2, 0), 920)
                : 720
            ScrollView {
                Group {
                    if hasWorkspace {
                        workspaceSurface(contentWidth: contentMax)
                    } else {
                        noWorkspaceSurface
                    }
                }
                .frame(maxWidth: contentMax, alignment: .leading)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, LatticeMetrics.pageVerticalPadding)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Workspace")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace")
    }

    // MARK: - Surfaces

    private var noWorkspaceSurface: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("No Workspace", systemImage: "folder.badge.questionmark")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            Text("Choose a folder to use as the current workspace. New chats pick up this path; existing chats keep the folder they were created with.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                state.chooseWorkspace()
            } label: {
                Label("Choose Workspace…", systemImage: "folder.badge.plus")
            }
            .buttonStyle(LatticePrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel("Choose Workspace")
            .accessibilityHint("Opens a folder picker to set the current workspace")
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .latticeContentSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("No workspace selected")
    }

    private func workspaceSurface(contentWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            identityHeader
            summaryStrip(contentWidth: contentWidth)
            if let selected = selectedRelatedSession {
                currentActivity(for: selected)
            }
            recentChatsSection
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .latticeContentSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Current workspace")
        .accessibilityValue(workspaceDisplayName)
    }

    // MARK: - Identity & actions

    private var identityHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(workspaceDisplayName)
                        .font(.title2.weight(.semibold))
                        .textSelection(.enabled)
                        .accessibilityAddTraits(.isHeader)
                    Text(trimmedWorkspacePath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Workspace path")
                        .accessibilityValue(trimmedWorkspacePath)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ViewThatFits(in: .horizontal) {
                workspaceActions(stacking: false)
                workspaceActions(stacking: true)
            }
            .controlSize(.regular)
            if let message = state.workspaceActionMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Workspace action result")
                    .accessibilityValue(message)
            }
        }
    }

    @ViewBuilder
    private func workspaceActions(stacking: Bool) -> some View {
        let buttons = Group {
            Button {
                state.chooseWorkspace()
            } label: {
                Label("Choose Workspace…", systemImage: "folder.badge.plus")
            }
            .buttonStyle(LatticePrimaryButtonStyle())
            .accessibilityLabel("Choose Workspace")
            .accessibilityHint("Opens a folder picker to change the current workspace")

            Button {
                state.revealSelectedWorkspaceInFinder()
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .buttonStyle(LatticeSecondaryButtonStyle())
            .disabled(!hasWorkspace)
            .accessibilityLabel("Reveal in Finder")
            .accessibilityHint("Shows the workspace folder in Finder without changing it")

            Button {
                state.copySelectedWorkspacePath()
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }
            .buttonStyle(LatticeGhostButtonStyle())
            .disabled(!hasWorkspace)
            .accessibilityLabel("Copy Path")
            .accessibilityHint("Copies the workspace path to the clipboard")
        }

        if stacking {
            VStack(alignment: .leading, spacing: 10) { buttons }
        } else {
            HStack(spacing: 10) { buttons }
        }
    }

    // MARK: - Summary (in-memory only)

    private func summaryStrip(contentWidth: CGFloat) -> some View {
        let columns: [GridItem] = contentWidth >= 520
            ? [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 10, alignment: .top)]
            : [GridItem(.flexible(minimum: 0, maximum: .infinity), spacing: 10, alignment: .top)]

        return LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            summaryChip(
                title: "Chats",
                value: "\(relatedSessions.count)",
                systemImage: "bubble.left.and.bubble.right",
                accessibility: "\(relatedSessions.count) chats in this workspace"
            )
            summaryChip(
                title: "Messages",
                value: "\(messageCount)",
                systemImage: "text.bubble",
                accessibility: "\(messageCount) messages across workspace chats"
            )
            summaryChip(
                title: "Streaming",
                value: "\(streamingCount)",
                systemImage: "waveform",
                accessibility: "\(streamingCount) chats currently streaming"
            )
            summaryChip(
                title: "Active actions",
                value: "\(activeActionCount)",
                systemImage: "bolt.horizontal.circle",
                accessibility: "\(activeActionCount) running or waiting actions"
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace activity summary")
    }

    private func summaryChip(title: String, value: String, systemImage: String, accessibility: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title3.weight(.semibold).monospacedDigit())
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: LatticeMetrics.compactRadius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
    }

    private func currentActivity(for session: LatticeSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Current activity")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(session.title)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if session.isStreaming {
                        ProgressView()
                            .controlSize(.mini)
                            .accessibilityLabel("Streaming")
                    }
                    Spacer(minLength: 4)
                }

                Text(session.backend.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(activityDetail(for: session))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: LatticeMetrics.compactRadius, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Current activity for \(session.title)")
            .accessibilityValue("\(session.backend.displayName) · \(activityDetail(for: session))")
        }
    }

    private func activityDetail(for session: LatticeSession) -> String {
        var parts: [String] = []
        parts.append("\(session.totalMessageCount) message\(session.totalMessageCount == 1 ? "" : "s")")
        if session.isStreaming {
            parts.append("streaming")
        }
        let liveActions = session.actions.filter { $0.status == .running || $0.status == .waiting }
        if !liveActions.isEmpty {
            let titles = liveActions.prefix(2).map(\.title).joined(separator: ", ")
            parts.append("\(liveActions.count) active: \(titles)")
        } else if let lastPreview = session.lastMessagePreview, !lastPreview.isEmpty {
            let preview = lastPreview.trimmingCharacters(in: .whitespacesAndNewlines)
            let clipped = preview.count > 120 ? String(preview.prefix(117)) + "…" : preview
            if !clipped.isEmpty {
                parts.append(clipped)
            }
        }
        parts.append(relativeUpdated(session.lastUpdated))
        return parts.joined(separator: " · ")
    }

    // MARK: - Recent chats

    private var recentChatsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent chats")
                    .font(.headline)
                Spacer(minLength: 8)
                if !relatedSessions.isEmpty {
                    Text("\(relatedSessions.count) total")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            if recentSessions.isEmpty {
                Text("No chats are tied to this workspace yet. New chats use this folder when you start them from Chats.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
                    .accessibilityLabel("No chats for this workspace")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(recentSessions.enumerated()), id: \.element.id) { index, session in
                        if index > 0 {
                            Divider().opacity(0.45)
                        }
                        workspaceSessionRow(session)
                    }
                }
                .background(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.03), in: RoundedRectangle(cornerRadius: LatticeMetrics.compactRadius, style: .continuous))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recent workspace chats")
    }

    private func workspaceSessionRow(_ session: LatticeSession) -> some View {
        Button {
            state.openSessionFromWorkspace(session.id)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if session.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.caption2)
                                .foregroundStyle(.pink)
                                .accessibilityLabel("Pinned")
                        }
                        Text(session.title)
                            .fontWeight(.medium)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        if session.isStreaming {
                            ProgressView()
                                .controlSize(.mini)
                                .accessibilityLabel("Streaming")
                        }
                    }
                    Text(workspaceSessionMetadata(for: session))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .accessibilityLabel(session.title)
        .accessibilityHint("Opens this existing chat")
        .accessibilityValue(workspaceSessionAccessibilityValue(session))
    }

    private func workspaceSessionMetadata(for session: LatticeSession) -> String {
        var parts = ["\(session.totalMessageCount) messages", relativeUpdated(session.lastUpdated)]
        if !session.actions.isEmpty {
            parts.append("\(session.actions.count) actions")
        }
        return parts.joined(separator: " · ")
    }

    private func workspaceSessionAccessibilityValue(_ session: LatticeSession) -> String {
        var parts = ["\(session.totalMessageCount) messages", relativeUpdated(session.lastUpdated)]
        if session.isStreaming { parts.append("streaming") }
        if session.isPinned { parts.append("pinned") }
        return parts.joined(separator: ", ")
    }

    private func relativeUpdated(_ date: Date) -> String {
        if date == .distantPast { return "No activity yet" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
