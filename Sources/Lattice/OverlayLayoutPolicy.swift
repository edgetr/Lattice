import Foundation

// MARK: - Floating overlay panel sizing

/// Pure geometry rules for the Lattice floating overlay `NSPanel`.
///
/// Fixed mode heights clip the 40 pt header, composer, optional command list,
/// attachments, Continue, permission cards, and save-failure banner. Callers
/// measure (or estimate) ideal content size, then clamp with these helpers so
/// the panel stays on the active display, top-anchored, and scrollable when tall.
enum LatticeOverlayLayoutPolicy: Sendable {
    /// Preferred gap from the top of `visibleFrame` when first placing the panel.
    static let preferredTopInset: Double = 72

    /// Minimum clearance from the visible frame edges.
    static let edgeMargin: Double = 16

    /// Skip no-op resizes / PreferenceKey chatter below this delta (points).
    static let sizeChangeEpsilon: Double = 1

    /// Ideal compact-chat transcript viewport (matches historical overlay layout).
    static let compactChatTranscriptIdeal: Double = 330

    /// Floor for the compact-chat transcript when the display is short.
    static let compactChatTranscriptMinimum: Double = 160

    // MARK: Preferred widths (pre-clamp)

    static let preferredIdleWidth: Double = 230
    static let preferredStandardWidth: Double = 620
    static let preferredCompactChatWidth: Double = 650

    // MARK: Minimum sizes (pre-clamp, still subject to display max)

    static let minimumIdleWidth: Double = 200
    /// Idle renders the same chrome/composer content as prompt until `show()` promotes it.
    static let minimumIdleHeight: Double = 100
    static let minimumStandardWidth: Double = 320
    /// Header (40) + padding (28) + spacing + a single composer row — never smaller.
    static let minimumStandardHeight: Double = 100
    static let minimumCompactChatWidth: Double = 360
    /// Header + useful transcript floor + composer chrome.
    static let minimumCompactChatHeight: Double = 320

    struct Size: Equatable, Sendable {
        var width: Double
        var height: Double

        init(width: Double, height: Double) {
            self.width = width
            self.height = height
        }
    }

    struct Rect: Equatable, Sendable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        var minX: Double { x }
        var minY: Double { y }
        var maxX: Double { x + width }
        var maxY: Double { y + height }
        var midX: Double { x + width / 2 }
    }

    /// Maximum panel size that fits inside `visibleFrame`, leaving edge margins and
    /// room under a top-anchored origin at `topY` (panel `maxY`).
    static func maximumSize(
        inVisibleFrame visible: Rect,
        topY: Double
    ) -> Size {
        let maxWidth = max(0, visible.width - edgeMargin * 2)
        // Keep the top edge at `topY` when possible; height may not extend below the bottom margin.
        let bottomLimit = visible.minY + edgeMargin
        let maxHeightFromTop = max(0, topY - bottomLimit)
        // Also never exceed the usable visible height (defensive if topY is off-screen).
        let maxHeightFromFrame = max(0, visible.height - edgeMargin * 2)
        return Size(width: maxWidth, height: min(maxHeightFromTop, maxHeightFromFrame))
    }

    /// Initial placement top (`maxY`) for a newly shown overlay on `visibleFrame`.
    static func preferredTopY(inVisibleFrame visible: Rect) -> Double {
        visible.maxY - preferredTopInset
    }

    static func clamp(
        preferred: Size,
        minimum: Size,
        maximum: Size
    ) -> Size {
        // If the display is smaller than the design minimum, prefer fitting the display.
        let effectiveMinWidth = min(minimum.width, maximum.width)
        let effectiveMinHeight = min(minimum.height, maximum.height)
        let width = min(max(preferred.width, effectiveMinWidth), max(effectiveMinWidth, maximum.width))
        let height = min(max(preferred.height, effectiveMinHeight), max(effectiveMinHeight, maximum.height))
        return Size(width: width, height: height)
    }

    /// Whether two sizes differ enough to warrant applying a panel frame change.
    static func isSignificantChange(_ a: Size, _ b: Size) -> Bool {
        abs(a.width - b.width) >= sizeChangeEpsilon || abs(a.height - b.height) >= sizeChangeEpsilon
    }

    /// Resize while preserving the top edge (`maxY`), then clamp into `visibleFrame`.
    ///
    /// Horizontal position keeps the previous center when possible. If the panel
    /// would extend past the bottom margin, height is assumed already clamped by
    /// `maximumSize`; this still nudges origin so the frame stays on-screen.
    static func topAnchoredFrame(
        current: Rect,
        target: Size,
        visible: Rect
    ) -> Rect {
        let preservedTop = current.maxY
        var frame = Rect(
            x: current.midX - target.width / 2,
            y: preservedTop - target.height,
            width: target.width,
            height: target.height
        )

        // Horizontal: keep fully inside visible frame.
        let minX = visible.minX + edgeMargin
        let maxX = visible.maxX - edgeMargin - frame.width
        if maxX < minX {
            // Narrower than panel + margins: center in the visible frame.
            frame.x = visible.minX + (visible.width - frame.width) / 2
        } else {
            frame.x = min(max(frame.x, minX), maxX)
        }

        // Vertical: prefer preserved top; if top itself is outside, pull into range.
        let minY = visible.minY + edgeMargin
        let maxTop = visible.maxY - edgeMargin
        var top = frame.maxY
        if top > maxTop { top = maxTop }
        frame.y = top - frame.height
        if frame.y < minY {
            frame.y = minY
            // If still too tall after y clamp, caller should have clamped height; keep top ≤ maxTop.
            if frame.maxY > maxTop {
                frame.y = max(minY, maxTop - frame.height)
            }
        }

        return frame
    }

    /// Adaptive compact-chat transcript height so composer/header stay on-screen.
    ///
    /// - Parameters:
    ///   - hostHeight: Current panel content height (0 → use ideal).
    ///   - reservedChromeHeight: Header, padding, composer, attachments, banners, spacing.
    static func compactChatTranscriptHeight(
        hostHeight: Double,
        reservedChromeHeight: Double
    ) -> Double {
        guard hostHeight > 0 else { return compactChatTranscriptIdeal }
        let available = hostHeight - max(0, reservedChromeHeight)
        if available <= 0 { return compactChatTranscriptMinimum }
        return min(compactChatTranscriptIdeal, max(compactChatTranscriptMinimum, available))
    }
}
