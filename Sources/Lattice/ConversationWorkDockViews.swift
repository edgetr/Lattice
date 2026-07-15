import SwiftUI
import AppKit
import LatticeCore
import UniformTypeIdentifiers

struct WorkLogDisclosure: View {
    let actions: [SessionAction]
    let onJump: (UUID) -> Void

    private var orderedActions: [SessionAction] {
        actions.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(orderedActions) { action in
                    HStack(alignment: .top, spacing: 8) {
                        SessionActionDetailRow(action: action)
                        Spacer(minLength: 8)
                        Button {
                            onJump(action.work?.originMessageID ?? action.messageID)
                        } label: {
                            Label("Jump", systemImage: "arrow.up.left")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .accessibilityLabel("Jump to originating message")
                        .accessibilityIdentifier(LatticeAccessibilityID.workOriginJump(action.id))
                    }
                    .id(action.id)
                    if action.id != orderedActions.last?.id { Divider() }
                }
            }
            .padding(.top, 10)
        } label: {
            HStack {
                Label("Work log", systemImage: "list.bullet.rectangle")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(actions.count) items")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(LatticeAccessibilityID.workLog)
            .accessibilityLabel("Work log, \(actions.count) items")
            .accessibilityHint("Expand to review chronological work and jump to its source")
        }
        .padding(11)
        .latticeGlass(cornerRadius: 12, interactive: true)
    }
}

struct WorkActionDock: View {
    let session: LatticeSession
    @ObservedObject var state: AppState
    let onJump: (UUID) -> Void

    private var snapshot: WorkProjection.Snapshot { state.workProjection(for: session) }
    private var request: WorkProjection.ActionableRequest? { snapshot.actionable }
    private var action: SessionAction? {
        guard let request else { return nil }
        return session.actions.first(where: { $0.id == request.id })
    }

    private var artifactCanOpen: Bool {
        guard let locator = request?.artifactLocator else { return false }
        let workspace = URL(fileURLWithPath: session.workspacePath ?? state.selectedWorkspacePath).standardizedFileURL
        return WorkArtifactAccessPolicy.canOpen(locator: locator, workspace: workspace)
    }

