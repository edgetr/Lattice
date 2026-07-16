import SwiftUI
import LatticeCore

struct CommandPaletteView: View {
    @ObservedObject var state: AppState
    @FocusState private var searchFocused: Bool

    private var results: [LatticeCommandPaletteItem] {
        state.filteredCommandPaletteItems()
    }

    private var chatResults: [LatticeCommandPaletteItem] {
        results.filter { item in
            if case .chat = item.kind { return true }
            return false
        }
    }

    private var commandResults: [LatticeCommandPaletteItem] {
        results.filter { $0.kind == .command }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "command")
                    .foregroundStyle(.secondary)
                TextField("Search chats and commands", text: $state.commandPaletteSearch)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityIdentifier(LatticeAccessibilityID.commandPaletteSearch)
                    .accessibilityLabel("Search chats and commands")
                    .onSubmit { state.performSelectedCommandPaletteItem() }
                    .onChange(of: state.commandPaletteSearch) { _, _ in
                        state.clampCommandPaletteSelection()
                    }
                if !state.commandPaletteSearch.isEmpty {
                    Button {
                        state.commandPaletteSearch = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(LatticeIconButtonStyle(size: .compact))
                    .accessibilityLabel("Clear palette search")
                    .help("Clear palette search")
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, state.commandPaletteSearch.isEmpty ? 14 : 4)
            .padding(.vertical, state.commandPaletteSearch.isEmpty ? 12 : 4)
            .latticeGlass(cornerRadius: 18, tint: .pink.opacity(0.08))
            .padding(14)

            if results.isEmpty {
                LatticeEmptyState(
                    title: "No matches",
                    message: "Try a different chat, workspace, or command name.",
                    systemImage: "magnifyingglass",
                    density: .compact
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List {
                        if !chatResults.isEmpty {
                            Section("Chats") {
                                ForEach(chatResults) { item in paletteButton(item) }
                            }
                        }
                        if !commandResults.isEmpty {
                            Section("Commands") {
                                ForEach(commandResults) { item in paletteButton(item) }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .onAppear {
                        scrollSelectionIntoView(proxy)
                    }
                    .onChange(of: state.commandPaletteSelectedID) { _, _ in
                        scrollSelectionIntoView(proxy)
                    }
                }
            }

            HStack {
                Text("↑↓ select · Return opens the highlighted chat or runs the command.")
                Spacer()
                Button("Close") { state.closeCommandPalette() }
                    .keyboardShortcut(.cancelAction)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 560, height: 470)
        .onAppear {
            // Keep search focused; selection updates never reassign this.
            searchFocused = true
            state.clampCommandPaletteSelection()
        }
        .onChange(of: results) { _, _ in
            state.clampCommandPaletteSelection()
        }
        .focusable()
        .onKeyPress(.upArrow) {
            state.moveCommandPaletteSelection(delta: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            state.moveCommandPaletteSelection(delta: 1)
            return .handled
        }
        .onKeyPress(.return) {
            // AppState gates on palette visibility so this cannot double-run with TextField onSubmit.
            state.performSelectedCommandPaletteItem()
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(LatticeAccessibilityID.commandPalette)
        .accessibilityLabel("Command palette")
    }

    private func paletteButton(_ item: LatticeCommandPaletteItem) -> some View {
        Button {
            guard item.isEnabled else { return }
            state.selectCommandPaletteItem(item.id)
            state.performCommandPaletteItem(item.id)
        } label: {
            CommandPaletteRow(item: item, isSelected: state.commandPaletteSelectedID == item.id)
        }
        .buttonStyle(.plain)
        .disabled(!item.isEnabled)
        .id(item.id)
        .accessibilityIdentifier(LatticeAccessibilityID.commandPaletteItem(item.id))
        .listRowBackground(selectionBackground(for: item))
        .help(item.isEnabled ? item.detail : (item.disabledReason ?? item.detail))
        .onHover { hovering in
            // Mouse exit must not clear the shared selection or steal search focus.
            guard hovering else { return }
            state.selectCommandPaletteItem(item.id)
        }
    }

    private func scrollSelectionIntoView(_ proxy: ScrollViewProxy) {
        guard let id = state.commandPaletteSelectedID else { return }
        DispatchQueue.main.async {
            // Use the smallest necessary scroll. Centering an animated hover target can
            // move another row under the pointer and cause a hover-selection cascade.
            proxy.scrollTo(id)
        }
    }

    @ViewBuilder
    private func selectionBackground(for item: LatticeCommandPaletteItem) -> some View {
        if state.commandPaletteSelectedID == item.id {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(item.isEnabled ? Color.pink.opacity(0.14) : Color.secondary.opacity(0.10))
        } else {
            Color.clear
        }
    }
}

private struct CommandPaletteRow: View {
    let item: LatticeCommandPaletteItem
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbolName)
                .foregroundStyle(item.isEnabled ? .pink : .secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(item.isEnabled ? .primary : .secondary)
                Text(item.isEnabled ? item.detail : (item.disabledReason ?? item.detail))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let chatState = item.chatState, chatState.requiresAttention {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
            } else if let chatState = item.chatState, chatState.hasUnreadActivity {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            } else if item.chatState?.isCurrent == true {
                Text("Current")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else if isSelected, item.isEnabled {
                Text("↩")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.title)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(item.isEnabled ? item.detail : (item.disabledReason ?? item.detail))
        .accessibilityAddTraits(accessibilityTraits)
    }

    /// Distinct SF Symbol per command id so enabled rows scan quickly.
    /// Disabled/unavailable rows always use `nosign` regardless of id.
    private var symbolName: String {
        guard item.isEnabled else { return "nosign" }
        if let chatState = item.chatState {
            switch chatState.activityStatus {
            case .idle: return "bubble.left"
            case .queued: return "clock"
            case .running: return "waveform"
            case .waitingForApproval: return "hand.raised.fill"
            case .failed: return "exclamationmark.triangle.fill"
            case .completed: return "checkmark.circle.fill"
            case .cancelled: return "stop.circle"
            }
        }
        switch item.id {
        case "new-chat": return "square.and.pencil"
        case "send-message": return "paperplane"
        case "stop": return "stop.circle"
        case "continue": return "arrow.forward.circle"
        case "open-overlay": return "macwindow"
        case "show-chats": return "bubble.left.and.bubble.right"
        case "show-projects": return "folder"
        case "show-models": return "cpu"
        case "show-connections": return "link"
        case "show-extensions": return "puzzlepiece.extension"
        case "toggle-inspector": return "sidebar.trailing"
        case "choose-workspace": return "folder.badge.gearshape"
        case "refresh-connections": return "arrow.clockwise"
        case "open-extensions-folder": return "folder.badge.plus"
        case "open-skills-folder": return "wand.and.stars"
        case "policy-ask": return "hand.raised"
        case "policy-smart": return "sparkles"
        case "policy-accept-edits": return "pencil.and.outline"
        case "policy-yolo": return "bolt.fill"
        case "privacy-cloud": return "cloud"
        case "privacy-local": return "lock.iphone"
        case "export-chat": return "square.and.arrow.up"
        case "import-chat": return "square.and.arrow.down"
        default: return "command"
        }
    }

    private var accessibilityValue: String {
        if item.isEnabled {
            return isSelected ? "Selected" : ""
        }
        let reason = item.disabledReason ?? "Unavailable"
        // Disabled rows are never the shared selection, but still announce disabled truthfully.
        return "Disabled, \(reason)"
    }

    private var accessibilityTraits: AccessibilityTraits {
        isSelected ? .isSelected : AccessibilityTraits()
    }
}
