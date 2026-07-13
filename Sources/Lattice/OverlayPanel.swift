import SwiftUI
import AppKit
import Carbon
import LatticeCore

@MainActor
final class OverlayPanelController {
    private let state: AppState
    private var panel: LatticePanel?
    private var hiddenWorkspaceWindows: [NSWindow] = []
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    /// Last size applied to the panel — used to suppress no-op / jittery resizes.
    private var lastAppliedSize = LatticeOverlayLayoutPolicy.Size(width: 0, height: 0)
    /// Last ideal content size accepted from measurement (or fallback).
    private var lastIdealContentSize = LatticeOverlayLayoutPolicy.Size(width: 0, height: 0)
    /// Mode associated with `lastIdealContentSize` so heights never leak across modes.
    private var lastMeasuredMode: OverlayMode?
    /// Shared layout probe for content measurement (owned here so it survives view rebuilds).
    private let layoutMetrics = OverlayLayoutMetrics()

    init(state: AppState) { self.state = state }
    isolated deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    func installGlobalShortcut() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var identifier = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard identifier.id == 1 else { return noErr }
            let controller = Unmanaged<OverlayPanelController>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in controller.toggle() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)

        let identifier = EventHotKeyID(signature: fourCharCode("LATT"), id: 1)
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(cmdKey | shiftKey), identifier, GetApplicationEventTarget(), 0, &hotKey)
    }

    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    func show() {
        let panel = panel ?? makePanel()
        state.isOverlayVisible = true
        hiddenWorkspaceWindows = NSApp.windows.filter { !($0 is LatticePanel) && $0.isVisible }
        hiddenWorkspaceWindows.forEach {
            $0.alphaValue = 1
            $0.ignoresMouseEvents = true
            $0.orderOut(nil)
        }
        if state.overlayMode == .idle {
            state.overlayMode = .prompt
        }
        // Fresh show: discard stale measurements from a prior session.
        lastIdealContentSize = .init(width: 0, height: 0)
        lastAppliedSize = .init(width: 0, height: 0)
        lastMeasuredMode = nil
        layoutMetrics.resetMeasurement()
        resize(for: state.overlayMode, idealContentSize: nil, animated: false)
        position(panel)
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func hide() {
        state.isOverlayVisible = false
        restoreHiddenWorkspaceWindows()
        panel?.orderOut(nil)
    }

    func showWorkspace(completion: (() -> Void)? = nil) {
        state.isOverlayVisible = false
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        restoreHiddenWorkspaceWindows()
        let workspaceIsReady = frontWorkspaceWindow() != nil
        panel?.orderOut(nil)
        if workspaceIsReady {
            completion?()
        } else {
            state.openWorkspaceAction?()
            frontWorkspaceWindowWhenAvailable(completion: completion)
        }
    }

    private func frontWorkspaceWindowWhenAvailable(attempt: Int = 0, completion: (() -> Void)? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.05 : 0.15)) { [weak self] in
            guard let self else { return }
            NSApp.activate(ignoringOtherApps: true)
            if self.frontWorkspaceWindow() != nil {
                completion?()
                return
            }
            if attempt < 5 {
                self.frontWorkspaceWindowWhenAvailable(attempt: attempt + 1, completion: completion)
            }
        }
    }

    private func showCommandPaletteFromOverlay() {
        state.openCommandPaletteFromOverlay { [weak self] completion in
            self?.showWorkspace(completion: completion)
        }
    }

    @discardableResult
    private func frontWorkspaceWindow() -> NSWindow? {
        let candidates = NSApp.windows.filter { !($0 is LatticePanel) && $0.canBecomeMain }
        guard let window = candidates.first else { return nil }
        if window.isMiniaturized { window.deminiaturize(nil) }
        if !window.isVisible { window.orderFrontRegardless() }
        else { window.orderFrontRegardless() }
        window.ignoresMouseEvents = false
        window.alphaValue = 1
        window.makeMain()
        window.makeKey()
        return window
    }

    private func restoreHiddenWorkspaceWindows() {
        guard !hiddenWorkspaceWindows.isEmpty else { return }
        for window in hiddenWorkspaceWindows {
            if window.isMiniaturized {
                window.ignoresMouseEvents = false
                window.alphaValue = 1
            } else {
                window.ignoresMouseEvents = false
                window.alphaValue = 1
                window.orderFrontRegardless()
            }
        }
        hiddenWorkspaceWindows = []
    }

    /// Resizes the floating panel for `mode`.
    /// - Parameter idealContentSize: Measured SwiftUI content size when available; `nil` uses a state-derived estimate until the next measurement.
    func resize(for mode: OverlayMode, idealContentSize: CGSize? = nil, animated: Bool = true) {
        guard let panel else { return }

        let visibleNS = activeVisibleFrame(for: panel)
        let visible = LatticeOverlayLayoutPolicy.Rect(
            x: visibleNS.minX,
            y: visibleNS.minY,
            width: visibleNS.width,
            height: visibleNS.height
        )

        let preferredWidth = preferredWidth(for: mode)
        let minimum = minimumSize(for: mode)

        let ideal: LatticeOverlayLayoutPolicy.Size
        if let measured = idealContentSize, measured.width > 1, measured.height > 1 {
            ideal = .init(width: preferredWidth, height: Double(measured.height))
            lastIdealContentSize = ideal
            lastMeasuredMode = mode
        } else if lastIdealContentSize.height > 1, lastMeasuredMode == mode {
            // Keep last good measurement when onChange fires before the next layout pass.
            ideal = .init(width: preferredWidth, height: lastIdealContentSize.height)
        } else {
            // Mode change or first layout: never reuse another mode's measured height.
            if lastMeasuredMode != mode {
                lastIdealContentSize = .init(width: 0, height: 0)
                lastMeasuredMode = nil
            }
            ideal = fallbackIdealSize(for: mode)
        }

        // Top edge of the current frame (or preferred placement top if the panel has no useful frame yet).
        let currentTop: Double
        if panel.frame.height > 1 {
            currentTop = panel.frame.maxY
        } else {
            currentTop = LatticeOverlayLayoutPolicy.preferredTopY(inVisibleFrame: visible)
        }

        let maximum = LatticeOverlayLayoutPolicy.maximumSize(inVisibleFrame: visible, topY: currentTop)
        let clamped = LatticeOverlayLayoutPolicy.clamp(preferred: ideal, minimum: minimum, maximum: maximum)

        guard LatticeOverlayLayoutPolicy.isSignificantChange(clamped, lastAppliedSize)
                || panel.frame.width < 1
                || panel.frame.height < 1 else { return }
        lastAppliedSize = clamped

        let current = LatticeOverlayLayoutPolicy.Rect(
            x: panel.frame.minX,
            y: panel.frame.minY,
            width: panel.frame.width,
            height: panel.frame.height
        )
        let next = LatticeOverlayLayoutPolicy.topAnchoredFrame(current: current, target: clamped, visible: visible)
        let frame = NSRect(x: next.x, y: next.y, width: next.width, height: next.height)

        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.allowsImplicitAnimation = true
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func preferredWidth(for mode: OverlayMode) -> Double {
        switch mode {
        case .idle: LatticeOverlayLayoutPolicy.preferredIdleWidth
        case .prompt, .context, .running, .result: LatticeOverlayLayoutPolicy.preferredStandardWidth
        case .compactChat: LatticeOverlayLayoutPolicy.preferredCompactChatWidth
        }
    }

    private func minimumSize(for mode: OverlayMode) -> LatticeOverlayLayoutPolicy.Size {
        switch mode {
        case .idle:
            return .init(
                width: LatticeOverlayLayoutPolicy.minimumIdleWidth,
                height: LatticeOverlayLayoutPolicy.minimumIdleHeight
            )
        case .compactChat:
            return .init(
                width: LatticeOverlayLayoutPolicy.minimumCompactChatWidth,
                height: LatticeOverlayLayoutPolicy.minimumCompactChatHeight
            )
        case .prompt, .context, .running, .result:
            return .init(
                width: LatticeOverlayLayoutPolicy.minimumStandardWidth,
                height: LatticeOverlayLayoutPolicy.minimumStandardHeight
            )
        }
    }

    /// State-derived ideal size used before the first content measurement (and as a safety net).
    /// Intentionally generous enough not to clip header + composer chrome; measurement tightens it.
    private func fallbackIdealSize(for mode: OverlayMode) -> LatticeOverlayLayoutPolicy.Size {
        let commandCount = state.appCommandSuggestions(for: state.draft).count
        let hasContinue = state.canContinueSelectedSession
        let hasAttachments = !state.attachments.isEmpty
        let hasSaveFailure = state.needsSessionSaveFailureAttention && !state.needsPersistenceRecovery
        let hasPermission = state.selectedSessionID.flatMap { state.harnessPermissionNotice(for: $0) } != nil
        let hasSelfEdit = state.selectedSessionID.map { !state.visibleSelfEditPreviews(for: $0).isEmpty } == true
        let saveFailureExtra: Double = {
            guard hasSaveFailure else { return 0 }
            return state.expandedSessionSaveFailureDetails ? 220 : 130
        }()

        // Outer padding (14×2) + prominent header row (40) + stack spacing before body (12).
        let chrome: Double = 28 + 40 + 12
        let attachmentBlock: Double = hasAttachments ? 36 + 8 : 0
        let commandBlock: Double = commandCount > 0 ? Double(min(commandCount, 8)) * 48 + 8 : 0
        let continueBlock: Double = hasContinue ? 30 + 8 : 0
        let composerRow: Double = 56

        switch mode {
        case .idle:
            var height = chrome + attachmentBlock + commandBlock + continueBlock + composerRow
            if hasSaveFailure { height += saveFailureExtra + 12 }
            return .init(width: LatticeOverlayLayoutPolicy.preferredIdleWidth, height: height)
        case .prompt, .context:
            var height = chrome + attachmentBlock + commandBlock + continueBlock + composerRow
            if hasSaveFailure { height += saveFailureExtra + 12 }
            return .init(width: LatticeOverlayLayoutPolicy.preferredStandardWidth, height: height)
        case .running:
            var height = chrome + (hasPermission ? 150 : composerRow)
            if hasSaveFailure { height += saveFailureExtra + 12 }
            return .init(width: LatticeOverlayLayoutPolicy.preferredStandardWidth, height: height)
        case .result:
            var height = chrome + (hasSelfEdit ? 300 : 130)
            if hasSaveFailure { height += saveFailureExtra + 12 }
            return .init(width: LatticeOverlayLayoutPolicy.preferredStandardWidth, height: height)
        case .compactChat:
            var height = chrome
                + LatticeOverlayLayoutPolicy.compactChatTranscriptIdeal
                + 12
                + attachmentBlock
                + commandBlock
                + continueBlock
                + composerRow
            if hasSaveFailure { height += saveFailureExtra + 12 }
            return .init(width: LatticeOverlayLayoutPolicy.preferredCompactChatWidth, height: height)
        }
    }

    private func makePanel() -> LatticePanel {
        let panel = LatticePanel(
            contentRect: .init(x: 0, y: 0, width: LatticeOverlayLayoutPolicy.preferredStandardWidth, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.contentView = NSHostingView(rootView: OverlayView(
            state: state,
            layoutMetrics: layoutMetrics,
            resize: { [weak self] mode, ideal in
                self?.resize(for: mode, idealContentSize: ideal)
            },
            dismiss: { [weak self] in self?.hide() },
            openCommandPalette: { [weak self] in self?.showCommandPaletteFromOverlay() },
            openWorkspace: { [weak self] in self?.showWorkspace() }
        ))
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        let visibleNS = placementVisibleFrame()
        let visible = LatticeOverlayLayoutPolicy.Rect(
            x: visibleNS.minX,
            y: visibleNS.minY,
            width: visibleNS.width,
            height: visibleNS.height
        )
        let topY = LatticeOverlayLayoutPolicy.preferredTopY(inVisibleFrame: visible)
        let maximum = LatticeOverlayLayoutPolicy.maximumSize(inVisibleFrame: visible, topY: topY)
        let preferred = LatticeOverlayLayoutPolicy.Size(
            width: panel.frame.width > 1 ? Double(panel.frame.width) : LatticeOverlayLayoutPolicy.preferredStandardWidth,
            height: panel.frame.height > 1 ? Double(panel.frame.height) : LatticeOverlayLayoutPolicy.minimumStandardHeight
        )
        let minimum = minimumSize(for: state.overlayMode)
        let clamped = LatticeOverlayLayoutPolicy.clamp(preferred: preferred, minimum: minimum, maximum: maximum)
        let centered = LatticeOverlayLayoutPolicy.Rect(
            x: visible.midX - clamped.width / 2,
            y: topY - clamped.height,
            width: clamped.width,
            height: clamped.height
        )
        let frame = LatticeOverlayLayoutPolicy.topAnchoredFrame(current: centered, target: clamped, visible: visible)
        lastAppliedSize = clamped
        panel.setFrame(NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height), display: false)
    }

    /// Screen under the cursor (initial placement).
    private func placementVisibleFrame() -> NSRect {
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    }

    /// Screen currently containing the panel, falling back to cursor/main.
    private func activeVisibleFrame(for panel: NSPanel) -> NSRect {
        if let screen = panel.screen {
            return screen.visibleFrame
        }
        return placementVisibleFrame()
    }

    private func fourCharCode(_ string: String) -> FourCharCode {
        string.utf8.reduce(0) { ($0 << 8) + FourCharCode($1) }
    }
}

final class LatticePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Overlay content

/// Layout probe for the floating overlay. Uses `ObservableObject` (not `@State`) so the
/// Command Line Tools / manual `swiftc` path can build without SwiftUI macro plugins.
@MainActor
final class OverlayLayoutMetrics: ObservableObject {
    @Published var measuredIdealSize: CGSize = .zero
    @Published var hostSize: CGSize = .zero
    @Published var measuredForMode: OverlayMode?

    func resetMeasurement() {
        measuredIdealSize = .zero
        measuredForMode = nil
    }
}

private struct OverlayIdealContentSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        // Prefer the largest reported ideal so nested readers cannot shrink the panel spuriously.
        value = CGSize(width: max(value.width, next.width), height: max(value.height, next.height))
    }
}