    var body: some View {
        if let request, let action {
            let presentation = WorkItemPresentationPolicy.presentation(for: request, action: action)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Current request")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(presentation.status)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.orange.opacity(0.12), in: Capsule())
                    Spacer()
                    Button {
                        let actionOrigin = request.originActionID
                        let visibleActionOrigin = snapshot.log.contains(where: { $0.actionID == actionOrigin })
                        onJump(visibleActionOrigin ? actionOrigin : request.originMessageID)
                    } label: {
                        Label("Jump to source", systemImage: "arrow.up.left")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .accessibilityLabel("Jump to originating message or action")
                    .accessibilityIdentifier(LatticeAccessibilityID.workOriginJump(request.id))
                }

                Text(presentation.heading)
                    .font(.headline)
                Text(action.title)
                    .font(.callout.weight(.semibold))
                if !action.detail.isEmpty {
                    Text(action.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(5)
                        .textSelection(.enabled)
                }

                if request.kind == .liveQuestion {
                    TextField("Type your answer", text: answerBinding(for: request.id), axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Answer question")
                        .onSubmit { sendAnswer(request) }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        dockActions(for: request)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        dockActions(for: request)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: state.composerMaxWidth())
            .latticeGlass(cornerRadius: 14, interactive: true, tint: .orange.opacity(0.05))
            .padding(.horizontal, state.composerHorizontalPadding())
            .padding(.top, 8)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(LatticeAccessibilityID.workDock)
            .accessibilityLabel(presentation.accessibilityLabel)
            .accessibilityHint(presentation.accessibilityHint)
        }
    }

    @ViewBuilder
    private func dockActions(for request: WorkProjection.ActionableRequest) -> some View {
        switch request.kind {
        case .liveApproval:
            if let notice = state.harnessPermissionNotice(for: session.id), notice.request.id == request.id {
                let options = state.availableHarnessPermissionOptions(for: notice)
                ForEach(options.filter(\.isReject)) { option in
                    Button(option.name) { state.respondToHarnessPermission(notice, option: option) }
                        .buttonStyle(LatticeSecondaryButtonStyle())
                }
                if options.filter(\.isReject).isEmpty {
                    Button("Stop") { state.stop(sessionID: session.id) }
                        .buttonStyle(LatticeSecondaryButtonStyle())
                }
                ForEach(options.filter(\.isAllow)) { option in
                    Button(option.name) { state.respondToHarnessPermission(notice, option: option) }
                        .buttonStyle(LatticePrimaryButtonStyle())
                        .accessibilityIdentifier(LatticeAccessibilityID.workPrimaryAction(request.id))
                }
            }
        case .liveQuestion:
            Button("Send answer") { sendAnswer(request) }
                .buttonStyle(LatticePrimaryButtonStyle())
                .disabled(answerText(for: request.id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: [.command])
                .accessibilityIdentifier(LatticeAccessibilityID.workPrimaryAction(request.id))
        case .userTaskConfirmation:
            Button("Confirm task") { state.confirmWorkTask(actionID: request.id) }
                .buttonStyle(LatticePrimaryButtonStyle())
                .accessibilityIdentifier(LatticeAccessibilityID.workPrimaryAction(request.id))
        case .retryableFailure:
            Button("Retry turn") { state.retryWorkItem(actionID: request.id) }
                .buttonStyle(LatticePrimaryButtonStyle())
                .accessibilityIdentifier(LatticeAccessibilityID.workPrimaryAction(request.id))
        case .artifactOperation:
            Button("Reveal in Finder") { state.revealWorkArtifact(actionID: request.id) }
                .buttonStyle(LatticeSecondaryButtonStyle())
            Button("Open artifact") { state.openWorkArtifact(actionID: request.id) }
                .buttonStyle(LatticePrimaryButtonStyle())
                .disabled(!artifactCanOpen)
                .help(artifactCanOpen ? "Open this safe workspace document" : "Reveal only: this artifact is not a safe workspace document")
                .accessibilityIdentifier(LatticeAccessibilityID.workPrimaryAction(request.id))
        }
    }

    private func sendAnswer(_ request: WorkProjection.ActionableRequest) {
        let submitted = answerText(for: request.id)
        state.workQuestionAnswers[request.id] = ""
        state.answerWorkQuestion(actionID: request.id, answer: submitted)
    }

    private func answerText(for id: UUID) -> String {
        state.workQuestionAnswers[id] ?? ""
    }

    private func answerBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { state.workQuestionAnswers[id] ?? "" },
            set: { state.workQuestionAnswers[id] = $0 }
        )
    }
}

struct AssistantActivityDisclosure: View {
    let actions: [SessionAction]
    @ObservedObject var state: AppState

    private var summaryTitle: String {
        if actions.count == 1 { return actions[0].title }
        return "\(actions.count) model activities"
    }

    private var summaryStatus: (label: String, color: Color) {
        if actions.contains(where: { $0.status == .waiting }) { return ("Waiting", LatticeStatusSemantic.approval.color) }
        if actions.contains(where: { $0.status == .running }) { return ("Working", LatticeStatusSemantic.running.color) }
        if actions.contains(where: { $0.status == .failed || $0.status == .denied }) { return ("Needs attention", LatticeStatusSemantic.failed.color) }
        if actions.contains(where: { $0.status == .cancelled || $0.status == .interrupted }) { return ("Incomplete", LatticeStatusSemantic.neutral.color) }
        return ("Done", LatticeStatusSemantic.success.color)
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
                    SessionActionDetailRow(
                        action: action,
                        onOpenPath: { path in state.openFileBrowserPath(path) },
                        onOpenTerminal: { cwd in state.openTerminalForFailedTool(cwd: cwd) }
                    )
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
        .latticeGlass(cornerRadius: LatticeMetrics.compactRadius, interactive: true)
        .accessibilityLabel("Model activity, \(summaryTitle), \(summaryStatus.label)")
        .accessibilityHint("Expand or collapse model activity and reasoning summaries")
        .accessibilityIdentifier(
            actions.contains(where: { $0.kind == .approval })
                ? LatticeAccessibilityID.activityApproval
                : LatticeAccessibilityID.activityTool
        )
    }
}

struct SessionActionDetailRow: View {
    let action: SessionAction
    var onOpenPath: ((String) -> Void)?
    var onOpenTerminal: ((String?) -> Void)?

