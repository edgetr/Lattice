import SwiftUI
import LatticeCore

/// Ephemeral selection and composer state kept in a StateObject so the manual
/// Command Line Tools build avoids SwiftUI's external `@State` macro while still
/// retaining selection across AppState publishes.
@MainActor
private final class CheckpointReviewViewModel: ObservableObject {
    @Published var selectedPath: String?
    @Published var selectedHunkHeader: String?
    @Published var selectedStartLine: Int?
    @Published var selectedEndLine: Int?
    @Published var noteKind: WorkspaceReviewNoteKind = .note
    @Published var noteBody = ""
    @Published var showsRevertConfirmation = false
    @Published var expandedPaths: Set<String> = []
}

struct CheckpointReviewView: View {
    @ObservedObject var state: AppState
    @StateObject private var model = CheckpointReviewViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let review = state.selectedCheckpointReview {
                statusSection(review)
                if let changes = review.changes {
                    changeSummary(changes)
                    fileReview(changes)
                    noteComposer(review)
                    savedNotes(review.notes)
                    revertSection(review)
                } else if review.activity != .capturingBefore && review.activity != .capturingAfter && review.activity != .running {
                    LatticeEmptyState(
                        title: "No review diff yet",
                        message: "A captured before/after pair is required before changes can be reviewed or reverted.",
                        systemImage: "doc.text.magnifyingglass",
                        density: .compact
                    )
                }
            } else {
                LatticeEmptyState(
                    title: "No Code checkpoint",
                    message: "Lattice creates checkpoints when the next Code run begins and ends. After a run finishes, review opens here by default.",
                    systemImage: "clock.arrow.circlepath",
                    density: .compact
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog(
            "Revert all reviewed changes?",
            isPresented: $model.showsRevertConfirmation,
            titleVisibility: .visible
        ) {
            Button("Revert to Before-Run Checkpoint", role: .destructive) {
                state.confirmSelectedCheckpointRevert()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only the operations in this preview will be attempted. Lattice will refuse if target files have newer, staged, or conflicting changes.")
        }
    }

    private func statusSection(_ review: WorkspaceCheckpointReviewState) -> some View {
        InspectorOpaqueSection(title: "Checkpoint", systemImage: statusIcon(review.activity)) {
            HStack(spacing: 8) {
                if review.activity == .capturingBefore || review.activity == .capturingAfter {
                    ProgressView().controlSize(.small)
                }
                Text(review.activity.label)
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 4)
            }
            Text(review.worktreePath)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            InspectorFactRow(title: "Session", value: shortID(review.sessionID))
            InspectorFactRow(title: "Run", value: shortID(review.runID))
            if let issue = review.issue {
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(LatticeStatusSemantic.approval.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Checkpoint issue: \(issue)")
            }
        }
    }

    private func changeSummary(_ changes: WorkspaceCheckpointChangeSet) -> some View {
        InspectorOpaqueSection(title: "Run Changes", systemImage: "plus.forwardslash.minus") {
            HStack(spacing: 12) {
                stat("Files", changes.stats.filesChanged, color: .primary)
                stat("Added", changes.stats.additions, color: LatticeStatusSemantic.success.color)
                stat("Deleted", changes.stats.deletions, color: LatticeStatusSemantic.failed.color)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(changes.stats.filesChanged) changed files, \(changes.stats.additions) additions, \(changes.stats.deletions) deletions")
        }
    }

    private func fileReview(_ changes: WorkspaceCheckpointChangeSet) -> some View {
        InspectorOpaqueSection(title: "Files & Hunks", systemImage: "doc.text.magnifyingglass") {
            if changes.files.isEmpty {
                Text("No repository changes were recorded for this run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(changes.files) { file in
                DisclosureGroup(isExpanded: expansionBinding(for: file.path)) {
                    if file.isUntracked {
                        Text("Untracked content was not captured. Only privacy-preserving file metadata is available.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    }
                    ForEach(Array(file.hunks.enumerated()), id: \.offset) { _, hunk in
                        VStack(alignment: .leading, spacing: 2) {
                            Button {
                                select(file: file, hunk: hunk)
                            } label: {
                                Text(hunk.header)
                                    .font(LatticeTypography.monoSmall)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Select hunk \(hunk.header) in \(file.path)")
                            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                                diffLine(line, file: file, hunk: hunk)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } label: {
                    LatticeRow(isSelected: model.selectedPath == file.path) {
                        HStack(spacing: 6) {
                            Image(systemName: fileIcon(file.status))
                                .foregroundStyle(file.isUntracked ? LatticeStatusSemantic.warning.color : .secondary)
                            Text(file.path)
                                .font(LatticeTypography.mono)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    model.selectedPath = file.path
                                    model.selectedHunkHeader = nil
                                    model.selectedStartLine = nil
                                    model.selectedEndLine = nil
                                }
                                .accessibilityAddTraits(.isButton)
                                .accessibilityLabel("Select \(file.path), \(file.additions) additions, \(file.deletions) deletions")
                            Text("+\(file.additions)").foregroundStyle(LatticeStatusSemantic.success.color)
                            Text("−\(file.deletions)").foregroundStyle(LatticeStatusSemantic.failed.color)
                            Button {
                                state.openFileBrowserPath(file.path)
                            } label: {
                                Image(systemName: "doc.text.magnifyingglass")
                            }
                            .buttonStyle(LatticeIconButtonStyle(size: .compact))
                            .accessibilityLabel("Preview \(file.path) in files")
                        }
                        .font(LatticeTypography.caption)
                    }
                }
            }
        }
    }

    private func noteComposer(_ review: WorkspaceCheckpointReviewState) -> some View {
        InspectorOpaqueSection(title: "Review Note", systemImage: "text.bubble") {
            Picker("Review item type", selection: $model.noteKind) {
                Text("Note").tag(WorkspaceReviewNoteKind.note)
                Text("Follow-up").tag(WorkspaceReviewNoteKind.followUpPrompt)
            }
            .pickerStyle(.segmented)
            .accessibilityHint("Choose whether to save an observation or a follow-up prompt.")
            Text(targetDescription)
                .font(.caption2.monospaced())
                .foregroundStyle(model.selectedPath == nil ? LatticeStatusSemantic.approval.color : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.selectedPath != nil {
                HStack {
                    lineField("Start", value: $model.selectedStartLine)
                    lineField("End", value: $model.selectedEndLine)
                }
            }
            TextEditor(text: $model.noteBody)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 64, maxHeight: 120)
                .padding(5)
                .background(
                    Color(nsColor: .textBackgroundColor),
                    in: RoundedRectangle(cornerRadius: LatticeMetrics.compactRadius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: LatticeMetrics.compactRadius, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.25))
                )
                .accessibilityLabel(model.noteKind == .note ? "Review note" : "Follow-up prompt")
            noteComposerActions
        }
    }

    @ViewBuilder
    private func savedNotes(_ notes: [WorkspaceReviewNote]) -> some View {
        if !notes.isEmpty {
            InspectorOpaqueDisclosure(title: "Saved Review Items (\(notes.count))", systemImage: "tray.full") {
                ForEach(notes) { note in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Label(note.kind == .note ? "Note" : "Follow-up", systemImage: note.kind == .note ? "text.bubble" : "arrowshape.turn.up.right")
                                .font(.caption.weight(.semibold))
                            Spacer(minLength: 4)
                            Button("Add to follow-up") {
                                state.addReviewNoteToComposer(note)
                            }
                            .buttonStyle(LatticeGhostButtonStyle())
                            .help("Insert this saved review into the composer. Explicit action only.")
                        }
                        Text(note.path + rangeSuffix(note.lineRange))
                            .font(LatticeTypography.monoSmall)
                            .foregroundStyle(.secondary)
                        Text(note.body).font(LatticeTypography.caption).textSelection(.enabled)
                        if note.kind == .followUpPrompt || !note.body.isEmpty {
                            Button {
                                state.openFileBrowserPath(note.path)
                            } label: {
                                Label("Open in files", systemImage: "folder")
                                    .font(LatticeTypography.caption)
                            }
                            .buttonStyle(LatticeGhostButtonStyle())
                        }
                    }
                    .padding(.vertical, 3)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func revertSection(_ review: WorkspaceCheckpointReviewState) -> some View {
        InspectorOpaqueSection(title: "Revert", systemImage: "arrow.uturn.backward.circle") {
            Text("Preview validates ownership and current file state. Applying is a separate confirmed action and refuses conflicts or newer target changes.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(review.isPreparingRevert ? "Preparing Preview…" : "Preview Revert to Checkpoint") {
                state.previewSelectedCheckpointRevert()
            }
            .disabled(!review.ownsCompletePair || review.isPreparingRevert || review.isApplyingRevert || state.selectedSession?.isStreaming == true)
            .accessibilityHint(review.ownsCompletePair ? "Checks for conflicts without changing files." : "A complete captured before and after pair is required.")
            if let preview = review.revertPreview {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Preview · \(preview.operations.count) operation\(preview.operations.count == 1 ? "" : "s")")
                        .font(.caption.weight(.semibold))
                    ForEach(Array(preview.operations.enumerated()), id: \.offset) { _, operation in
                        Label(operation.path, systemImage: operation.kind == .applyTrackedReversePatch ? "doc.badge.arrow.up" : "trash")
                            .font(.caption2.monospaced())
                    }
                    ForEach(preview.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundStyle(LatticeStatusSemantic.approval.color)
                    }
                    Button(review.isApplyingRevert ? "Reverting…" : "Confirm Revert…", role: .destructive) {
                        model.showsRevertConfirmation = true
                    }
                    .disabled(review.isApplyingRevert || state.selectedSession?.isStreaming == true)
                    .accessibilityHint("Opens a final destructive confirmation. Current files are checked again before anything is applied.")
                }
                .padding(8)
                .background(
                    LatticeStatusSemantic.approval.color.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: LatticeMetrics.compactRadius, style: .continuous)
                )
            }
            if let status = review.revertStatus {
                Label(status, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(LatticeStatusSemantic.approval.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Revert status: \(status)")
            }
        }
    }

    private func diffLine(_ line: WorkspaceCheckpointDiffLine, file: WorkspaceCheckpointFileChange, hunk: WorkspaceCheckpointHunk) -> some View {
        let number = line.newLineNumber ?? line.oldLineNumber
        return Button {
            model.selectedPath = file.path
            model.selectedHunkHeader = hunk.header
            model.selectedStartLine = number
            model.selectedEndLine = number
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(number.map(String.init) ?? "·")
                    .frame(width: 28, alignment: .trailing)
                    .foregroundStyle(.secondary)
                Text(prefix(line.kind) + line.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption2.monospaced())
            .padding(.vertical, 1)
            .background(lineBackground(line.kind))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Select \(file.path) line \(number.map(String.init) ?? "without a line number"): \(line.text)")
    }

    private func lineField(_ title: String, value: Binding<Int?>) -> some View {
        TextField(title, value: value, format: .number)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Review \(title.lowercased()) line")
    }

    private var validLineRange: WorkspaceReviewLineRange? {
        guard let start = model.selectedStartLine, let end = model.selectedEndLine,
              start > 0, end >= start else { return nil }
        return WorkspaceReviewLineRange(start: start, end: end)
    }

    private var invalidLineRange: Bool {
        (model.selectedStartLine != nil || model.selectedEndLine != nil) && validLineRange == nil
    }

    private var targetDescription: String {
        guard let selectedPath = model.selectedPath else { return "Select a file, hunk, or diff line to attach this item." }
        return selectedPath + rangeSuffix(validLineRange)
    }

    @ViewBuilder
    private var noteComposerActions: some View {
        let disabled = model.selectedPath == nil
            || model.noteBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || invalidLineRange
        HStack(spacing: 8) {
            if model.noteKind == .note {
                Button("Save Note") { saveCurrentNote() }
                    .buttonStyle(LatticePrimaryButtonStyle())
                    .disabled(disabled)
                    .accessibilityHint(model.selectedPath == nil ? "Select a file or hunk first." : "Persists this item with the selected repository path and line range.")
                Button("Add to follow-up") { addCurrentNoteToComposer() }
                    .buttonStyle(LatticeSecondaryButtonStyle())
                    .disabled(disabled)
                    .help("Insert this review into the composer draft. Notes never enter the composer automatically.")
            } else {
                Button("Save Follow-up") { saveCurrentNote() }
                    .buttonStyle(LatticeSecondaryButtonStyle())
                    .disabled(disabled)
                    .accessibilityHint(model.selectedPath == nil ? "Select a file or hunk first." : "Persists this item with the selected repository path and line range.")
                Button("Add to follow-up") { addCurrentNoteToComposer() }
                    .buttonStyle(LatticePrimaryButtonStyle())
                    .disabled(disabled)
                    .help("Insert this review into the composer draft. Notes never enter the composer automatically.")
                    .accessibilityHint("Explicitly adds this review text to the chat composer.")
            }
        }
    }

    private func saveCurrentNote() {
        guard let selectedPath = model.selectedPath else { return }
        state.addSelectedCheckpointReviewNote(
            path: selectedPath,
            body: model.noteBody,
            kind: model.noteKind,
            lineRange: validLineRange,
            hunkHeader: model.selectedHunkHeader
        )
        model.noteBody = ""
    }

    private func addCurrentNoteToComposer() {
        guard let selectedPath = model.selectedPath else { return }
        state.addReviewSelectionToComposer(
            path: selectedPath,
            body: model.noteBody,
            kind: model.noteKind,
            lineRange: validLineRange,
            hunkHeader: model.selectedHunkHeader
        )
    }

    private func select(file: WorkspaceCheckpointFileChange, hunk: WorkspaceCheckpointHunk) {
        model.selectedPath = file.path
        model.selectedHunkHeader = hunk.header
        model.selectedStartLine = max(1, hunk.newStart)
        model.selectedEndLine = max(1, hunk.newStart + max(0, hunk.newCount - 1))
    }

    private func expansionBinding(for path: String) -> Binding<Bool> {
        Binding(
            get: { model.selectedPath == path || model.expandedPaths.contains(path) },
            set: { expanded in
                if expanded {
                    model.expandedPaths.insert(path)
                    model.selectedPath = path
                } else {
                    model.expandedPaths.remove(path)
                }
            }
        )
    }

    private func stat(_ title: String, _ value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value.formatted()).font(.headline.monospacedDigit()).foregroundStyle(color)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shortID(_ id: UUID) -> String { String(id.uuidString.prefix(8)).lowercased() }
    private func rangeSuffix(_ range: WorkspaceReviewLineRange?) -> String {
        guard let range else { return "" }
        return range.start == range.end ? ":\(range.start)" : ":\(range.start)-\(range.end)"
    }
    private func prefix(_ kind: WorkspaceCheckpointDiffLineKind) -> String {
        switch kind { case .context: " "; case .addition: "+"; case .deletion: "−" }
    }
    private func lineBackground(_ kind: WorkspaceCheckpointDiffLineKind) -> Color {
        switch kind {
        case .context: .clear
        case .addition: LatticeStatusSemantic.success.color.opacity(0.10)
        case .deletion: LatticeStatusSemantic.failed.color.opacity(0.10)
        }
    }
    private func statusIcon(_ activity: WorkspaceCheckpointActivity) -> String {
        switch activity {
        case .idle: "clock"
        case .capturingBefore, .capturingAfter: "arrow.triangle.2.circlepath"
        case .running: "play.circle"
        case .ready: "checkmark.seal"
        case .failed: "exclamationmark.triangle"
        }
    }
    private func fileIcon(_ status: WorkspaceCheckpointFileStatus) -> String {
        switch status {
        case .added: "doc.badge.plus"
        case .deleted: "doc.badge.minus"
        case .renamed: "arrow.right.doc.on.clipboard"
        case .copied: "doc.on.doc"
        case .modified, .typeChanged, .unknown: "doc.text"
        }
    }
}