private struct OverlayHostSizeReader: View {
    @ObservedObject var metrics: OverlayLayoutMetrics

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { metrics.hostSize = geo.size }
                .onChange(of: geo.size) { _, newSize in metrics.hostSize = newSize }
        }
    }
}

private struct OverlayIdealSizeReader: View {
    var body: some View {
        GeometryReader { geo in
            Color.clear.preference(key: OverlayIdealContentSizeKey.self, value: geo.size)
        }
    }
}

struct OverlayView: View {
    @ObservedObject var state: AppState
    @ObservedObject var layoutMetrics: OverlayLayoutMetrics
    /// `(mode, measuredIdealSize?)` — pass measured size when known; `nil` triggers state-derived fallback.
    let resize: (OverlayMode, CGSize?) -> Void
    let dismiss: () -> Void
    let openCommandPalette: () -> Void
    let openWorkspace: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var contentNeedsScroll: Bool {
        let ideal = layoutMetrics.measuredIdealSize
        let host = layoutMetrics.hostSize
        guard ideal.height > 1, host.height > 1 else { return false }
        return ideal.height > host.height + CGFloat(LatticeOverlayLayoutPolicy.sizeChangeEpsilon)
    }

    private var transitionAnimation: Animation? {
        reduceMotion ? nil : .snappy(duration: 0.24)
    }

