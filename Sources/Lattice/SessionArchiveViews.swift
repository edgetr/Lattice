import SwiftUI
import LatticeCore

// MARK: - Export options

struct ExportChatSheet: View {
    @ObservedObject var state: AppState
    @FocusState private var focusedControl: ExportFocus?

    private enum ExportFocus: Hashable {
        case format
        case queued
        case export
        case cancel
    }

    private var sessionTitle: String {
        guard let id = state.exportChatSessionID,
              let session = state.sessions.first(where: { $0.id == id }) else {
            return "Selected chat"
        }
        return session.title
    }

    private var hasQueuedFollowUps: Bool {
        guard let id = state.exportChatSessionID,
              let session = state.sessions.first(where: { $0.id == id }) else {
            return false
        }
        return !session.queuedFollowUps.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export Chat")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            Text("Export “\(sessionTitle)” as a portable file. Ordinary unsent composer drafts are never included.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Format", selection: $state.exportChatFormat) {
                ForEach(SessionPortableArchive.ExportFormat.allCases) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .pickerStyle(.radioGroup)
            .focused($focusedControl, equals: .format)
            .accessibilityLabel("Export format")
            .accessibilityHint("JSON archives can be re-imported. Markdown is read-only and cannot be imported.")

            if state.exportChatFormat == .markdown {
                Label("Markdown is human-readable only and cannot be imported later.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("JSON archive is versioned for safe round-trip import on this Mac or another.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle(isOn: $state.exportChatIncludeQueuedFollowUps) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Include queued follow-ups")
                    Text(hasQueuedFollowUps
                         ? "Off by default. Turn on only if you want queued drafts in the export."
                         : "This chat has no queued follow-ups. Leave off unless you expect to add some before export.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .focused($focusedControl, equals: .queued)
            .accessibilityLabel("Include queued follow-ups")
            .accessibilityHint("Queued drafts and follow-ups are excluded unless you explicitly enable this option. Ordinary composer drafts are never exported.")
            .accessibilityIdentifier("export-include-queued")

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Privacy")
                        .font(.caption.weight(.semibold))
                    Text("Exports include the visible transcript, timestamps, pins, mode, provider, model, and runtime labels, user-visible reasoning labels, policy and privacy settings, attachment names only, and sanitized completed action summaries. Provider thread IDs, secrets, hidden reasoning, approval replay state, running state, and attachment file contents are never included.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    state.cancelExportChatSheet()
                }
                .keyboardShortcut(.cancelAction)
                .focused($focusedControl, equals: .cancel)
                .accessibilityLabel("Cancel export")
                .accessibilityHint("Closes without writing a file")

                Button("Export…") {
                    state.confirmExportChatOptions()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .focused($focusedControl, equals: .export)
                .accessibilityLabel("Continue to save panel")
                .accessibilityHint("Opens the system save panel to choose the destination file")
                .accessibilityIdentifier("export-confirm")
            }
        }
        .padding(22)
        .frame(width: 480)
        .onAppear { focusedControl = .format }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Export chat options")
    }
}

// MARK: - Import preview

struct ImportChatPreviewSheet: View {
    @ObservedObject var state: AppState
    @FocusState private var focusedControl: ImportFocus?

    private enum ImportFocus: Hashable {
        case cancel
        case confirm
    }

    private var preview: SessionArchiveImportPreview? {
        state.pendingImportPlan?.preview
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import Chat Preview")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            Text("Review the archive. Nothing is added until you confirm. Import always creates a new chat and never overwrites or merges with existing chats.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let preview {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        labeledRow("Title", preview.title)
                        labeledRow("Route", "\(preview.routeLabel) · \(preview.modelLabel)")
                        if let harness = preview.harnessLabel, !harness.isEmpty {
                            labeledRow("Runtime", harness)
                        }
                        if let reasoning = preview.reasoningLabel {
                            labeledRow("Reasoning", reasoning)
                        }
                        labeledRow("Policy", preview.policy)
                        labeledRow("Privacy", preview.privacyMode)
                        labeledRow("Messages", "\(preview.messageCount)")
                        labeledRow("Actions", "\(preview.actionCount)")
                        labeledRow("Attachments", "\(preview.attachmentCount) (metadata only; will show as missing)")
                        labeledRow(
                            "Queued follow-ups",
                            preview.includesQueuedFollowUps
                                ? "\(preview.queuedFollowUpCount) included (not auto-sent)"
                                : "excluded"
                        )
                        labeledRow("Pinned", preview.isPinned ? "yes" : "no")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Import preview summary")
                .accessibilityIdentifier("import-preview-summary")

                if preview.isDuplicate {
                    Label(
                        "Duplicate warning: a chat with the same portable content fingerprint already exists. You can still import a separate new copy.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("import-duplicate-warning")
                }

                Text("Provider thread IDs, running state, and approval replay state are never restored. Attachments remain missing metadata only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No import preview is available.")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    state.cancelImportChatPreview()
                }
                .keyboardShortcut(.cancelAction)
                .focused($focusedControl, equals: .cancel)
                .accessibilityLabel("Cancel import")
                .accessibilityHint("Closes without adding a chat")

                Button("Import as New Chat") {
                    state.confirmImportChatPreview()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(preview == nil)
                .focused($focusedControl, equals: .confirm)
                .accessibilityLabel("Confirm import as new chat")
                .accessibilityHint("Adds a new chat from the archive without starting the provider")
                .accessibilityIdentifier("import-confirm")
            }
        }
        .padding(22)
        .frame(width: 520)
        .onAppear { focusedControl = .confirm }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Import chat preview")
    }

    private func labeledRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}
