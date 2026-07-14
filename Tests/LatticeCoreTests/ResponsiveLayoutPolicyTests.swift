import Testing
@testable import LatticeCore

@Suite("Responsive layout policy")
struct ResponsiveLayoutPolicyTests {
    @Test func narrowPageUsesCompactInsets() {
        #expect(LatticeResponsiveLayoutPolicy.horizontalPadding(forAvailableWidth: 640) == 16)
        #expect(LatticeResponsiveLayoutPolicy.contentWidth(forAvailableWidth: 640) == 608)
    }

    @Test func regularPageUsesComfortableInsets() {
        #expect(LatticeResponsiveLayoutPolicy.horizontalPadding(forAvailableWidth: 900) == 24)
        #expect(LatticeResponsiveLayoutPolicy.contentWidth(forAvailableWidth: 900) == 852)
    }

    @Test func widePageCapsReadingRegion() {
        #expect(LatticeResponsiveLayoutPolicy.horizontalPadding(forAvailableWidth: 1_600) == 32)
        #expect(LatticeResponsiveLayoutPolicy.contentWidth(forAvailableWidth: 1_600) == 1_280)
    }

    @Test func unknownWidthHasStableFirstLayout() {
        #expect(LatticeResponsiveLayoutPolicy.contentWidth(forAvailableWidth: 0) == 900)
    }

    @Test func sectionsOnlySplitAtComfortableWidth() {
        #expect(!LatticeResponsiveLayoutPolicy.usesSideBySideSections(forContentWidth: 1_039))
        #expect(LatticeResponsiveLayoutPolicy.usesSideBySideSections(forContentWidth: 1_040))
    }

    @Test func cardsDoNotCompressBelowTheirMinimums() {
        #expect(!LatticeResponsiveLayoutPolicy.canFitMultipleCards(contentWidth: 693, minimumCardWidth: 340))
        #expect(LatticeResponsiveLayoutPolicy.canFitMultipleCards(contentWidth: 694, minimumCardWidth: 340))
    }
}