    private var icon: String {
        switch action.kind {
        case .approval: return action.status == .waiting ? "hand.raised.fill" : "checkmark.shield"
        case .plan: return "list.bullet.clipboard"
        case .reasoning: return "brain"
        case .harness: return "terminal"
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

    private var statusSemantic: LatticeStatusSemantic {
        switch action.status {
        case .completed, .allowed: .success
        case .failed, .denied: .failed
        case .cancelled, .interrupted: .neutral
        case .running: .running
        case .waiting: .approval
        }
    }

    private var filePathCandidate: String? {
        guard action.kind == .tool,
              action.toolKind == .write || action.toolKind == .read || action.toolKind == .none else {
            return nil
        }
        let detail = action.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !detail.isEmpty else { return nil }
        // Prefer first path-looking token in the detail line.
        let first = detail.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init).first ?? detail
        return first
    }

    /// Best-effort cwd from failed command detail (absolute path or `cwd:` / `in ` prefixes).
    private var failedToolCwdCandidate: String? {
        let detail = action.detail
        let patterns = ["cwd:", "cwd=", "working directory:", "in "]
        let lower = detail.lowercased()
        for pattern in patterns {
            if let range = lower.range(of: pattern) {
                let after = detail[range.upperBound...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let token = after.split(whereSeparator: { $0.isWhitespace || $0 == ";" || $0 == "," })
                    .map(String.init)
                    .first ?? ""
                if token.hasPrefix("/") { return token }
            }
        }
        // Absolute path token in detail may be the command cwd for shell tools.
        let tokens = detail.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if let abs = tokens.first(where: { $0.hasPrefix("/") && !$0.contains("://") }) {
            // Prefer directories: if it looks like a file, use parent.
            if abs.hasSuffix("/") { return abs }
            if abs.contains(".") {
                return (abs as NSString).deletingLastPathComponent
            }
            return abs
        }
        return nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(statusSemantic.color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(action.title).fontWeight(.medium)
                    LatticeStatusChip(semantic: statusSemantic, title: statusLabel)
                }
                if !action.detail.isEmpty {
                    Text(action.detail)
                        .font(LatticeTypography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if action.workspaceScoped {
                    Label("Workspace scoped", systemImage: "folder.badge.checkmark")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 8) {
                    if let path = filePathCandidate, let onOpenPath {
                        Button("Preview in files") { onOpenPath(path) }
                            .buttonStyle(LatticeGhostButtonStyle())
                            .accessibilityLabel("Preview \(path) in files")
                    }
                    if action.status == .failed,
                       (action.toolKind == .command || action.kind == .harness),
                       let onOpenTerminal {
                        Button("Open terminal") { onOpenTerminal(failedToolCwdCandidate) }
                            .buttonStyle(LatticeGhostButtonStyle())
                            .accessibilityLabel("Open workspace terminal for failed command")
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            action.kind == .approval
                ? LatticeAccessibilityID.activityApproval
                : LatticeAccessibilityID.activityTool
        )
        .accessibilityLabel("\(action.title), \(statusLabel)")
        .accessibilityValue(action.detail)
    }
}

