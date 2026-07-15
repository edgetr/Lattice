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
                    ContentUnavailableView(
                        "No Review Diff",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("A captured before/after pair is required before changes can be reviewed or reverted.")
                    )
                    .frame(maxWidth: .infinity)
                }
            } else {
                ContentUnavailableView(
                    "No Code Checkpoint",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Lattice creates checkpoints when the next Code run begins and ends.")
                )
                .frame(maxWidth: .infinity)
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
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Checkpoint issue: \(issue)")
            }
        }
    }

    private func changeSummary(_ changes: WorkspaceCheckpointChangeSet) -> some View {
        InspectorOpaqueSection(title: "Run Changes", systemImage: "plus.forwardslash.minus") {
            HStack(spacing: 12) {
                stat("Files", changes.stats.filesChanged, color: .primary)
                stat("Added", changes.stats.additions, color: .green)
                stat("Deleted", changes.stats.deletions, color: .red)
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
                DisclosureGroup {
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
                                    .font(.caption2.monospaced())
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
                    Button {
                        model.selectedPath = file.path
                        model.selectedHunkHeader = nil
                        model.selectedStartLine = nil
                        model.selectedEndLine = nil
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: fileIcon(file.status))
                                .foregroundStyle(file.isUntracked ? .orange : .secondary)
                            Text(file.path).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text("+\(file.additions)").foregroundStyle(.green)
                            Text("−\(file.deletions)").foregroundStyle(.red)
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Select \(file.path), \(file.additions) additions, \(file.deletions) deletions")
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
                .foregroundStyle(model.selectedPath == nil ? .orange : .secondary)
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
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.secondary.opacity(0.25)))
                .accessibilityLabel(model.noteKind == .note ? "Review note" : "Follow-up prompt")
            Button(model.noteKind == .note ? "Save Note" : "Save Follow-up") {
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
            .disabled(model.selectedPath == nil || model.noteBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || invalidLineRange)
            .accessibilityHint(model.selectedPath == nil ? "Select a file or hunk first." : "Persists this item with the selected repository path and line range.")
        }
    }

    @ViewBuilder
    private func savedNotes(_ notes: [WorkspaceReviewNote]) -> some View {
        if !notes.isEmpty {
            InspectorOpaqueDisclosure(title: "Saved Review Items (\(notes.count))", systemImage: "tray.full") {
                ForEach(notes) { note in
                    VStack(alignment: .leading, spacing: 3) {
                        Label(note.kind == .note ? "Note" : "Follow-up", systemImage: note.kind == .note ? "text.bubble" : "arrowshape.turn.up.right")
                            .font(.caption.weight(.semibold))
                        Text(note.path + rangeSuffix(note.lineRange))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        Text(note.body).font(.caption).textSelection(.enabled)
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
                            .foregroundStyle(.orange)
                    }
                    Button(review.isApplyingRevert ? "Reverting…" : "Confirm Revert…", role: .destructive) {
                        model.showsRevertConfirmation = true
                    }
                    .disabled(review.isApplyingRevert || state.selectedSession?.isStreaming == true)
                    .accessibilityHint("Opens a final destructive confirmation. Current files are checked again before anything is applied.")
                }
                .padding(8)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            if let status = review.revertStatus {
                Label(status, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
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

    private func select(file: WorkspaceCheckpointFileChange, hunk: WorkspaceCheckpointHunk) {
        model.selectedPath = file.path
        model.selectedHunkHeader = hunk.header
        model.selectedStartLine = max(1, hunk.newStart)
        model.selectedEndLine = max(1, hunk.newStart + max(0, hunk.newCount - 1))
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
        switch kind { case .context: .clear; case .addition: .green.opacity(0.10); case .deletion: .red.opacity(0.10) }
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
