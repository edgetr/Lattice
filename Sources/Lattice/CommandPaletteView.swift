import SwiftUI
import LatticeCore

struct CommandPaletteView: View {
    @ObservedObject var state: AppState
    @FocusState private var searchFocused: Bool

    private var results: [LatticeCommandPaletteItem] {
        state.filteredCommandPaletteItems()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "command")
                    .foregroundStyle(.secondary)
                TextField("Search commands", text: $state.commandPaletteSearch)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityIdentifier(LatticeAccessibilityID.commandPaletteSearch)
                    .accessibilityLabel("Search commands")
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
                    .accessibilityLabel("Clear command search")
                    .help("Clear command search")
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, state.commandPaletteSearch.isEmpty ? 14 : 4)
            .padding(.vertical, state.commandPaletteSearch.isEmpty ? 12 : 4)
            .latticeGlass(cornerRadius: 18, tint: .pink.opacity(0.08))
            .padding(14)

            if results.isEmpty {
                ContentUnavailableView("No commands", systemImage: "command", description: Text("Try a different action name."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(results) { item in
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
                Text("↑↓ select · Return runs the highlighted enabled command.")
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
            if isSelected, item.isEnabled {
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
