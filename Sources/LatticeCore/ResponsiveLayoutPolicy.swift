import Foundation

/// Pure presentation breakpoints shared by the catalog-style pages.
/// Values are based on the available content region, never the display size.
public enum LatticeResponsiveLayoutPolicy: Sendable {
    public static let comfortableContentWidth = 900.0
    public static let maximumContentWidth = 1_280.0
    public static let sideBySideSectionBreakpoint = 1_040.0
    public static let cardSpacing = 14.0

    public static func horizontalPadding(forAvailableWidth width: Double) -> Double {
        if width > 0, width < 720 { return 16 }
        if width > 0, width < 1_100 { return 24 }
        return 32
    }

    public static func contentWidth(forAvailableWidth width: Double) -> Double {
        guard width > 0 else { return comfortableContentWidth }
        let usable = width - horizontalPadding(forAvailableWidth: width) * 2
        return min(max(usable, 0), maximumContentWidth)
    }

    public static func usesSideBySideSections(forContentWidth width: Double) -> Bool {
        width >= sideBySideSectionBreakpoint
    }

    public static func canFitMultipleCards(
        contentWidth: Double,
        minimumCardWidth: Double
    ) -> Bool {
        contentWidth >= minimumCardWidth * 2 + cardSpacing
    }
}
