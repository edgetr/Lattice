import AppKit
import Foundation
import LatticeCore
import SwiftUI

/// Owns workspace file browser + terminal work-loop surfaces.
/// Separated from AppState so conversation UI does not re-render on tool listing churn.
@MainActor
final class WorkspaceToolsController: ObservableObject {
    @Published var showFileBrowser = false
    @Published var showWorkspaceTerminal = false
    /// True when the terminal dock is preferred open but layout hid it to protect transcript height.
    @Published private(set) var workspaceTerminalLayoutSuppressed = false
    @Published private(set) var fileBrowserRootPath = ""
    @Published private(set) var fileBrowserRelativeDirectory = ""
    @Published private(set) var fileBrowserNodes: [WorkspaceFileNode] = []
    @Published private(set) var fileBrowserSelectedPath: String?
    @Published private(set) var fileBrowserPinnedPaths: [String] = []
    @Published private(set) var fileBrowserPreview: WorkspaceFilePreview?
    @Published private(set) var fileBrowserPreviewImage: NSImage?
    @Published private(set) var fileBrowserIsLoading = false
    @Published private(set) var fileBrowserPreviewLoading = false
    @Published private(set) var fileBrowserTruncated = false
    @Published private(set) var fileBrowserError: String?
    @Published var terminalCommandDraft = ""
    @Published private(set) var workspaceTerminalSnapshot: WorkspaceTerminalSnapshot?
    @Published private(set) var workspaceTerminalIsRunning = false
    /// Wired by AppState so tool messages surface on the shared workspace banner.
    var onWorkspaceActionMessage: (String?) -> Void = { _ in }

    private var fileBrowserListGeneration = 0
    private var fileBrowserPreviewGeneration = 0
    private var fileBrowserListTask: Task<Void, Never>?
    private var fileBrowserPreviewTask: Task<Void, Never>?
    private var workspaceTerminalStore = WorkspaceTerminalStore()
    private var workspaceTerminalProcess: Process?
    private var workspaceTerminalStdoutPipe: Pipe?
    private var workspaceTerminalStderrPipe: Pipe?
    /// Monotonic run identity so stale termination/read handlers cannot clobber a newer run.
    private var workspaceTerminalRunID = UUID()
    /// Worktree path for the currently tracked process (if any).
    private var workspaceTerminalRunningWorktreePath: String?
    private var workspaceTerminalProcessGroupID: pid_t?
    private let fileLister = WorkspaceFileLister()

    /// Active workspace path for tools. Wired by AppState from session + selection.
    var workspacePathProvider: () -> String = { "" }

