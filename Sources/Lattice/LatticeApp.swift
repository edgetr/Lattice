import SwiftUI
import AppKit
import Darwin
import LatticeCore

@main
struct LatticeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Lattice", id: "workspace") {
            WorkspaceRootView(state: delegate.state)
        }
        .defaultSize(width: 1240, height: 800)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Command Palette…") { delegate.state.openCommandPalette() }
                    .keyboardShortcut("k", modifiers: [.command])
                Button("Open Command Palette…") { delegate.state.openCommandPalette() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Show Lattice Overlay") { delegate.overlay.toggle() }
            }
            CommandMenu("Session") {
                Button("New Chat") { delegate.state.newSession() }
                    .keyboardShortcut("n", modifiers: [.command])
                Button("Previous Chat") { delegate.state.selectAdjacentSession(offset: -1) }
                    .keyboardShortcut("[", modifiers: [.command, .option])
                    .disabled(!delegate.state.canNavigateSessionList)
                Button("Next Chat") { delegate.state.selectAdjacentSession(offset: 1) }
                    .keyboardShortcut("]", modifiers: [.command, .option])
                    .disabled(!delegate.state.canNavigateSessionList)
                Button("Send Message") { delegate.state.sendDraft() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!delegate.state.canSendDraft)
                Button("Stop") { delegate.state.stop() }
                    .keyboardShortcut(".", modifiers: [.command])
                    .disabled(!delegate.state.canStopSelectedSession)
                Button("Continue Response") { delegate.state.continueSelectedResponse() }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .disabled(!delegate.state.canContinueSelectedSession)
                Divider()
                Button("Export Chat…") { delegate.state.requestExportSelectedSession() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(!delegate.state.canExportSelectedSession)
                    .accessibilityHint("Export the selected chat as a portable archive or Markdown")
                Button("Import Chat…") { delegate.state.requestImportChat() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(!delegate.state.canImportChat)
                    .accessibilityHint("Import a Lattice JSON archive as a new chat after preview")
                Divider()
                Button("Delete Chat", role: .destructive) {
                    delegate.state.requestDeleteSelectedSession()
                }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(!delegate.state.canDeleteSelectedSession)
            }
            CommandMenu("Connections") {
                Button("Refresh Connections") { delegate.state.requestConnectionRefresh() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!delegate.state.canRequestConnectionRefresh)
                    .accessibilityHint(delegate.state.connectionRefreshDisabledReason ?? "Refresh provider readiness and model catalogs")
            }
        }

        Settings {
            SettingsView(state: delegate.state)
        }
        .defaultSize(width: 560, height: 400)
    }
}

struct WorkspaceRootView: View {
    @ObservedObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        WorkspaceView(state: state)
            .frame(minWidth: 900, minHeight: 620)
            .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
            .preferredColorScheme(nil)
            .sheet(isPresented: Binding(
                get: { state.showsOnboarding && !state.needsPersistenceRecovery },
                set: { if !$0 { state.skipOnboarding() } }
            )) {
                OnboardingView(
                    step: $state.onboardingStep,
                    workspacePath: state.selectedWorkspacePath,
                    onChooseWorkspace: state.chooseWorkspace,
                    onOpenConnections: state.openConnectionsFromOnboarding,
                    onSkip: state.skipOnboarding,
                    onFinish: state.finishOnboarding
                )
            }
            .onAppear {
                state.openWorkspaceAction = { openWindow(id: "workspace") }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    lazy var overlay = OverlayPanelController(state: state)
    private var isTerminatingDuplicateInstance = false
    private var ownsSingleInstanceLock = false
    private var didFlushForTermination = false
    private let singleInstanceLockURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "com.lattice.desktop.instance.lock",
        isDirectory: true
    )

    func applicationWillFinishLaunching(_ notification: Notification) {
        if claimSingleInstanceLockOrActivateExisting() || activateExistingPackagedInstanceIfNeeded() {
            isTerminatingDuplicateInstance = true
            NSApp.terminate(nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        guard !isTerminatingDuplicateInstance else { return }
        if activateExistingPackagedInstanceIfNeeded() {
            isTerminatingDuplicateInstance = true
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        overlay.installGlobalShortcut()
        state.showOverlayAction = { [weak self] in self?.overlay.show() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !isTerminatingDuplicateInstance else { return }
        state.refreshConnectionsAfterExternalStateChange()
    }

    func applicationDidResignActive(_ notification: Notification) {
        guard !isTerminatingDuplicateInstance else { return }
        _ = state.flushPersistenceForLifecycleBoundary()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminatingDuplicateInstance else { return .terminateNow }
        switch state.flushPersistenceForLifecycleBoundary() {
        case .saved, .blockedByWriteGate:
            didFlushForTermination = true
            return .terminateNow
        case .failed, .coalescedFailure:
            // Keep the app alive so the non-destructive status UI and Retry remain visible.
            NSApp.activate(ignoringOtherApps: true)
            state.openWorkspaceAction?()
            return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Defensive fallback for termination paths that bypass applicationShouldTerminate.
        if !isTerminatingDuplicateInstance && !didFlushForTermination {
            _ = state.flushPersistenceForLifecycleBoundary()
        }
        guard ownsSingleInstanceLock else { return }
        try? FileManager.default.removeItem(at: singleInstanceLockURL)
        ownsSingleInstanceLock = false
    }

    private func claimSingleInstanceLockOrActivateExisting() -> Bool {
        let pidURL = singleInstanceLockURL.appendingPathComponent("pid")
        let currentPID = NSRunningApplication.current.processIdentifier
        for _ in 0..<2 {
            do {
                try FileManager.default.createDirectory(at: singleInstanceLockURL, withIntermediateDirectories: false)
                try Data("\(currentPID)\n".utf8).write(to: pidURL, options: .atomic)
                ownsSingleInstanceLock = true
                return false
            } catch {
                if let ownerPID = existingLockOwnerPID(from: pidURL),
                   ownerPID != currentPID,
                   let ownerApp = NSRunningApplication(processIdentifier: ownerPID),
                   ownerApp.bundleIdentifier == Bundle.main.bundleIdentifier,
                   !ownerApp.isTerminated,
                   kill(ownerPID, 0) == 0 {
                    ownerApp.activate(options: [.activateAllWindows])
                    return true
                }
                try? FileManager.default.removeItem(at: singleInstanceLockURL)
            }
        }
        return false
    }

    private func existingLockOwnerPID(from pidURL: URL) -> pid_t? {
        guard let data = try? Data(contentsOf: pidURL),
              let text = String(data: data, encoding: .utf8),
              let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return pid_t(value)
    }

    private func activateExistingPackagedInstanceIfNeeded() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return false }
        let currentPID = NSRunningApplication.current.processIdentifier
        let runningInstances = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !$0.isTerminated }

        guard runningInstances.contains(where: { $0.processIdentifier == currentPID }) else { return false }
        guard let primaryInstance = runningInstances.min(by: { left, right in
            switch (left.launchDate, right.launchDate) {
            case let (leftDate?, rightDate?):
                if leftDate != rightDate { return leftDate < rightDate }
                return left.processIdentifier < right.processIdentifier
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return left.processIdentifier < right.processIdentifier
            }
        }) else { return false }

        guard primaryInstance.processIdentifier != currentPID else { return false }
        primaryInstance.activate(options: [.activateAllWindows])
        return true
    }
}
