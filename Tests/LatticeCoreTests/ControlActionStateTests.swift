import Testing
@testable import LatticeCore

@Suite("Control action dispatch")
struct ControlActionStateTests {
    @Test func dispatchesOnceWhileRunning() {
        var state = ControlActionState()

        #expect(state.begin(progressMessage: "Checking…"))
        #expect(!state.begin(progressMessage: "Checking again…"))
        #expect(state.phase == .running)
        #expect(state.message == "Checking…")
    }

    @Test func disabledPrerequisiteDoesNotDispatch() {
        var state = ControlActionState()

        #expect(!state.begin(progressMessage: "Checking…", disabledReason: "Runtime is unavailable"))
        #expect(state.phase == .idle)
        #expect(state.message == nil)
    }

    @Test func reportsSuccessAndAllowsAnotherDispatch() {
        var state = ControlActionState()
        #expect(state.begin(progressMessage: "Checking…"))

        state.succeed("Ready")

        #expect(state.phase == .succeeded)
        #expect(state.message == "Ready")
        #expect(state.begin(progressMessage: "Checking again…"))
        #expect(state.phase == .running)
    }

    @Test func reportsFailureAndRecoversOnRetry() {
        var state = ControlActionState()
        #expect(state.begin(progressMessage: "Checking…"))

        state.fail("Catalog unavailable")

        #expect(state.phase == .failed)
        #expect(state.message == "Catalog unavailable")
        #expect(state.begin(progressMessage: "Retrying…"))
        state.succeed("Recovered")
        #expect(state.phase == .succeeded)
        #expect(state.message == "Recovered")
    }

    @Test func staleCompletionCannotOverwriteIdleState() {
        var state = ControlActionState()

        state.succeed("Unexpected")
        state.fail("Unexpected")

        #expect(state.phase == .idle)
        #expect(state.message == nil)
    }
}
