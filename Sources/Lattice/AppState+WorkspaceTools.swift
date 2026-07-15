import Foundation
import Combine
import AppKit
import SwiftUI
import Darwin
import UniformTypeIdentifiers
import LatticeCore

@MainActor
extension AppState {
    // MARK: - Workspace tools façade

    var activeWorkspacePathForTools: String {
        let sessionPath = selectedSession?.workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !sessionPath.isEmpty { return sessionPath }
        return selectedWorkspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func rebindWorkLoopSurfacesAfterSelectionChange() {
        workspaceTools.rebindAfterSelectionChange()
    }

    var showFileBrowser: Bool {
        get { workspaceTools.showFileBrowser }
        set { workspaceTools.showFileBrowser = newValue }
    }
    var showWorkspaceTerminal: Bool {
        get { workspaceTools.showWorkspaceTerminal }
        set { workspaceTools.showWorkspaceTerminal = newValue }
    }
    var workspaceTerminalLayoutSuppressed: Bool { workspaceTools.workspaceTerminalLayoutSuppressed }
    var fileBrowserRootPath: String { workspaceTools.fileBrowserRootPath }
    var fileBrowserRelativeDirectory: String { workspaceTools.fileBrowserRelativeDirectory }
    var fileBrowserNodes: [WorkspaceFileNode] { workspaceTools.fileBrowserNodes }
    var fileBrowserSelectedPath: String? { workspaceTools.fileBrowserSelectedPath }
    var fileBrowserPinnedPaths: [String] { workspaceTools.fileBrowserPinnedPaths }
    var fileBrowserPreview: WorkspaceFilePreview? { workspaceTools.fileBrowserPreview }
    var fileBrowserPreviewImage: NSImage? { workspaceTools.fileBrowserPreviewImage }
    var fileBrowserIsLoading: Bool { workspaceTools.fileBrowserIsLoading }
    var fileBrowserPreviewLoading: Bool { workspaceTools.fileBrowserPreviewLoading }
    var fileBrowserTruncated: Bool { workspaceTools.fileBrowserTruncated }
    var fileBrowserError: String? { workspaceTools.fileBrowserError }
    var terminalCommandDraft: String {
        get { workspaceTools.terminalCommandDraft }
        set { workspaceTools.terminalCommandDraft = newValue }
    }
    var workspaceTerminalSnapshot: WorkspaceTerminalSnapshot? { workspaceTools.workspaceTerminalSnapshot }
    var workspaceTerminalIsRunning: Bool { workspaceTools.workspaceTerminalIsRunning }

    func setWorkspaceTerminalLayoutSuppressed(_ suppressed: Bool) {
        workspaceTools.setWorkspaceTerminalLayoutSuppressed(suppressed)
    }
    func toggleFileBrowser() { workspaceTools.toggleFileBrowser() }
    func openFileBrowserPath(_ relativePath: String) { workspaceTools.openFileBrowserPath(relativePath) }
    func refreshFileBrowserListing() { workspaceTools.refreshFileBrowserListing() }
    func selectFileBrowserNode(_ node: WorkspaceFileNode) { workspaceTools.selectFileBrowserNode(node) }
    func pinFileBrowserSelection() { workspaceTools.pinFileBrowserSelection() }
    func toggleWorkspaceTerminal() { workspaceTools.toggleWorkspaceTerminal() }
    func ensureWorkspaceTerminal() { workspaceTools.ensureWorkspaceTerminal() }
    func runWorkspaceTerminalCommand() { workspaceTools.runWorkspaceTerminalCommand() }
    func stopWorkspaceTerminal(invalidateRun: Bool = false) { workspaceTools.stopWorkspaceTerminal(invalidateRun: invalidateRun) }
    func clearWorkspaceTerminal() { workspaceTools.clearWorkspaceTerminal() }
    func fileBrowserNavigateUp() { workspaceTools.fileBrowserNavigateUp() }
    func revealFileBrowserSelectionInFinder() { workspaceTools.revealFileBrowserSelectionInFinder() }
    func attachTerminalOutputToComposer() {
        guard let payload = workspaceTools.terminalOutputAttachmentText() else { return }
        draft = ReviewFollowUpPayloadPolicy.mergeIntoDraft(existingDraft: draft, payload: payload)
        if case .compact = composerState {
            composerState = .expanded
        }
    }
    func openTerminalForFailedTool(cwd: String? = nil) { workspaceTools.openTerminalForFailedTool(cwd: cwd) }

    var composerStateForBinding: MorphingControlState {
        selectedSession.map { visibleComposerState(for: $0.id) } ?? composerState
    }

}
