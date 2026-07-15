import SwiftUI
import AppKit
import LatticeCore
import UniformTypeIdentifiers

struct TranscriptLoadingView: View {
    var body: some View {
        VStack(spacing: 18) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 12) {
                ForEach([0.92, 0.72, 0.84], id: \.self) { width in
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.secondary.opacity(0.12))
                        .frame(maxWidth: 560 * width, minHeight: 44, maxHeight: 44)
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            Text("Loading conversation…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading conversation transcript")
        .accessibilityIdentifier("lattice.conversation.loading")
    }
}

/// Compact Jump to Latest control overlaid on the conversation scroll area.
struct JumpToLatestControl: View {
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

struct QueuedFollowUpRow: View {
    let followUp: QueuedFollowUp
    let isFIFOHead: Bool
    let sessionIsStreaming: Bool
    @ObservedObject var state: AppState

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: semantic.systemImage)
                .foregroundStyle(semantic.color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(LatticeTypography.captionStrong)
                        .foregroundStyle(semantic.color)
                    LatticeStatusChip(semantic: semantic, title: chipTitle)
                }
                Text(followUp.text)
                    .font(LatticeTypography.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let statusDetail {
                    Text(statusDetail)
                        .font(LatticeTypography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            if !sessionIsStreaming, isFIFOHead, canSend {
                Button(actionTitle) { state.sendQueuedFollowUp(followUp.id) }
                    .buttonStyle(LatticePrimaryButtonStyle())
                    .accessibilityHint(actionHint)
            }
            if canRemove {
                Button("Remove") { state.removeQueuedFollowUp(followUp.id) }
                    .buttonStyle(LatticeGhostButtonStyle())
            }
        }
        .padding(12)
        .latticeContentSurface(cornerRadius: LatticeMetrics.controlRadius)
        .overlay(
            RoundedRectangle(cornerRadius: LatticeMetrics.controlRadius, style: .continuous)
                .strokeBorder(semantic.color.opacity(0.22), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(LatticeAccessibilityID.outboxStrip)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
    }

    private var title: String {
        switch followUp.lifecycle {
        case .pending: "Queued follow-up"
        case .dispatching: "Sending follow-up"
        case .blocked(.contextMismatch): "Review changed context"
        case .blocked(.restartRecovery): "Review after restart"
        case .blocked(.missingCapturedContext): "Review imported follow-up"
        case .blocked(.awaitingExplicitReview): "Review follow-up"
        case .failed: "Follow-up failed"
        }
    }

    private var chipTitle: String {
        switch followUp.lifecycle {
        case .pending: "Queued"
        case .dispatching: "Sending"
        case .blocked(.restartRecovery): "After restart"
        case .blocked: "Needs review"
        case .failed: "Failed"
        }
    }

    private var semantic: LatticeStatusSemantic {
        switch followUp.lifecycle {
        case .pending: .queued
        case .dispatching: .running
        case .blocked: .approval
        case .failed: .failed
        }
    }

    private var canSend: Bool {
        if case .dispatching = followUp.lifecycle { return false }
        return true
    }

    private var canRemove: Bool {
        if case .dispatching = followUp.lifecycle { return false }
        return true
    }

    private var statusDetail: String? {
        switch followUp.lifecycle {
        case .failed(let reason):
            return reason.detail ?? "Could not send. Review and retry when ready."
        case .blocked(.restartRecovery):
            return "Lattice restarted before this could send. Review once, then send."
        case .blocked(.contextMismatch):
            return "Route, workspace, or attachments changed since it was queued."
        case .blocked(.missingCapturedContext):
            return "Imported without send context. Review before sending."
        case .blocked(.awaitingExplicitReview):
            return "Waiting for your review before send."
        case .pending:
            return isFIFOHead ? "Next in queue." : "Waiting behind earlier follow-ups."
        case .dispatching:
            return "Sending now…"
        }
    }

    private var actionTitle: String {
        switch followUp.lifecycle {
        case .pending: "Send now"
        case .blocked(.restartRecovery): "Review & send"
        case .blocked, .failed: "Retry"
        case .dispatching: "Sending"
        }
    }

    private var actionHint: String {
        switch followUp.lifecycle {
        case .blocked(.restartRecovery):
            "One-click review after restart, then send"
        case .blocked, .failed:
            "Send after reviewing the blocked or failed follow-up"
        default:
            "Send this queued follow-up now"
        }
    }

    private var accessibilityValue: String {
        switch followUp.lifecycle {
        case .pending: "Queued and waiting"
        case .dispatching: "Sending"
        case .blocked: "Blocked until you review"
        case .failed(let reason): reason.detail ?? "Failed — retry available"
        }
    }
}

/// Composer-adjacent strip that promotes post-run checkpoint review for Code mode.
struct CodeCheckpointReviewStrip: View {
    @ObservedObject var state: AppState
    let review: WorkspaceCheckpointReviewState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(LatticeStatusSemantic.success.color)
            VStack(alignment: .leading, spacing: 2) {
                Text("Run changes ready for review")
                    .font(LatticeTypography.captionStrong)
                if let changes = review.changes {
                    Text("\(changes.stats.filesChanged) files · +\(changes.stats.additions) / −\(changes.stats.deletions)")
                        .font(LatticeTypography.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button("Open Files") {
                if let path = review.changes?.files.first?.path {
                    state.openFileBrowserPath(path)
                } else {
                    state.showFileBrowser = true
                    state.refreshFileBrowserListing()
                }
            }
            .buttonStyle(LatticeSecondaryButtonStyle())
            Button("Review") {
                state.openCheckpointReview()
            }
            .buttonStyle(LatticePrimaryButtonStyle())
            .accessibilityHint("Opens the inspector Review tab for this run")
        }
        .padding(12)
        .latticeContentSurface(cornerRadius: LatticeMetrics.controlRadius)
        .padding(.horizontal, state.composerHorizontalPadding())
        .padding(.top, 8)
        .frame(maxWidth: state.composerMaxWidth())
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Checkpoint review available")
    }
}

struct EmptyConversationView: View {
    @ObservedObject var state: AppState
    var body: some View {
        ZStack(alignment: .topLeading) {
            LatticeIdentityAnchor()
                .padding(.leading, 24)
                .padding(.top, 22)

            LatticeEmptyState(
                title: state.copyText(for: .emptyChatTitle, fallback: "What can I help with?"),
                message: "Send a prompt or attach context to begin. Route: \(state.activeBackend.displayName).",
                systemImage: "sparkles"
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct NewChatShellView: View {
    @ObservedObject var state: AppState

    var body: some View {
        LatticeEmptyState(
            title: "New chat",
            message: state.activeConversationMode.map { "\($0.displayName) mode — nothing is saved until you send or attach context." }
                ?? "Choose a mode and model to begin. Nothing is saved until you send.",
            systemImage: "bubble.left.and.bubble.right"
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("New chat setup")
        .accessibilityValue(state.activeComposerBackend?.displayName ?? "Choose a mode and model")
    }
}

