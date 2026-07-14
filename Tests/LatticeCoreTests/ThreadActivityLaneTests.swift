import Foundation
import Testing
@testable import LatticeCore

@Suite("Thread activity lanes")
struct ThreadActivityLaneTests {
    @Test("concurrent threads transition independently")
    func concurrentTransitionsAreIsolated() {
        let code = UUID()
        let work = UUID()
        var store = ThreadActivityLaneStore(selectedSessionID: code)

        store.apply(.started, to: code)
        store.apply(.started, to: work)
        store.apply(.approvalRequested, to: work)
        store.apply(.completed, to: code)

        #expect(store.lane(for: code).status == .completed)
        #expect(!store.lane(for: code).hasUnreadActivity)
        #expect(store.lane(for: work).status == .waitingForApproval)
        #expect(store.lane(for: work).requiresAttention)
        #expect(store.lane(for: work).hasUnreadActivity)
    }

    @Test("selection clears only that thread unread indicator")
    func selectionChangesAreScoped() {
        let first = UUID()
        let second = UUID()
        var store = ThreadActivityLaneStore()
        store.apply(.completed, to: first)
        store.apply(.failed("Provider unavailable"), to: second)

        store.select(first)

        #expect(!store.lane(for: first).hasUnreadActivity)
        #expect(store.lane(for: second).hasUnreadActivity)
        #expect(store.lane(for: second).requiresAttention)
        #expect(store.lane(for: second).failureMessage == "Provider unavailable")
    }

    @Test("cancellation does not alter another active thread")
    func cancellationIsIsolated() {
        let cancelled = UUID()
        let running = UUID()
        var store = ThreadActivityLaneStore(selectedSessionID: running)
        store.apply(.started, to: cancelled)
        store.apply(.started, to: running)

        store.apply(.cancelled, to: cancelled)

        #expect(store.lane(for: cancelled).status == .cancelled)
        #expect(store.lane(for: cancelled).hasUnreadActivity)
        #expect(store.lane(for: running).status == .running)
        #expect(!store.lane(for: running).hasUnreadActivity)
    }

    @Test("queued work stays visible across a run")
    func queuedCountSurvivesRunTransitions() {
        let sessionID = UUID()
        var store = ThreadActivityLaneStore()
        store.apply(.queued(2), to: sessionID)
        store.apply(.priorityChanged(.high), to: sessionID)
        store.apply(.queuePositionChanged(3), to: sessionID)
        #expect(store.lane(for: sessionID).status == .queued)
        #expect(store.lane(for: sessionID).priority == .high)
        #expect(store.lane(for: sessionID).queuePosition == 3)

        store.apply(.started, to: sessionID)
        #expect(store.lane(for: sessionID).status == .running)
        #expect(store.lane(for: sessionID).queuedCount == 2)
        #expect(store.lane(for: sessionID).queuePosition == nil)

        store.apply(.completed, to: sessionID)
        #expect(store.lane(for: sessionID).status == .queued)
    }
}
