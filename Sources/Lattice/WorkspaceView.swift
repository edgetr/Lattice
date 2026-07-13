import SwiftUI
import AppKit
import LatticeCore

struct WorkspaceView: View {
    @ObservedObject var state: AppState

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
                state.noteWorkspaceWidth(width)
            }
            .onChange(of: state.columnVisibility) { _, newValue in
                state.noteColumnVisibilityChanged(to: newValue)
            }
        )
        .onChange(of: state.selectedSection) { _, section in
            noteSelectedSectionChanged(section)
        }
        .accessibilityIdentifier(LatticeAccessibilityID.workspaceRoot)
        .toolbar {
            ToolbarItemGroup {
                if state.selectedSection == .conversations {
                    Button { state.newSession() } label: { Label("New chat", systemImage: "square.and.pencil") }
                    Button { state.openCommandPalette() } label: { Label("Commands", systemImage: "command") }
                        .accessibilityIdentifier(LatticeAccessibilityID.toolbarCommands)
                    Button { state.overlayMode = .prompt; state.showOverlayAction?() } label: { Label("Overlay", systemImage: "rectangle.on.rectangle") }
                        .accessibilityIdentifier(LatticeAccessibilityID.toolbarOverlay)
                    Button { state.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                } else {
                    Button { state.openCommandPalette() } label: { Label("Commands", systemImage: "command") }
                        .accessibilityIdentifier(LatticeAccessibilityID.toolbarCommands)
                    Button { state.overlayMode = .prompt; state.showOverlayAction?() } label: { Label("Overlay", systemImage: "rectangle.on.rectangle") }
                        .accessibilityIdentifier(LatticeAccessibilityID.toolbarOverlay)
                }
            }
        }
        .sheet(isPresented: $state.showCommandPalette) {
            CommandPaletteView(state: state)
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
            Text("Lattice will use the provider’s verified installer or package source, then check that the CLI is available before enabling it.")
        }
        .safeAreaInset(edge: .top, spacing: 0) {
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

    private func noteSelectedSectionChanged(_ section: WorkspaceSection) {
        guard section == .conversations else { return }
        state.applyAdaptiveColumnVisibilityIfNeeded()
    }

    @ViewBuilder private var workspaceLayout: some View {
        if state.selectedSection == .conversations {
            ConversationWorkspaceLayout(state: state)
        } else {
            SectionWorkspaceLayout(state: state, detail: sectionDetail)
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
        switch state.selectedSection {
        case .conversations: EmptyView()
        case .projects: ProjectsView(state: state)
        case .models: ModelsView(state: state)
        case .connections: ConnectionsView(state: state)
        case .extensions: ExtensionsView(state: state)
        }
    }
}

private struct ConversationWorkspaceLayout: View {
    @ObservedObject var state: AppState

    var body: some View {
        NavigationSplitView(columnVisibility: $state.columnVisibility) {
            SidebarView(state: state)
                // Section sidebar can shrink aggressively; chat list + transcript keep priority.
                .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 230)
        } content: {
            SessionListView(state: state)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 340)
        } detail: {
            if state.isOverlayVisible {
                Color.clear
            } else {
                ConversationView(state: state)
                    .inspector(isPresented: $state.showInspector) {
                        InspectorView(state: state)
                            .inspectorColumnWidth(min: 240, ideal: 280, max: 330)
                    }
            }
        }
        // Prefer a usable transcript over keeping every column open at narrow widths.
        .navigationSplitViewStyle(.prominentDetail)
    }
}

private struct SectionWorkspaceLayout<Detail: View>: View {
    @ObservedObject var state: AppState
    let detail: Detail

    var body: some View {
        NavigationSplitView {
            SidebarView(state: state)
                .navigationSplitViewColumnWidth(min: 168, ideal: 200, max: 230)
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
    @ObservedObject var state: AppState
    var body: some View {
        List(selection: $state.selectedSection) {
            ForEach(WorkspaceSection.allCases) { section in
                Label(section.displayName, systemImage: section.icon).tag(section)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Lattice")
        .accessibilityIdentifier(LatticeAccessibilityID.brandingTitle)
    }
}

struct SessionListView: View {
    @ObservedObject var state: AppState
    var filtered: [LatticeSession] {
        LatticeSessionListOrdering.sorted(state.sessions.filter { $0.matchesSearch(state.searchText) })
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
        .padding(.vertical, state.searchText.isEmpty ? 10 : 4)
        .latticeGlass(cornerRadius: state.cornerRadius(for: .search, default: 18), tint: state.tintColor(for: .search)?.opacity(0.18))
        .padding(10)
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
                        SessionRow(
                            session: session,
                            selected: state.selectedSessionID == session.id,
                            pinAction: { state.togglePinnedSession(session.id) },
                            deleteAction: { state.requestDeleteSession(session.id) }
                        )
                        .tag(session.id)
                        .accessibilityIdentifier(LatticeAccessibilityID.sessionRow(session.id))
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(session.title)
                        .accessibilityValue(SessionListAccessibilityPolicy.value(for: session))
                        .contextMenu { sessionContextMenu(for: session) }
                    }
                }
                .accessibilityIdentifier(LatticeAccessibilityID.sessionList)
            }
        }
    }