    private var commandSuggestionCount: Int {
        state.appCommandSuggestions(for: state.draft).count
    }

    var body: some View {
        panelChrome
            .latticeGlass(cornerRadius: state.cornerRadius(for: .overlay, default: 22), tint: state.tintColor(for: .overlay))
            .background(OverlayHostSizeReader(metrics: layoutMetrics))
            .onPreferenceChange(OverlayIdealContentSizeKey.self) { size in
                handleMeasuredIdealSize(size)
            }
            .onChange(of: state.overlayMode) { _, mode in
                layoutMetrics.resetMeasurement()
                resize(mode, nil)
            }
            .onChange(of: commandSuggestionCount) { _, _ in requestResizePreservingMeasurement() }
            .onChange(of: state.selfEditPreviews.count) { _, _ in requestResizePreservingMeasurement() }
            .onChange(of: state.harnessPermissionNotices.count) { _, _ in requestResizePreservingMeasurement() }
            .onChange(of: state.needsSessionSaveFailureAttention) { _, _ in requestResizePreservingMeasurement() }
            .onChange(of: state.expandedSessionSaveFailureDetails) { _, _ in requestResizePreservingMeasurement() }
            .onChange(of: state.attachments.count) { _, _ in requestResizePreservingMeasurement() }
            .onChange(of: state.canContinueSelectedSession) { _, _ in requestResizePreservingMeasurement() }
            .onChange(of: state.draft) { _, _ in requestResizePreservingMeasurement() }
            .animation(transitionAnimation, value: state.overlayMode)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(LatticeAccessibilityID.overlay)
            .accessibilityLabel("Lattice overlay")
            .alert("Delete from here?", isPresented: $state.showDeleteMessageConfirmation) {
                Button("Cancel", role: .cancel) { state.cancelPendingMessageDeletion() }
                Button("Delete", role: .destructive) { state.confirmPendingMessageDeletion() }
            } message: {
                Text("This removes this message and everything after it. This cannot be undone.")
            }
    }

