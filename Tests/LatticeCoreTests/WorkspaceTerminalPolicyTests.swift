import Foundation
import Testing
@testable import LatticeCore

@Suite("Workspace terminal policy")
struct WorkspaceTerminalPolicyTests {
    @Test func sessionsSurviveChatSwitchOnSameWorktree() {
        let worktree = "/Users/dev/project"
        #expect(WorkspaceTerminalPolicy.survivesSessionSwitch(terminalWorktreePath: worktree))
        #expect(
            WorkspaceTerminalPolicy.survivesSessionSwitch(
                terminalWorktreePath: worktree,
                previousSessionWorkspace: worktree,
                nextSessionWorkspace: "/Users/dev/other"
            )
        )
    }

    @Test func emptyWorktreeKeyDoesNotSurvive() {
        #expect(!WorkspaceTerminalPolicy.survivesSessionSwitch(terminalWorktreePath: "   "))
    }

    @Test func storeKeepsSnapshotAcrossLogicalSessionKeys() {
        var store = WorkspaceTerminalStore()
        var snapshot = store.ensureSnapshot(forWorktreePath: "/tmp/a")
        WorkspaceTerminalPolicy.appendLine(.init(text: "hello"), to: &snapshot)
        store.update(snapshot)

        let restored = store.snapshot(forWorktreePath: "/tmp/a")
        #expect(restored?.lines.count == 1)
        #expect(restored?.lines.first?.text == "hello")
        #expect(store.snapshot(forWorktreePath: "/tmp/b") == nil)
    }

    @Test func contextAttachmentIsUserConstructedFromLastOutput() {
        var snapshot = WorkspaceTerminalSnapshot(worktreePath: "/tmp/ws")
        WorkspaceTerminalPolicy.appendLine(.init(text: "ok"), to: &snapshot)
        let text = WorkspaceTerminalPolicy.contextAttachmentText(from: snapshot)
        #expect(text.contains("/tmp/ws"))
        #expect(text.contains("ok"))
    }

    @Test func emptyOutputAttachmentIsHonest() {
        let snapshot = WorkspaceTerminalSnapshot(worktreePath: "/tmp/ws")
        let text = WorkspaceTerminalPolicy.contextAttachmentText(from: snapshot)
        #expect(text.contains("empty"))
    }

    @Test func sanitizeCommandRejectsEmptyAndBoundsLength() {
        #expect(WorkspaceTerminalPolicy.sanitizeCommand("   ") == nil)
        #expect(WorkspaceTerminalPolicy.sanitizeCommand("ls") == "ls")
        let long = String(repeating: "a", count: WorkspaceTerminalPolicy.maximumCommandLength + 50)
        let sanitized = try #require(WorkspaceTerminalPolicy.sanitizeCommand(long))
        #expect(sanitized.count == WorkspaceTerminalPolicy.maximumCommandLength)
    }

    @Test func lineAndChunkBounds() {
        var snapshot = WorkspaceTerminalSnapshot(worktreePath: "/tmp/ws")
        for index in 0..<(WorkspaceTerminalSnapshot.maximumRetainedLines + 50) {
            WorkspaceTerminalPolicy.appendLine(.init(text: "line-\(index)"), to: &snapshot)
        }
        #expect(snapshot.lines.count == WorkspaceTerminalSnapshot.maximumRetainedLines)
        #expect(snapshot.lastOutputChunk.count <= WorkspaceTerminalSnapshot.maximumOutputChunkCharacters)
    }

    @Test func shouldRemapWhenSelectedWorkspaceChanges() {
        #expect(
            WorkspaceTerminalPolicy.shouldRemapTerminal(
                terminalWorktreePath: "/tmp/a",
                selectedWorkspacePath: "/tmp/b"
            )
        )
        #expect(
            !WorkspaceTerminalPolicy.shouldRemapTerminal(
                terminalWorktreePath: "/tmp/a",
                selectedWorkspacePath: "/tmp/a"
            )
        )
    }

    @Test func resolveShellPrefersExistingCandidates() {
        let shell = WorkspaceTerminalPolicy.resolveShellExecutable(fileExists: { $0 == "/bin/zsh" })
        #expect(shell == "/bin/zsh")
        let missing = WorkspaceTerminalPolicy.resolveShellExecutable(fileExists: { _ in false })
        #expect(missing == nil)
    }

    @Test func exitSemanticLabels() {
        #expect(WorkspaceTerminalPolicy.statusSemanticForExit(0) == "success")
        #expect(WorkspaceTerminalPolicy.statusSemanticForExit(1) == "failed")
    }
}
