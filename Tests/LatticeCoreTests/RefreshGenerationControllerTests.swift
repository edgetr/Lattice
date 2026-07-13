import Testing
@testable import LatticeCore

@Suite("Refresh generations")
struct RefreshGenerationControllerTests {
    @Test func onlyNewestGenerationCanPublishOrFinish() {
        let controller = RefreshGenerationController()
        let older = controller.begin()
        let newer = controller.begin()

        #expect(!controller.isCurrent(older))
        #expect(controller.isCurrent(newer))
    }

    @Test func currentGenerationRemainsValidUntilSuperseded() {
        let controller = RefreshGenerationController()
        let generation = controller.begin()

        #expect(controller.isCurrent(generation))
        #expect(controller.isCurrent(generation))

        _ = controller.begin()
        #expect(!controller.isCurrent(generation))
    }
}
