import AppKit
import Combine
import LatticeCore
import SwiftUI

@MainActor
final class WorkspaceLayoutStore {
    private static let defaultsKey = "lattice.workspace.layout.v2"
    private let defaults: UserDefaults
    private var archive: WorkspaceLayoutArchive
    private var pendingWrite: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        archive = WorkspaceLayoutStatePolicy.decodeArchive(defaults.data(forKey: Self.defaultsKey))
    }

    func state(for key: String) -> WorkspaceLayoutState {
        if archive.windows[key] == nil, archive.windows.count == 1, let legacy = archive.windows["main"] {
            archive.windows.removeValue(forKey: "main")
            archive.windows[key] = legacy
        }
        return WorkspaceLayoutStatePolicy.restoredState(
            for: key,
            in: archive,
            visibleScreens: Self.visibleScreens
        )
    }

    func update(key: String, state: WorkspaceLayoutState) {
        archive = WorkspaceLayoutStatePolicy.updating(archive, key: key, state: state)
        pendingWrite?.cancel()
        pendingWrite = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.writeNow()
        }
    }

    func flush() {
        pendingWrite?.cancel()
        pendingWrite = nil
        writeNow()
    }

    private func writeNow() {
        guard let data = WorkspaceLayoutStatePolicy.encodeArchive(archive) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    static var visibleScreens: [WorkspaceWindowFrame] {
        NSScreen.screens.map { screen in
            let frame = screen.visibleFrame
            return WorkspaceWindowFrame(
                x: frame.origin.x,
                y: frame.origin.y,
                width: frame.width,
                height: frame.height
            )
        }
    }
}

@MainActor
final class WorkspaceWindowLayout: ObservableObject {
    let key: String
    @Published var selectedSection: WorkspaceSection { didSet { changed() } }
    @Published var columnVisibility: NavigationSplitViewVisibility { didSet { changed() } }
    @Published var sidebarExpanded: Bool { didSet { changed() } }
    @Published var showInspector: Bool { didSet { changed() } }
    @Published private(set) var sidebarWidth: CGFloat
    @Published private(set) var inspectorWidth: CGFloat
    @Published private(set) var primarySplitWidth: CGFloat
    @Published private(set) var keyActivationSequence = 0

    private let store: WorkspaceLayoutStore
    private var window: NSWindow?
    private var lastNonMaximizedFrame: WorkspaceWindowFrame?
    /// NotificationCenter tokens are not Sendable; deinit must tear them down off the actor.
    nonisolated(unsafe) private var windowObservers: [NSObjectProtocol] = []
    private var restoringWindow = false
    private var lastMeasuredWorkspaceWidth: CGFloat = 0
    private var lastAutoAppliedColumnVisibility: NavigationSplitViewVisibility?
    private var respectsUserColumnChoice = false

    init(key: String, store: WorkspaceLayoutStore) {
        self.key = key
        self.store = store
        let saved = store.state(for: key)
        selectedSection = WorkspaceSection(persistenceID: saved.selectedPage) ?? .conversations
        columnVisibility = Self.visibility(saved.sidebarVisibility)
        sidebarExpanded = saved.sidebarExpanded
        showInspector = saved.inspectorVisible
        sidebarWidth = CGFloat(saved.sidebarWidth)
        inspectorWidth = CGFloat(saved.inspectorWidth)
        primarySplitWidth = CGFloat(saved.primarySplitSizes.first ?? 280)
        lastNonMaximizedFrame = saved.windowFrame
    }

    deinit {
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
    }

    var isKeyWindow: Bool { window?.isKeyWindow == true }

