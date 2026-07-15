import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit
import LatticeCore

struct ScreenshotCaptureContext: Sendable {
    let applicationName: String?
    let bundleIdentifier: String?
    let windowTitle: String?
    let accessibilityText: String?
    let accessibilityAuthorized: Bool
}

struct ScreenshotCaptureResult: Sendable {
    let data: Data
    let source: ContextAttachmentImageSource
    let context: ScreenshotCaptureContext
}

enum ScreenshotCaptureServiceError: LocalizedError {
    case permissionRequired
    case noWindow
    case cancelled
    case captureFailed

    var errorDescription: String? {
        switch self {
        case .permissionRequired: "Screen Recording permission is required. Enable Lattice in System Settings → Privacy & Security → Screen & System Audio Recording."
        case .noWindow: "No capturable app window is visible."
        case .cancelled: "Screenshot capture was cancelled."
        case .captureFailed: "The screenshot could not be captured."
        }
    }
}

@MainActor
final class ScreenshotCaptureService {
    var screenRecordingStatus: ScreenRecordingPermissionStatus {
        CGPreflightScreenCaptureAccess() ? .authorized : .notDetermined
    }

    var accessibilityStatus: AccessibilityPermissionStatus {
        AXIsProcessTrusted() ? .authorized : .notDetermined
    }

