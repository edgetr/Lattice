import Testing
@testable import LatticeCore

@Suite("Control action dispatch")
struct ControlActionStateTests {
    @Test func dispatchesOnceWhileRunning() {
        var state = ControlActionState()

        let first = state.begin(progressMessage: "Checking…")
        let second = state.begin(progressMessage: "Checking again…")
        #expect(first)
        #expect(!second)
        #expect(state.phase == .running)
        #expect(state.message == "Checking…")
    }

    @Test func disabledPrerequisiteDoesNotDispatch() {
        var state = ControlActionState()

        let began = state.begin(progressMessage: "Checking…", disabledReason: "Runtime is unavailable")
        #expect(!began)
        #expect(state.phase == .idle)
        #expect(state.message == nil)
    }

    @Test func reportsSuccessAndAllowsAnotherDispatch() {
        var state = ControlActionState()
        let first = state.begin(progressMessage: "Checking…")
        #expect(first)

        state.succeed("Ready")

        #expect(state.phase == .succeeded)
        #expect(state.message == "Ready")
        let second = state.begin(progressMessage: "Checking again…")
        #expect(second)
        #expect(state.phase == .running)
    }

    @Test func reportsFailureAndRecoversOnRetry() {
        var state = ControlActionState()
        let first = state.begin(progressMessage: "Checking…")
        #expect(first)

        state.fail("Catalog unavailable")

        #expect(state.phase == .failed)
        #expect(state.message == "Catalog unavailable")
        let retry = state.begin(progressMessage: "Retrying…")
        #expect(retry)
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