    func attach(to window: NSWindow) {
        guard self.window !== window else { return }
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers.removeAll()
        self.window = window
        restoreWindowState()
        let names: [Notification.Name] = [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification]
        windowObservers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if name == NSWindow.didBecomeKeyNotification {
                        self?.keyActivationSequence &+= 1
                    } else {
                        self?.captureWindowState()
                    }
                }
            }
        }
    }

    func measureSidebar(_ width: CGFloat) {
        guard width > 0, abs(sidebarWidth - width) > 1 else { return }
        sidebarWidth = width
        changed()
    }

    func measureInspector(_ width: CGFloat) {
        guard width > 0, abs(inspectorWidth - width) > 1 else { return }
        inspectorWidth = width
        changed()
    }

    func measurePrimarySplit(_ width: CGFloat) {
        guard width > 0, abs(primarySplitWidth - width) > 1 else { return }
        primarySplitWidth = width
        changed()
    }

    func noteWorkspaceWidth(_ width: CGFloat) {
        let previous = lastMeasuredWorkspaceWidth
        lastMeasuredWorkspaceWidth = width
        if previous > 0,
           !LatticeWorkspaceLayoutPolicy.shouldResumeAutomaticColumnManagement(width: Double(previous)),
           LatticeWorkspaceLayoutPolicy.shouldResumeAutomaticColumnManagement(width: Double(width)) {
            respectsUserColumnChoice = false
        }
        applyAdaptiveColumnVisibilityIfNeeded()
    }

    func noteColumnVisibilityChanged(_ value: NavigationSplitViewVisibility) {
        if let auto = lastAutoAppliedColumnVisibility, auto == value {
            lastAutoAppliedColumnVisibility = nil
            return
        }
        lastAutoAppliedColumnVisibility = nil
        respectsUserColumnChoice = true
    }

    func applyAdaptiveColumnVisibilityIfNeeded() {
        guard selectedSection == .conversations, lastMeasuredWorkspaceWidth > 0, !respectsUserColumnChoice else { return }
        let suggested: NavigationSplitViewVisibility = LatticeWorkspaceLayoutPolicy.suggestedColumnMode(forWidth: Double(lastMeasuredWorkspaceWidth)) == .all
            ? .all : .doubleColumn
        guard columnVisibility != suggested else { return }
        lastAutoAppliedColumnVisibility = suggested
        columnVisibility = suggested
    }

    func flush() {
        captureWindowState()
        store.flush()
    }

    private func changed() {
        guard !restoringWindow else { return }
        store.update(key: key, state: snapshot())
    }

    private func snapshot() -> WorkspaceLayoutState {
        let currentFrame: WorkspaceWindowFrame? = window.map {
            WorkspaceWindowFrame(x: $0.frame.origin.x, y: $0.frame.origin.y, width: $0.frame.width, height: $0.frame.height)
        }
        if window?.isZoomed != true { lastNonMaximizedFrame = currentFrame }
        return WorkspaceLayoutState(
            selectedPage: selectedSection.persistenceID,
            sidebarVisibility: Self.visibilityID(columnVisibility),
            sidebarExpanded: sidebarExpanded,
            sidebarWidth: sidebarWidth,
            inspectorVisible: showInspector,
            inspectorWidth: inspectorWidth,
            primarySplitSizes: [primarySplitWidth],
            windowFrame: lastNonMaximizedFrame ?? currentFrame,
            windowIsMaximized: window?.isZoomed == true
        )
    }

    private func restoreWindowState() {
        guard let window else { return }
        let saved = store.state(for: key)
        let frameRestored = WorkspaceLayoutStatePolicy.clamped(saved, visibleScreens: WorkspaceLayoutStore.visibleScreens)
        lastNonMaximizedFrame = frameRestored.windowFrame
        restoringWindow = true
        if let frame = frameRestored.windowFrame {
            window.setFrame(
                NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height),
                display: true
            )
        }
        if frameRestored.windowIsMaximized != window.isZoomed { window.zoom(nil) }
        let restored = WorkspaceLayoutStatePolicy.clamped(
            frameRestored,
            visibleScreens: WorkspaceLayoutStore.visibleScreens,
            availableContentWidth: window.frame.width
        )
        columnVisibility = Self.visibility(restored.sidebarVisibility)
        sidebarExpanded = restored.sidebarExpanded
        showInspector = restored.inspectorVisible
        sidebarWidth = CGFloat(restored.sidebarWidth)
        inspectorWidth = CGFloat(restored.inspectorWidth)
        primarySplitWidth = CGFloat(restored.primarySplitSizes.first ?? 280)
        restoringWindow = false
        changed()
    }

    private func captureWindowState() {
        guard !restoringWindow else { return }
        changed()
    }

    private static func visibility(_ value: String) -> NavigationSplitViewVisibility {
        switch value {
        case "doubleColumn": .doubleColumn
        case "detailOnly": .detailOnly
        default: .all
        }
    }

    private static func visibilityID(_ value: NavigationSplitViewVisibility) -> String {
        switch value {
        case .doubleColumn: "doubleColumn"
        case .detailOnly: "detailOnly"
        default: "all"
        }
    }
}

struct WorkspaceWindowReader: NSViewRepresentable {
    let onResolve: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            onResolve(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            guard let window = nsView?.window else { return }
            onResolve(window)
        }
    }
}

private struct MeasuredWidth: ViewModifier {
    let changed: (CGFloat) -> Void

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { proxy in
                Color.clear.onAppear { changed(proxy.size.width) }
                    .onChange(of: proxy.size.width) { _, width in changed(width) }
            }
        }
    }
}

extension View {
    func reportWorkspaceWidth(_ changed: @escaping (CGFloat) -> Void) -> some View {
        modifier(MeasuredWidth(changed: changed))
    }
}
