import Foundation
import Testing
@testable import LatticeCore

@Suite("Run UI state")
struct RunUIStateTests {
    @Test("terminal transition for one session does not clear another run")
    func terminalTransitionIsSessionScoped() {
        let first = UUID()
        let second = UUID()
        let firstActivity = RunUIActivity(icon: "terminal", title: "First command", detail: "first")
        let secondActivity = RunUIActivity(icon: "pencil", title: "Second edit", detail: "second")
        var states = [first: RunUIState(), second: RunUIState()]

        reduce(.started, for: first, in: &states)
        reduce(.started, for: second, in: &states)
        reduce(.setActivity([firstActivity]), for: first, in: &states)
        reduce(.setActivity([secondActivity]), for: second, in: &states)
        reduce(.completed, for: first, in: &states)

        #expect(states[first]?.overlayMode == .result)
        #expect(states[first]?.composerState == .expanded)
        #expect(states[first]?.activity.isEmpty == true)
        #expect(states[second]?.overlayMode == .running)
        #expect(states[second]?.composerState == .progress(0.1))
        #expect(states[second]?.activity == [secondActivity])
    }

    @Test("failure preserves other session approval and activity UI")
    func failureIsSessionScoped() {
        let failed = UUID()
        let waiting = UUID()
        let waitingActivity = RunUIActivity(icon: "hand.raised.fill", title: "Approval", detail: "Waiting")
        var states = [failed: RunUIState(), waiting: RunUIState()]

        reduce(.started, for: failed, in: &states)
        reduce(.started, for: waiting, in: &states)
        reduce(.permissionRequested, for: waiting, in: &states)
        reduce(.setActivity([waitingActivity]), for: waiting, in: &states)
        reduce(.failed("Provider failed"), for: failed, in: &states)

        #expect(states[failed]?.overlayMode == .prompt)
        #expect(states[failed]?.errorMessage == "Provider failed")
        #expect(states[waiting]?.overlayMode == .running)
        #expect(states[waiting]?.composerState == .approval)
        #expect(states[waiting]?.overlayControlState == .approval)
        #expect(states[waiting]?.activity == [waitingActivity])
    }

    @Test("activity upsert keeps latest four items per session")
    func activityIsBoundedPerSession() {
        var state = RunUIState()
        let items = (0..<5).map { RunUIActivity(icon: "circle", title: "Item \($0)", detail: "detail") }

        for item in items {
            RunUIReducer.reduce(.upsertActivity(item), into: &state)
        }

        #expect(state.activity == Array(items.suffix(4)))
    }

    private func reduce(_ action: RunUIAction, for sessionID: UUID, in states: inout [UUID: RunUIState]) {
        var state = states[sessionID] ?? RunUIState()
        RunUIReducer.reduce(action, into: &state)
        states[sessionID] = state
    }
}