    private var currentWorkspacePath: String {
        workspacePathProvider().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func rebindAfterSelectionChange() {
        let root = currentWorkspacePath
        if showFileBrowser {
            if fileBrowserRootPath != root {
                fileBrowserRelativeDirectory = ""
                fileBrowserSelectedPath = nil
                fileBrowserPreview = nil
                fileBrowserPreviewImage = nil
                fileBrowserPinnedPaths = []
            }
            refreshFileBrowserListing()
        }
        if showWorkspaceTerminal {
            ensureWorkspaceTerminal()
        }
    }

    // MARK: - File browser



    /// Process is active for the displayed worktree when Process is live and snapshot is running or stopping.
    private func isTerminalProcessActive(
        forDisplayPath displayPath: String,
        snapshotState: WorkspaceTerminalSessionState?
    ) -> Bool {
        let runningKey = workspaceTerminalRunningWorktreePath.map {
            WorkspaceTerminalPolicy.sessionKey(forWorktreePath: $0)
        }
        let displayKey = WorkspaceTerminalPolicy.sessionKey(forWorktreePath: displayPath)
        guard runningKey == displayKey, workspaceTerminalProcess?.isRunning == true else { return false }
        switch snapshotState {
        case .running, .stopping: return true
        default: return false
        }
    }

    func setWorkspaceTerminalLayoutSuppressed(_ suppressed: Bool) {
        if workspaceTerminalLayoutSuppressed != suppressed {
            workspaceTerminalLayoutSuppressed = suppressed
        }
    }

    func toggleFileBrowser() {
        showFileBrowser.toggle()
        if showFileBrowser {
            refreshFileBrowserListing()
        }
    }

    func openFileBrowserPath(_ relativePath: String) {
        showFileBrowser = true
        let cleaned = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            refreshFileBrowserListing()
            return
        }
        // Accept absolute paths only when they resolve under the active workspace.
        let root = currentWorkspacePath
        let relativeCandidate: String
        if cleaned.hasPrefix("/") {
            guard !root.isEmpty else {
                fileBrowserError = "Choose a workspace before opening files."
                return
            }
            let rootKey = (root as NSString).standardizingPath
            let absolute = (cleaned as NSString).standardizingPath
            guard absolute == rootKey || absolute.hasPrefix(rootKey + "/") else {
                fileBrowserError = "Path is outside the workspace."
                return
            }
            let stripped = String(absolute.dropFirst(rootKey.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            relativeCandidate = stripped
        } else {
            relativeCandidate = cleaned
        }

        switch WorkspaceFileListingPolicy.normalizeRelativePath(relativeCandidate) {
        case .failure:
            fileBrowserError = "Path escapes the workspace."
            return
        case .success(let normalized):
            guard case .success = WorkspaceFileListingPolicy.resolveContainedPath(
                rootPath: root,
                relativePath: normalized
            ) else {
                fileBrowserError = "Path escapes the workspace."
                return
            }
            if normalized.contains("/") {
                let parent = (normalized as NSString).deletingLastPathComponent
                fileBrowserRelativeDirectory = parent == "." ? "" : parent
            } else {
                fileBrowserRelativeDirectory = ""
            }
            fileBrowserSelectedPath = normalized
            fileBrowserError = nil
            refreshFileBrowserListing()
            loadFileBrowserPreview(relativePath: normalized)
        }
    }

    func refreshFileBrowserListing() {
        let root = currentWorkspacePath
        fileBrowserRootPath = root
        guard !root.isEmpty else {
            fileBrowserNodes = []
            fileBrowserError = nil
            fileBrowserIsLoading = false
            return
        }
        fileBrowserListTask?.cancel()
        fileBrowserListGeneration += 1
        let generation = fileBrowserListGeneration
        fileBrowserIsLoading = true
        fileBrowserError = nil
        let relative = fileBrowserRelativeDirectory
        let lister = fileLister
        fileBrowserListTask = Task { [weak self] in
            let cancelToken = WorkLoopCancelToken()
            let outcome: Result<WorkspaceFileListingResult, Error> = await withTaskCancellationHandler {
                await Task.detached(priority: .userInitiated) {
                    Result {
                        try lister.list(
                            WorkspaceFileListingRequest(rootPath: root, relativeDirectory: relative),
                            isCancelled: { cancelToken.isCancelled }
                        )
                    }
                }.value
            } onCancel: {
                cancelToken.cancel()
            }
            guard let self, self.fileBrowserListGeneration == generation, !Task.isCancelled else { return }
            switch outcome {
            case .success(let result):
                self.fileBrowserNodes = result.nodes
                self.fileBrowserTruncated = result.truncated
                self.fileBrowserIsLoading = false
            case .failure(let error):
                if (error as? WorkspaceFileListingError) == .cancelled { return }
                self.fileBrowserNodes = []
                self.fileBrowserIsLoading = false
                self.fileBrowserError = (error as? WorkspaceFileListingError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    func fileBrowserNavigateUp() {
        let current = fileBrowserRelativeDirectory
        guard !current.isEmpty else { return }
        let parent = (current as NSString).deletingLastPathComponent
        fileBrowserRelativeDirectory = (parent == "." || parent == current) ? "" : parent
        fileBrowserSelectedPath = nil
        fileBrowserPreview = nil
        fileBrowserPreviewImage = nil
        refreshFileBrowserListing()
    }

    func selectFileBrowserNode(_ node: WorkspaceFileNode) {
        if node.kind == .directory {
            fileBrowserRelativeDirectory = node.relativePath
            fileBrowserSelectedPath = nil
            fileBrowserPreview = nil
            fileBrowserPreviewImage = nil
            refreshFileBrowserListing()
            return
        }
        fileBrowserSelectedPath = node.relativePath
        loadFileBrowserPreview(relativePath: node.relativePath)
    }

    func pinFileBrowserSelection() {
        guard let path = fileBrowserSelectedPath, !path.isEmpty else { return }
        if let index = fileBrowserPinnedPaths.firstIndex(of: path) {
            fileBrowserPinnedPaths.remove(at: index)
        } else {
            fileBrowserPinnedPaths.append(path)
            if fileBrowserPinnedPaths.count > 12 {
                fileBrowserPinnedPaths.removeFirst(fileBrowserPinnedPaths.count - 12)
            }
        }
    }

    func revealFileBrowserSelectionInFinder() {
        guard let relative = fileBrowserSelectedPath, !relative.isEmpty else { return }
        let root = fileBrowserRootPath.isEmpty ? currentWorkspacePath : fileBrowserRootPath
        guard !root.isEmpty else { return }
        do {
            let absolute = try fileLister.containedAbsolutePath(rootPath: root, relativePath: relative)
            let url = URL(fileURLWithPath: absolute)
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                fileBrowserError = "File is missing on disk."
            }
        } catch {
            fileBrowserError = (error as? WorkspaceFileListingError)?.errorDescription ?? "Path is outside the workspace."
        }
    }

    private func loadFileBrowserPreview(relativePath: String) {
        let root = fileBrowserRootPath.isEmpty ? currentWorkspacePath : fileBrowserRootPath
        guard !root.isEmpty else { return }
        fileBrowserPreviewTask?.cancel()
        fileBrowserPreviewGeneration += 1
        let generation = fileBrowserPreviewGeneration
        fileBrowserPreviewLoading = true
        fileBrowserPreview = nil
        fileBrowserPreviewImage = nil
        let lister = fileLister
        fileBrowserPreviewTask = Task { [weak self] in
            let cancelToken = WorkLoopCancelToken()
            let outcome: Result<(WorkspaceFilePreview, NSImage?), Error> = await withTaskCancellationHandler {
                await Task.detached(priority: .userInitiated) {
                    Result {
                        let preview = try lister.preview(
                            rootPath: root,
                            relativePath: relativePath,
                            isCancelled: { cancelToken.isCancelled }
                        )
                        var image: NSImage?
                        if preview.kind == .image, let data = preview.data {
                            image = NSImage(data: data)
                        }
                        return (preview, image)
                    }
                }.value
            } onCancel: {
                cancelToken.cancel()
            }
            guard let self, self.fileBrowserPreviewGeneration == generation, !Task.isCancelled else { return }
            switch outcome {
            case .success(let pair):
                self.fileBrowserPreview = pair.0
                self.fileBrowserPreviewImage = pair.1
                self.fileBrowserPreviewLoading = false
            case .failure(let error):
                if (error as? WorkspaceFileListingError) == .cancelled { return }
                self.fileBrowserPreview = WorkspaceFilePreview(
                    relativePath: relativePath,
                    kind: .missing,
                    message: (error as? WorkspaceFileListingError)?.errorDescription ?? error.localizedDescription
                )
                self.fileBrowserPreviewLoading = false
            }
        }
    }

    // MARK: - Workspace terminal

    func toggleWorkspaceTerminal() {
        showWorkspaceTerminal.toggle()
        if showWorkspaceTerminal {
            ensureWorkspaceTerminal()
        }
    }

    func ensureWorkspaceTerminal() {
        let path = currentWorkspacePath
        guard !path.isEmpty else {
            workspaceTerminalSnapshot = nil
            workspaceTerminalIsRunning = false
            return
        }
        let snapshot = workspaceTerminalStore.ensureSnapshot(forWorktreePath: path)
        workspaceTerminalStore.update(snapshot)
        workspaceTerminalSnapshot = snapshot
        workspaceTerminalIsRunning = isTerminalProcessActive(forDisplayPath: path, snapshotState: snapshot.state)
    }

    func runWorkspaceTerminalCommand() {
        guard let command = WorkspaceTerminalPolicy.sanitizeCommand(terminalCommandDraft) else { return }
        let path = currentWorkspacePath
        guard !path.isEmpty else {
            onWorkspaceActionMessage("Choose a workspace before running terminal commands.")
            return
        }
        // Refuse starting on another worktree while a process is tracked.
        if let runningPath = workspaceTerminalRunningWorktreePath,
           WorkspaceTerminalPolicy.sessionKey(forWorktreePath: runningPath)
            != WorkspaceTerminalPolicy.sessionKey(forWorktreePath: path),
           workspaceTerminalProcess?.isRunning == true {
            onWorkspaceActionMessage("Stop the terminal in the other workspace before starting a new command here.")
            return
        }
        if workspaceTerminalIsRunning,
           workspaceTerminalRunningWorktreePath.map({ WorkspaceTerminalPolicy.sessionKey(forWorktreePath: $0) })
            == WorkspaceTerminalPolicy.sessionKey(forWorktreePath: path) {
            return
        }
        guard let shell = WorkspaceTerminalPolicy.resolveShellExecutable() else {
            var snapshot = workspaceTerminalStore.ensureSnapshot(forWorktreePath: path)
            snapshot.state = .failed
            snapshot.lastFailureSummary = "No shell executable found."
            WorkspaceTerminalPolicy.appendLine(
                .init(text: "No shell executable found on this Mac.", isError: true),
                to: &snapshot
            )
            workspaceTerminalStore.update(snapshot)
            workspaceTerminalSnapshot = snapshot
            return
        }

        // Stop previous run (if any) and invalidate its handlers via a new run ID.
        stopWorkspaceTerminal(invalidateRun: true)

        let runID = UUID()
        workspaceTerminalRunID = runID
        workspaceTerminalRunningWorktreePath = path

        var snapshot = workspaceTerminalStore.ensureSnapshot(forWorktreePath: path)
        WorkspaceTerminalPolicy.appendLine(.init(text: "$ \(command)"), to: &snapshot)
        snapshot.state = .running
        snapshot.lastFailureSummary = nil
        snapshot.lastExitStatus = nil
        workspaceTerminalStore.update(snapshot)
        workspaceTerminalSnapshot = snapshot
        workspaceTerminalIsRunning = true
        terminalCommandDraft = ""

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // Non-interactive shell invocation: not the agent channel. Job control (-m) helps
        // child pipelines share a process group with the shell when the shell becomes leader.
        process.arguments = ["-lc", "set -m; " + command]
        process.currentDirectoryURL = URL(fileURLWithPath: path, isDirectory: true)
        var environment = ChildProcessEnvironmentPolicy.providerOwnedRuntime(
            from: ProcessInfo.processInfo.environment,
            temporaryDirectory: FileManager.default.temporaryDirectory
        )
        environment["TERM"] = environment["TERM"] ?? "xterm-256color"
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        workspaceTerminalProcess = process
        workspaceTerminalStdoutPipe = stdout
        workspaceTerminalStderrPipe = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                self?.appendTerminalOutput(text, isError: false, worktreePath: path, runID: runID)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                self?.appendTerminalOutput(text, isError: true, worktreePath: path, runID: runID)
            }
        }
        process.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            let pid = proc.processIdentifier
            Task { @MainActor in
                self?.handleTerminalTermination(
                    status: status,
                    worktreePath: path,
                    runID: runID,
                    processIdentifier: pid
                )
            }
        }

        do {
            try process.run()
            let pid = process.processIdentifier
            // Only store a process-group id when the shell is the group leader (BoundedProcessTransport pattern).
            // Never fall back to raw PID for kill(-pid) — that can signal Lattice's own group.
            let group = getpgid(pid)
            workspaceTerminalProcessGroupID = (group > 0 && group == pid) ? group : nil
        } catch {
            if workspaceTerminalRunID == runID {
                workspaceTerminalIsRunning = false
                workspaceTerminalProcess = nil
                workspaceTerminalRunningWorktreePath = nil
                workspaceTerminalProcessGroupID = nil
            }
            var failed = workspaceTerminalStore.ensureSnapshot(forWorktreePath: path)
            failed.state = .failed
            failed.lastFailureSummary = error.localizedDescription
            WorkspaceTerminalPolicy.appendLine(
                .init(text: "Launch failed: \(error.localizedDescription)", isError: true),
                to: &failed
            )
            workspaceTerminalStore.update(failed)
            workspaceTerminalSnapshot = failed
        }
    }

    func stopWorkspaceTerminal(invalidateRun: Bool = false) {
        let process = workspaceTerminalProcess
        let groupID = workspaceTerminalProcessGroupID
        let runningPath = workspaceTerminalRunningWorktreePath

        if invalidateRun {
            workspaceTerminalRunID = UUID()
        }

        if let process, process.isRunning {
            // Prefer process-group signal only when we verified the shell is group leader.
            if let groupID, groupID > 0 {
                _ = kill(-groupID, SIGTERM)
            }
            process.terminate()
            // Escalate after a short grace. If we recorded a process group (shell was leader),
            // always SIGKILL the group so pipeline children die even when the shell PID is gone.
            // Per-PID liveness gating only applies when there is no verified group id (PID-reuse safety).
            let escalateGroup = groupID
            let escalatePID = process.processIdentifier
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.35) {
                if let escalateGroup, escalateGroup > 0 {
                    _ = kill(-escalateGroup, SIGKILL)
                    return
                }
                guard escalatePID > 0, kill(escalatePID, 0) == 0 else { return }
                _ = kill(escalatePID, SIGKILL)
            }
        }

        workspaceTerminalStdoutPipe?.fileHandleForReading.readabilityHandler = nil
        workspaceTerminalStderrPipe?.fileHandleForReading.readabilityHandler = nil

        if !invalidateRun {
            // Keep Process retained until its own termination handler for the active run.
            if let runningPath {
                var snapshot = workspaceTerminalStore.ensureSnapshot(forWorktreePath: runningPath)
                if snapshot.state == .running {
                    snapshot.state = .stopping
                    WorkspaceTerminalPolicy.appendLine(
                        .init(text: "[stopping…]", isError: false),
                        to: &snapshot
                    )
                    workspaceTerminalStore.update(snapshot)
                    if WorkspaceTerminalPolicy.sessionKey(forWorktreePath: currentWorkspacePath)
                        == WorkspaceTerminalPolicy.sessionKey(forWorktreePath: runningPath) {
                        workspaceTerminalSnapshot = snapshot
                    }
                }
            }
            workspaceTerminalIsRunning = isTerminalProcessActive(
                forDisplayPath: currentWorkspacePath,
                snapshotState: workspaceTerminalSnapshot?.state
            )
        } else {
            // Superseded/clear: always finalize the **running** worktree snapshot, not only the display path.
            if let runningPath {
                var killed = workspaceTerminalStore.ensureSnapshot(forWorktreePath: runningPath)
                killed.state = .exited
                killed.lastFailureSummary = nil
                WorkspaceTerminalPolicy.appendLine(
                    .init(text: "[stopped]", isError: false),
                    to: &killed
                )
                workspaceTerminalStore.update(killed)
                if WorkspaceTerminalPolicy.sessionKey(forWorktreePath: currentWorkspacePath)
                    == WorkspaceTerminalPolicy.sessionKey(forWorktreePath: runningPath) {
                    workspaceTerminalSnapshot = killed
                }
            }
            workspaceTerminalProcess = nil
            workspaceTerminalStdoutPipe = nil
            workspaceTerminalStderrPipe = nil
            workspaceTerminalRunningWorktreePath = nil
            workspaceTerminalProcessGroupID = nil
            workspaceTerminalIsRunning = false
        }
    }

    func clearWorkspaceTerminal() {
        let runningPath = workspaceTerminalRunningWorktreePath
        let displayPath = currentWorkspacePath
        // If a process belongs to another worktree, stop it and reset that worktree — don't only clear display.
        stopWorkspaceTerminal(invalidateRun: true)
        workspaceTerminalRunID = UUID()

        if let runningPath,
           WorkspaceTerminalPolicy.sessionKey(forWorktreePath: runningPath)
            != WorkspaceTerminalPolicy.sessionKey(forWorktreePath: displayPath) {
            // Reset the killed worktree buffer so it is not left `.running` after Clear on B.
            let clearedRunning = WorkspaceTerminalSnapshot(worktreePath: runningPath)
            workspaceTerminalStore.update(clearedRunning)
        }

        guard !displayPath.isEmpty else {
            workspaceTerminalSnapshot = nil
            return
        }
        let snapshot = WorkspaceTerminalSnapshot(worktreePath: displayPath)
        workspaceTerminalStore.update(snapshot)
        workspaceTerminalSnapshot = snapshot
    }

    func terminalOutputAttachmentText() -> String? {
        guard let snapshot = workspaceTerminalSnapshot else { return nil }
        return WorkspaceTerminalPolicy.contextAttachmentText(from: snapshot)
    }

    func openTerminalForFailedTool(cwd: String? = nil) {
        showWorkspaceTerminal = true
        ensureWorkspaceTerminal()
        if let cwd {
            let standardized = WorkspaceTerminalPolicy.standardizedPath(cwd)
            let workspace = currentWorkspacePath
            if !workspace.isEmpty {
                let root = (workspace as NSString).standardizingPath
                if standardized == root || standardized.hasPrefix(root + "/") {
                    // Pre-fill a cd into the tool cwd when it is under the workspace.
                    if standardized != root {
                        let relative = String(standardized.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        if !relative.isEmpty {
                            terminalCommandDraft = "cd \(relative.shellSingleQuoted) && "
                        }
                    }
                } else if !standardized.isEmpty {
                    onWorkspaceActionMessage("Tool working directory is outside this workspace; terminal stays workspace-scoped.")
                }
            }
        }
    }

    private func appendTerminalOutput(_ text: String, isError: Bool, worktreePath: String, runID: UUID) {
        guard runID == workspaceTerminalRunID else { return }
        let chunks = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var snapshot = workspaceTerminalStore.ensureSnapshot(forWorktreePath: worktreePath)
        // Don't flip stopping back to running on late output.
        let preserveStopping = snapshot.state == .stopping
        for (index, chunk) in chunks.enumerated() {
            if chunk.isEmpty && index == chunks.count - 1 { continue }
            WorkspaceTerminalPolicy.appendLine(.init(text: chunk, isError: isError), to: &snapshot)
        }
        if !preserveStopping {
            snapshot.state = .running
        }
        workspaceTerminalStore.update(snapshot)
        if WorkspaceTerminalPolicy.sessionKey(forWorktreePath: currentWorkspacePath)
            == WorkspaceTerminalPolicy.sessionKey(forWorktreePath: worktreePath) {
            workspaceTerminalSnapshot = snapshot
        }
    }

    private func handleTerminalTermination(
        status: Int32,
        worktreePath: String,
        runID: UUID,
        processIdentifier: Int32
    ) {
        // Ignore stale runs (superseded start/clear).
        guard runID == workspaceTerminalRunID else { return }

        workspaceTerminalStdoutPipe?.fileHandleForReading.readabilityHandler = nil
        workspaceTerminalStderrPipe?.fileHandleForReading.readabilityHandler = nil
        if workspaceTerminalProcess?.processIdentifier == processIdentifier {
            workspaceTerminalProcess = nil
        }
        workspaceTerminalStdoutPipe = nil
        workspaceTerminalStderrPipe = nil
        if workspaceTerminalRunningWorktreePath.map({ WorkspaceTerminalPolicy.sessionKey(forWorktreePath: $0) })
            == WorkspaceTerminalPolicy.sessionKey(forWorktreePath: worktreePath) {
            workspaceTerminalRunningWorktreePath = nil
            workspaceTerminalProcessGroupID = nil
            workspaceTerminalIsRunning = false
        }

        var snapshot = workspaceTerminalStore.ensureSnapshot(forWorktreePath: worktreePath)
        snapshot.state = status == 0 ? .exited : .failed
        snapshot.lastExitStatus = status
        if status != 0 {
            snapshot.lastFailureSummary = "Exit \(status)"
        }
        WorkspaceTerminalPolicy.appendLine(
            .init(text: "[exit \(status)]", isError: status != 0),
            to: &snapshot
        )
        workspaceTerminalStore.update(snapshot)
        if WorkspaceTerminalPolicy.sessionKey(forWorktreePath: currentWorkspacePath)
            == WorkspaceTerminalPolicy.sessionKey(forWorktreePath: worktreePath) {
            workspaceTerminalSnapshot = snapshot
        }
    }

}