    func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    func requestAccessibilityPermission() -> Bool {
        // Use the documented CFString key value rather than the non-Sendable global
        // `kAXTrustedCheckOptionPrompt` (Swift 6 concurrency diagnostics on CI).
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func captureFrontmostWindow(includeContext: Bool) async throws -> ScreenshotCaptureResult {
        guard CGPreflightScreenCaptureAccess() else { throw ScreenshotCaptureServiceError.permissionRequired }
        let shareable = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = Self.frontmostShareableWindow(from: shareable) else { throw ScreenshotCaptureServiceError.noWindow }

        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(window.frame.width * 2))
        configuration.height = max(1, Int(window.frame.height * 2))
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window),
            configuration: configuration
        )
        guard let data = Self.pngData(image) else { throw ScreenshotCaptureServiceError.captureFailed }
        let app = window.owningApplication
        let context = includeContext
            ? captureContext(pid: app?.processID, applicationName: app?.applicationName, bundleID: app?.bundleIdentifier, windowTitle: window.title)
            : .empty
        return ScreenshotCaptureResult(data: data, source: .windowCapture, context: context)
    }

    func captureRegion(includeContext: Bool) async throws -> ScreenshotCaptureResult {
        guard CGPreflightScreenCaptureAccess() else { throw ScreenshotCaptureServiceError.permissionRequired }
        guard let selection = await RegionSelectionController.select() else { throw ScreenshotCaptureServiceError.cancelled }
        let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = shareable.displays.first(where: { $0.displayID == selection.screenNumber }) else {
            throw ScreenshotCaptureServiceError.captureFailed
        }
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, display.width)
        configuration.height = max(1, display.height)
        configuration.showsCursor = true
        let fullImage = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: []),
            configuration: configuration
        )
        let screenFrame = selection.screenFrame
        let scaleX = CGFloat(fullImage.width) / screenFrame.width
        let scaleY = CGFloat(fullImage.height) / screenFrame.height
        let local = selection.rect.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        let crop = CGRect(
            x: local.minX * scaleX,
            y: (screenFrame.height - local.maxY) * scaleY,
            width: local.width * scaleX,
            height: local.height * scaleY
        ).integral
        guard crop.width > 1, crop.height > 1, let image = fullImage.cropping(to: crop), let data = Self.pngData(image) else {
            throw ScreenshotCaptureServiceError.captureFailed
        }
        let context = includeContext ? captureContextForTopWindow(at: selection.rect) : .empty
        return ScreenshotCaptureResult(data: data, source: .regionCapture, context: context)
    }

    private func captureContextForTopWindow(at rect: CGRect) -> ScreenshotCaptureContext {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let windows = CGWindowListCopyWindowInfo(options, CGWindowID(0)) as? [[String: Any]] ?? []
        guard let item = windows.first(where: { value in
            guard (value[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = value[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"] else { return false }
            return CGRect(x: x, y: y, width: width, height: height).intersects(rect)
        }) else { return .empty }
        let pid = (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
        let app = pid.flatMap { NSRunningApplication(processIdentifier: $0) }
        return captureContext(
            pid: pid,
            applicationName: app?.localizedName,
            bundleID: app?.bundleIdentifier,
            windowTitle: item[kCGWindowName as String] as? String
        )
    }

    private static func frontmostShareableWindow(from content: SCShareableContent) -> SCWindow? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let windows = CGWindowListCopyWindowInfo(options, CGWindowID(0)) as? [[String: Any]] ?? []
        for value in windows {
            guard (value[kCGWindowLayer as String] as? Int) == 0,
                  let number = (value[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let ownerPID = (value[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  ownerPID != ProcessInfo.processInfo.processIdentifier,
                  let window = content.windows.first(where: {
                      $0.windowID == CGWindowID(number) && $0.isOnScreen && $0.windowLayer == 0
                  }) else { continue }
            return window
        }
        return content.windows.first {
            $0.isOnScreen && $0.windowLayer == 0 && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier
        }
    }

    private func captureContext(pid: pid_t?, applicationName: String?, bundleID: String?, windowTitle: String?) -> ScreenshotCaptureContext {
        guard let pid else {
            return ScreenshotCaptureContext(applicationName: applicationName, bundleIdentifier: bundleID, windowTitle: windowTitle, accessibilityText: nil, accessibilityAuthorized: false)
        }
        let authorized = AXIsProcessTrusted()
        let text = authorized ? Self.accessibilitySummary(pid: pid) : nil
        return ScreenshotCaptureContext(
            applicationName: applicationName,
            bundleIdentifier: bundleID,
            windowTitle: windowTitle,
            accessibilityText: text,
            accessibilityAuthorized: authorized
        )
    }

    private static func accessibilitySummary(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let window = focused else { return nil }
        guard CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(window, to: AXUIElement.self)
        let attributes = [kAXTitleAttribute, kAXRoleDescriptionAttribute, kAXDescriptionAttribute, kAXValueAttribute]
        let values = attributes.compactMap { attribute -> String? in
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
            return value as? String
        }
        let joined = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n")
        return joined.isEmpty ? nil : String(joined.prefix(ContextAttachmentImageMetadata.maxAccessibilityTextLength))
    }

    private static func pngData(_ image: CGImage) -> Data? {
        let representation = NSBitmapImageRep(cgImage: image)
        return representation.representation(using: .png, properties: [:])
    }
}

private extension ScreenshotCaptureContext {
    static let empty = ScreenshotCaptureContext(
        applicationName: nil,
        bundleIdentifier: nil,
        windowTitle: nil,
        accessibilityText: nil,
        accessibilityAuthorized: false
    )
}

private struct RegionSelection {
    let rect: CGRect
    let screenFrame: CGRect
    let screenNumber: CGDirectDisplayID
}

@MainActor
private final class RegionSelectionController: NSObject {
    private var panel: NSPanel?
    private var continuation: CheckedContinuation<RegionSelection?, Never>?

    static func select() async -> RegionSelection? {
        await withCheckedContinuation { continuation in
            let controller = RegionSelectionController()
            controller.continuation = continuation
            controller.present()
        }
    }

    private func present() {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main else {
            finish(nil); return
        }
        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = RegionSelectionView { [self, weak screen] rect in
            guard let screen, let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                finish(nil); return
            }
            finish(rect.map { RegionSelection(rect: $0, screenFrame: screen.frame, screenNumber: number.uint32Value) })
        }
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        NSCursor.crosshair.push()
    }

    private func finish(_ result: RegionSelection?) {
        NSCursor.pop()
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        continuation?.resume(returning: result)
        continuation = nil
    }
}

private final class RegionSelectionView: NSView {
    private let completion: (CGRect?) -> Void
    private var start: CGPoint?
    private var current: CGPoint?

    init(completion: @escaping (CGRect?) -> Void) {
        self.completion = completion
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { completion(nil) } else { super.keyDown(with: event) }
    }
    override func mouseDown(with event: NSEvent) { start = convert(event.locationInWindow, from: nil); current = start; needsDisplay = true }
    override func mouseDragged(with event: NSEvent) { current = convert(event.locationInWindow, from: nil); needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        guard let selection = selectionRect, selection.width >= 8, selection.height >= 8, let window else { completion(nil); return }
        completion(window.convertToScreen(selection))
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill(); bounds.fill()
        guard let selectionRect else { return }
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(rect: selectionRect).addClip()
        NSColor.clear.setFill(); selectionRect.fill(using: .copy)
        NSGraphicsContext.current?.restoreGraphicsState()
        NSColor.systemPink.setStroke()
        let outline = NSBezierPath(rect: selectionRect); outline.lineWidth = 2; outline.stroke()
    }
    private var selectionRect: CGRect? {
        guard let start, let current else { return nil }
        return CGRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(current.x - start.x), height: abs(current.y - start.y))
    }
}
