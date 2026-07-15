import AppKit
import LatticeCore
import SwiftUI

/// Workspace-owned terminal panel. Sessions survive chat switches; agent I/O stays on structured harnesses.
struct TerminalPanelView: View {
    @ObservedObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var commandFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            outputScroll
            Divider()
            commandBar
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 140, idealHeight: 200)
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(LatticeAccessibilityID.terminalPanel)
        .accessibilityLabel("Workspace terminal")
        .onAppear {
            state.ensureWorkspaceTerminal()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            LatticeSectionHeader(title: "Terminal", systemImage: "terminal")
            if let snapshot = state.workspaceTerminalSnapshot {
                LatticeStatusChip(semantic: statusSemantic(snapshot), title: statusTitle(snapshot))
            }
            Spacer(minLength: 4)
            if let path = state.workspaceTerminalSnapshot?.worktreePath, !path.isEmpty {
                Text((path as NSString).lastPathComponent)
                    .font(LatticeTypography.mono)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(path)
            }
            Button {
                state.attachTerminalOutputToComposer()
            } label: {
                Image(systemName: "paperclip")
            }
            .buttonStyle(LatticeIconButtonStyle(size: .compact))
            .disabled(state.workspaceTerminalSnapshot?.lastOutputChunk.isEmpty != false)
            .help("Attach last terminal output to the composer (user-initiated)")
            .accessibilityLabel("Attach terminal output to composer")
            Button {
                state.clearWorkspaceTerminal()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(LatticeIconButtonStyle(size: .compact))
            .accessibilityLabel("Clear terminal")
            Button {
                state.showWorkspaceTerminal = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(LatticeIconButtonStyle(size: .compact))
            .accessibilityLabel("Close terminal")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var outputScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if let lines = state.workspaceTerminalSnapshot?.lines, !lines.isEmpty {
                        ForEach(lines) { line in
                            Text(line.text)
                                .font(LatticeTypography.monoBody)
                                .foregroundStyle(line.isError ? LatticeStatusSemantic.failed.color : .primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    } else {
                        Text("Run shell commands in the workspace. This is not the agent channel.")
                            .font(LatticeTypography.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    }
                }
                .padding(10)
            }
            .onChange(of: state.workspaceTerminalSnapshot?.lines.last?.id) { _, id in
                guard let id else { return }
                if reduceMotion {
                    proxy.scrollTo(id, anchor: .bottom)
                } else {
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var commandBar: some View {
        HStack(spacing: 8) {
            Text("$")
                .font(LatticeTypography.monoBody.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("Command…", text: $state.terminalCommandDraft)
                .textFieldStyle(.plain)
                .font(LatticeTypography.monoBody)
                .focused($commandFocused)
                .onSubmit { state.runWorkspaceTerminalCommand() }
                .disabled(state.workspaceTerminalIsRunning)
                .accessibilityLabel("Terminal command")
                .accessibilityIdentifier(LatticeAccessibilityID.terminalCommand)
            if state.workspaceTerminalIsRunning {
                Button("Stop") { state.stopWorkspaceTerminal() }
                    .buttonStyle(LatticeSecondaryButtonStyle())
                    .accessibilityLabel("Stop running command")
            } else {
                Button("Run") { state.runWorkspaceTerminalCommand() }
                    .buttonStyle(LatticePrimaryButtonStyle())
                    .disabled(state.terminalCommandDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Run command")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func statusSemantic(_ snapshot: WorkspaceTerminalSnapshot) -> LatticeStatusSemantic {
        switch snapshot.state {
        case .idle: return .idle
        case .running: return .running
        case .stopping: return .warning
        case .exited:
            if let code = snapshot.lastExitStatus, code != 0 { return .failed }
            return .success
        case .failed: return .failed
        }
    }

    private func statusTitle(_ snapshot: WorkspaceTerminalSnapshot) -> String {
        switch snapshot.state {
        case .idle:
            return "Ready"
        case .running:
            return "Running"
        case .stopping:
            return "Stopping…"
        case .exited:
            if let code = snapshot.lastExitStatus {
                return code == 0 ? "Exit 0" : "Exit \(code)"
            }
            return "Exited"
        case .failed:
            return snapshot.lastFailureSummary ?? "Failed"
        }
    }
}