    private var sessionListEmptyState: some View {
        ContentUnavailableView {
            Label("No Chats", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("Use New chat in the toolbar to start your first conversation.")
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(LatticeAccessibilityID.sessionList)
    }

    private var sessionListNoSearchMatches: some View {
        ContentUnavailableView {
            Label("No Matches", systemImage: "magnifyingglass")
        } description: {
            Text("No chats match your search.")
                .multilineTextAlignment(.center)
        } actions: {
            Button {
                state.searchText = ""
            } label: {
                Text("Clear Search")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .accessibilityLabel("Clear Search")
            .accessibilityHint("Clear the chat search field")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
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
        .accessibilityHint("Export this chat as a portable archive or Markdown")
        Button {
            state.requestImportChat()
        } label: {
            Label("Import Chat…", systemImage: "square.and.arrow.down")
        }
        .disabled(!state.canImportChat)
        .accessibilityHint("Import a Lattice JSON archive as a new chat")
        Button(role: .destructive) { state.requestDeleteSession(session.id) } label: {
            Label("Delete Chat", systemImage: "trash")
        }
        .disabled(session.isStreaming)
    }
}

struct SessionRow: View {
    let session: LatticeSession
    let selected: Bool
    let pinAction: () -> Void
    let deleteAction: () -> Void

    private var showsPinButton: Bool {
        selected || session.isPinned
    }

    private var showsDeleteButton: Bool {
        selected && !session.isStreaming
    }

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
                    if session.isStreaming {
                        ProgressView()
                            .controlSize(.mini)
                            .accessibilityHidden(true)
                    }
                }
                if let last = session.messages.last, !last.text.isEmpty {
                    Text(last.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button(action: pinAction) {
                Image(systemName: session.isPinned ? "pin.slash" : "pin")
            }
            .buttonStyle(LatticeIconButtonStyle(size: .compact, tint: session.isPinned ? .pink : nil))
            .opacity(showsPinButton ? 1 : 0)
            .disabled(!showsPinButton)
            .accessibilityLabel(session.isPinned ? "Unpin chat" : "Pin chat")
            .help(session.isPinned ? "Unpin chat" : "Pin chat")
            .accessibilityHidden(!showsPinButton)
            Button(role: .destructive, action: deleteAction) {
                Image(systemName: "trash")
            }
            .buttonStyle(LatticeIconButtonStyle(size: .compact, isDestructive: true))
            .opacity(showsDeleteButton ? 1 : 0)
            .disabled(!showsDeleteButton)
            .accessibilityLabel("Delete chat")
            .help("Delete chat")
            .accessibilityHidden(!showsDeleteButton)
        }
        .padding(.vertical, 4)
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
        relatedSessions.reduce(0) { $0 + $1.messages.count }
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
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel("Choose Workspace")
            .accessibilityHint("Opens a folder picker to set the current workspace")
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .latticeGlass(cornerRadius: LatticeMetrics.surfaceRadius)
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
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .latticeGlass(cornerRadius: LatticeMetrics.surfaceRadius)
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
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Choose Workspace")
            .accessibilityHint("Opens a folder picker to change the current workspace")

            Button {
                state.revealSelectedWorkspaceInFinder()
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .disabled(!hasWorkspace)
            .accessibilityLabel("Reveal in Finder")
            .accessibilityHint("Shows the workspace folder in Finder without changing it")

            Button {
                state.copySelectedWorkspacePath()
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
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
        parts.append("\(session.messages.count) message\(session.messages.count == 1 ? "" : "s")")
        if session.isStreaming {
            parts.append("streaming")
        }
        let liveActions = session.actions.filter { $0.status == .running || $0.status == .waiting }
        if !liveActions.isEmpty {
            let titles = liveActions.prefix(2).map(\.title).joined(separator: ", ")
            parts.append("\(liveActions.count) active: \(titles)")
        } else if let last = session.messages.last, !last.text.isEmpty {
            let preview = last.text.trimmingCharacters(in: .whitespacesAndNewlines)
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
        var parts = ["\(session.messages.count) messages", relativeUpdated(session.lastUpdated)]
        if !session.actions.isEmpty {
            parts.append("\(session.actions.count) actions")
        }
        return parts.joined(separator: " · ")
    }

    private func workspaceSessionAccessibilityValue(_ session: LatticeSession) -> String {
        var parts = ["\(session.messages.count) messages", relativeUpdated(session.lastUpdated)]
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