    @ViewBuilder
    private var panelChrome: some View {
        if state.overlayMode == .compactChat {
            // Compact chat keeps ConversationView's own transcript scroll; outer scroll only on overflow.
            compactChatChrome
        } else {
            standardScrollableChrome
        }
    }

    private var standardScrollableChrome: some View {
        ScrollView(.vertical, showsIndicators: contentNeedsScroll) {
            overlayStack
        }
        .scrollDisabled(!contentNeedsScroll)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var compactChatChrome: some View {
        if contentNeedsScroll {
            ScrollView(.vertical, showsIndicators: true) {
                overlayStack
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            overlayStack
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var overlayStack: some View {
        VStack(spacing: 12) {
            headerRow
            if state.needsSessionSaveFailureAttention, !state.needsPersistenceRecovery {
                SessionSaveFailureView(state: state)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // Ideal height at the panel's width — independent of current panel height.
        .fixedSize(horizontal: false, vertical: true)
        .background(OverlayIdealSizeReader())
    }

    private var headerRow: some View {
        HStack {
            Text("Lattice").font(.caption).fontWeight(.semibold)
            Spacer()
            Button(action: openCommandPalette) {
                Image(systemName: "command")
            }
            .buttonStyle(LatticeIconButtonStyle(size: .prominent))
            .accessibilityIdentifier(LatticeAccessibilityID.overlayOpenCommandPalette)
            .accessibilityLabel("Open command palette")
            .help("Open command palette")
            Button(action: openWorkspace) {
                Image(systemName: "macwindow")
            }
            .buttonStyle(LatticeIconButtonStyle(size: .prominent))
            .accessibilityIdentifier(LatticeAccessibilityID.overlayOpenWorkspace)
            .accessibilityLabel("Open workspace")
            .help("Open workspace")
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(LatticeIconButtonStyle(size: .prominent))
            .accessibilityLabel("Dismiss")
            .help("Dismiss")
        }
    }

    private func handleMeasuredIdealSize(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        let previous = layoutMetrics.measuredIdealSize
        let epsilon = CGFloat(LatticeOverlayLayoutPolicy.sizeChangeEpsilon)
        let changed =
            abs(previous.width - size.width) >= epsilon
            || abs(previous.height - size.height) >= epsilon
            || layoutMetrics.measuredForMode != state.overlayMode
        guard changed else { return }
        layoutMetrics.measuredIdealSize = size
        layoutMetrics.measuredForMode = state.overlayMode
        resize(state.overlayMode, size)
    }

    private func requestResizePreservingMeasurement() {
        // Drop the view-side cache so the next layout reports a fresh ideal size.
        // Controller still reuses lastMeasuredMode-matched height until that pass arrives.
        layoutMetrics.resetMeasurement()
        resize(state.overlayMode, nil)
    }

    @ViewBuilder private var content: some View {
        switch state.overlayMode {
        case .idle, .prompt:
            VStack(spacing: 8) {
                AttachmentStrip(state: state)
                overlayComposer
            }
        case .context:
            VStack(spacing: 8) {
                AttachmentStrip(state: state)
                overlayComposer
            }
        case .running:
            if let sessionID = state.selectedSessionID,
               let notice = state.harnessPermissionNotice(for: sessionID) {
                HarnessPermissionNoticeRow(notice: notice, state: state)
            } else {
                overlayComposer
            }
        case .result:
            resultContent
        case .compactChat:
            compactChatContent
        }
    }

    @ViewBuilder private var resultContent: some View {
        if let sessionID = state.selectedSessionID,
           let preview = state.visibleSelfEditPreviews(for: sessionID).first {
            SelfEditPreviewRow(preview: preview, state: state)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(state.selectedSession?.messages.last?.text ?? "Finished.")
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Follow up") {
                        state.overlayMode = .prompt
                        state.overlayControlState = .expanded
                    }
                    Spacer()
                    Button("Expand Chat") { state.overlayMode = .compactChat }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var compactChatContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if state.isOverlayVisible {
                ConversationView(state: state, showsComposer: false)
                    .frame(height: compactTranscriptHeight)
                    .frame(maxWidth: .infinity)
                    .layoutPriority(1)
            }
            AttachmentStrip(state: state)
            overlayComposer
        }
        .frame(maxWidth: .infinity)
    }

    /// Keeps a useful transcript viewport; shrinks on short displays so composer/header stay reachable.
    private var compactTranscriptHeight: CGFloat {
        var reserved = 14.0 * 2 // outer padding
        reserved += 40 // prominent header
        reserved += 12 // header → body spacing
        if state.needsSessionSaveFailureAttention, !state.needsPersistenceRecovery {
            reserved += state.expandedSessionSaveFailureDetails ? 220 : 130
            reserved += 12
        }
        reserved += 12 // transcript → composer stack spacing
        if !state.attachments.isEmpty { reserved += 36 + 8 }
        if commandSuggestionCount > 0 { reserved += Double(min(commandSuggestionCount, 8)) * 48 + 8 }
        if state.canContinueSelectedSession { reserved += 30 + 8 }
        if !state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !state.canSendDraft,
           state.composerSubmitDisabledHelp != nil {
            reserved += 44 // visible route/setup blocker
        }
        reserved += 56 // composer row
        let height = LatticeOverlayLayoutPolicy.compactChatTranscriptHeight(
            hostHeight: Double(layoutMetrics.hostSize.height),
            reservedChromeHeight: reserved
        )
        return CGFloat(height)
    }

    private var overlayComposer: some View {
        VStack(spacing: 8) {
            let commands = state.appCommandSuggestions(for: state.draft)
            if !commands.isEmpty {
                AppCommandSuggestionList(commands: commands) { command in
                    state.insertAppCommand(command)
                }
            }
            if state.canContinueSelectedSession {
                HStack {
                    Spacer()
                    Button {
                        state.continueSelectedResponse()
                    } label: {
                        Label("Continue", systemImage: "arrow.turn.down.right")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Ask the current chat to continue from the last assistant response")
                }
            }
            if !state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !state.canSendDraft,
               let reason = state.composerSubmitDisabledHelp {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityLabel("Message cannot be sent")
                    .accessibilityValue(reason)
            }
            MorphingControl(
                state: $state.overlayControlState,
                text: $state.draft,
                compactTitle: state.copyText(for: .askButton, fallback: "Ask Lattice"),
                expandedPlaceholder: state.copyText(for: .promptPlaceholder, fallback: "What do you need?"),
                onSubmit: state.sendDraft,
                onStop: state.stop,
                onChooseFiles: state.chooseAttachments,
                onDropFiles: state.addAttachments,
                onDismissContext: { state.overlayControlState = .expanded; state.overlayMode = .prompt },
                isSubmitEnabled: state.canSendDraft,
                isStopEnabled: state.canStopSelectedSession,
                submitDisabledHelp: state.composerSubmitDisabledHelp,
                stopDisabledHelp: "No response is running",
                surfaceTint: state.tintColor(for: .composer) ?? state.tintColor(for: .overlay),
                surfaceCornerRadius: state.cornerRadius(for: .composer, default: 16)
            )
        }
    }
}
