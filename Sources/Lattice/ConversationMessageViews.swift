import SwiftUI
import AppKit
import LatticeCore
import UniformTypeIdentifiers

struct MessageRow: View {
    let message: ChatMessage
    let artifacts: [AssistantArtifact]
    let isSessionStreaming: Bool
    let availableWidth: CGFloat
    @ObservedObject var state: AppState

    private var bubbleMaxWidth: CGFloat {
        CGFloat(LatticeMessageRowLayoutPolicy.bubbleMaxWidth)
    }

    /// Session route for provenance — read live from session state, never duplicated onto the message.
    private var routeSession: LatticeSession? {
        state.selectedSession
    }

    private var hasVisibleContent: Bool {
        !message.text.isEmpty || !artifacts.isEmpty
    }

    var body: some View {
        let compactActions = LatticeMessageRowLayoutPolicy.usesCompactActions(
            availableWidth: Double(availableWidth),
            isUser: message.role == .user
        )

        Group {
            if message.role == .user {
                userLayout(compactActions: compactActions)
            } else {
                assistantLayout(compactActions: compactActions)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            MessageTimestampPresentationPolicy.accessibilityMetadata(
                role: message.role,
                date: message.date,
                isGenerating: message.role == .assistant && !hasVisibleContent && isSessionStreaming
            )
        )
    }

    @ViewBuilder
    private func userLayout(compactActions: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Soft leading inset only — never a hard minWidth that can squeeze the bubble.
            Spacer(minLength: compactActions ? 16 : 48)
            MessageActionControls(
                message: message,
                state: state,
                includesEdit: true,
                usesCompactControls: compactActions
            )
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .trailing, spacing: 4) {
                VStack(alignment: .leading, spacing: 6) {
                    if message.isPinned { PinnedMessageBadge() }
                    // Leading alignment inside multi-line user bubbles (bubble itself stays trailing).
                    MessageContentView(text: message.text, isUser: true)
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
                .latticeGlass(cornerRadius: 18, interactive: false, tint: message.isPinned ? .pink.opacity(0.08) : nil)
                // Max only — no minWidth floor. Text wraps within the measured row width.
                .frame(maxWidth: bubbleMaxWidth, alignment: .leading)
                .layoutPriority(1)

                MessageTimestampCaption(date: message.date)
                    .padding(.trailing, 4)
            }
        }
    }

    @ViewBuilder
    private func assistantLayout(compactActions: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if !hasVisibleContent && isSessionStreaming {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.vertical, 5)
                        .accessibilityHidden(true)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        if message.isPinned { PinnedMessageBadge() }
                        if message.role == .assistant, let session = routeSession {
                            AssistantRouteProvenanceCaption(
                                backend: session.backend,
                                sessionHarnessID: session.harnessID
                            )
                        }
                        if !message.text.isEmpty {
                            MessageContentView(text: message.text, isUser: false)
                                .foregroundStyle(message.role == .system ? .secondary : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(artifacts) { artifact in
                            AssistantArtifactCard(
                                artifact: artifact,
                                workspace: URL(
                                    fileURLWithPath: routeSession?.workspacePath ?? state.selectedWorkspacePath,
                                    isDirectory: true
                                )
                            )
                        }
                        MessageTimestampCaption(date: message.date)
                    }
                }
            }
            // Flexible fill — no minWidth floor that can force one-character wrapping.
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            if hasVisibleContent {
                MessageActionControls(
                    message: message,
                    state: state,
                    includesEdit: false,
                    usesCompactControls: compactActions
                )
                .fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}

/// Shared message actions for user and assistant rows.
/// At comfortable widths, renders discrete icon buttons; at compact widths, collapses into one accessible overflow menu.
struct MessageActionControls: View {
    let message: ChatMessage
    @ObservedObject var state: AppState
    var includesEdit: Bool
    var usesCompactControls: Bool

    private var copyLabel: String {
        state.copiedMessageID == message.id ? "Copied" : "Copy"
    }

    private var copySymbol: String {
        state.copiedMessageID == message.id ? "checkmark" : "doc.on.doc"
    }

    private var pinLabel: String {
        message.isPinned ? "Unpin message" : "Pin message"
    }

    private var pinSymbol: String {
        message.isPinned ? "pin.slash" : "pin"
    }

    private var canBranch: Bool {
        state.canBranchFromMessage(message)
    }

    private var compactAccessibilityHint: String {
        var actions = ["copy", "pin"]
        if canBranch { actions.append("branch") }
        if includesEdit { actions.append("edit") }
        actions.append("delete")
        return "Contains message actions: \(actions.joined(separator: ", "))"
    }

    var body: some View {
        if usesCompactControls {
            Menu {
                Button {
                    state.copyMessage(message)
                } label: {
                    Label(copyLabel, systemImage: copySymbol)
                }
                .help(copyLabel)
                .accessibilityLabel(copyLabel)

                Button {
                    state.togglePinnedMessage(message)
                } label: {
                    Label(pinLabel, systemImage: pinSymbol)
                }
                .help(pinLabel)
                .accessibilityLabel(pinLabel)

                if canBranch {
                    Button {
                        state.branchFromMessage(message)
                    } label: {
                        Label("Branch from here", systemImage: "arrow.triangle.branch")
                    }
                    .help("Branch from here")
                    .accessibilityLabel("Branch from here")
                }

                if includesEdit {
                    Button {
                        state.beginEditingMessage(message)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .help("Edit")
                    .accessibilityLabel("Edit")
                }

                Button(role: .destructive) {
                    state.requestDeleteMessage(message)
                } label: {
                    Label("Delete from here", systemImage: "trash")
                }
                .help("Delete from here")
                .accessibilityLabel("Delete from here")
                .accessibilityHint("Removes this message and everything after it")
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(LatticeIconButtonStyle(size: .compact))
            .fixedSize()
            .accessibilityLabel("Message actions")
            .accessibilityHint(compactAccessibilityHint)
            .help("Message actions")
        } else {
            // Spacing keeps ≥40×40 interaction frames from overlapping (visual chrome stays compact).
            HStack(alignment: .center, spacing: 0) {
                MessageActionButton(systemImage: copySymbol, label: copyLabel) {
                    state.copyMessage(message)
                }
                MessageActionButton(systemImage: pinSymbol, label: pinLabel) {
                    state.togglePinnedMessage(message)
                }
                if canBranch {
                    MessageActionButton(systemImage: "arrow.triangle.branch", label: "Branch from here") {
                        state.branchFromMessage(message)
                    }
                }
                if includesEdit {
                    MessageActionButton(systemImage: "pencil", label: "Edit") {
                        state.beginEditingMessage(message)
                    }
                }
                MessageActionButton(systemImage: "trash", label: "Delete from here", isDestructive: true) {
                    state.requestDeleteMessage(message)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }
}

struct PinnedMessageBadge: View {
    var body: some View {
        Label("Pinned", systemImage: "pin.fill")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.pink)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.pink.opacity(0.12), in: Capsule())
            .accessibilityLabel("Pinned message")
    }
}

struct MessageActionButton: View {
    let systemImage: String
    let label: String
    var isDestructive = false
    let action: () -> Void

    var body: some View {
        Button(role: isDestructive ? .destructive : nil, action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(LatticeIconButtonStyle(size: .compact, isDestructive: isDestructive))
        .accessibilityLabel(label)
        .help(label)
    }
}

