import Foundation
import Testing
@testable import LatticeCore

@Suite("Interactive process ownership")
struct InteractiveProcessRegistryTests {
    private var request: BoundedSubprocessRequest {
        BoundedSubprocessRequest(executableURL: URL(fileURLWithPath: "/bin/sh"), deadline: 1)
    }

    @Test func staleRunCannotUnregisterReplacement() {
        let registry = InteractiveProcessRegistry()
        let sessionID = UUID()
        let first = BoundedProcessTransport(request: request)
        let second = BoundedProcessTransport(request: request)

        guard case .accepted(let firstOwner) = registry.register(process: first, input: nil, for: sessionID, start: registry.beginStart(for: sessionID)),
              case .accepted(let secondOwner) = registry.register(process: second, input: nil, for: sessionID, start: registry.beginStart(for: sessionID)) else {
            Issue.record("Both runs should register")
            return
        }

        #expect(!registry.unregister(firstOwner, sessionID: sessionID).removedCurrentOwner)
        #expect(registry.unregister(secondOwner, sessionID: sessionID).removedCurrentOwner)
    }

    @Test func cancellationBeforeRegistrationRejectsRun() {
        let registry = InteractiveProcessRegistry()
        let sessionID = UUID()
        let start = registry.beginStart(for: sessionID)
        _ = registry.cancel(sessionID: sessionID)

        let result = registry.register(process: BoundedProcessTransport(request: request), input: nil, for: sessionID, start: start)
        guard case .cancelled = result else {
            Issue.record("Pre-registration cancellation must reject the run")
            return
        }
        #expect(registry.abandonStart(start, sessionID: sessionID) == false)
    }

    @Test func abandonedStartDoesNotLeakIntoLaterCancellation() {
        let registry = InteractiveProcessRegistry()
        let sessionID = UUID()
        let abandoned = registry.beginStart(for: sessionID)
        #expect(!registry.abandonStart(abandoned, sessionID: sessionID))
        _ = registry.cancel(sessionID: sessionID)

        let next = registry.beginStart(for: sessionID)
        let result = registry.register(
            process: BoundedProcessTransport(request: request),
            input: nil,
            for: sessionID,
            start: next
        )
        guard case .accepted(let owner) = result else {
            Issue.record("A later start must not inherit cancellation from an abandoned run")
            return
        }
        #expect(!registry.unregister(owner, sessionID: sessionID).wasCancelled)
    }

    @Test func cancelOldThenImmediateReplacementIsAccepted() {
        let registry = InteractiveProcessRegistry()
        let sessionID = UUID()
        let first = BoundedProcessTransport(request: request)
        let second = BoundedProcessTransport(request: request)
        guard case .accepted(let firstOwner) = registry.register(process: first, input: nil, for: sessionID, start: registry.beginStart(for: sessionID)) else {
            Issue.record("First run should register")
            return
        }

        _ = registry.cancel(sessionID: sessionID)
        guard case .accepted(let secondOwner) = registry.register(process: second, input: nil, for: sessionID, start: registry.beginStart(for: sessionID)) else {
            Issue.record("Replacement must not consume cancellation aimed at the old owner")
            return
        }

        #expect(registry.unregister(firstOwner, sessionID: sessionID).wasCancelled)
        #expect(registry.unregister(secondOwner, sessionID: sessionID).removedCurrentOwner)
    }

    @Test func staleOwnerCannotEraseReplacementMetadata() {
        let registry = InteractiveProcessRegistry()
        let sessionID = UUID()
        guard case .accepted(let firstOwner) = registry.register(
            process: BoundedProcessTransport(request: request),
            input: nil,
            for: sessionID,
            start: registry.beginStart(for: sessionID)
        ), case .accepted(let secondOwner) = registry.register(
            process: BoundedProcessTransport(request: request),
            input: nil,
            for: sessionID,
            start: registry.beginStart(for: sessionID)
        ) else {
            Issue.record("Both owners should register")
            return
        }
        let permissionID = UUID()
        #expect(registry.updateMetadata(secondOwner, sessionID: sessionID) {
            $0.threadID = "replacement-thread"
            $0.turnID = "replacement-turn"
            $0.providerSessionID = "replacement-acp"
            $0.pendingPermissionIDs = [permissionID]
        })

        #expect(!registry.unregister(firstOwner, sessionID: sessionID).removedCurrentOwner)
        #expect(registry.metadata(for: secondOwner, sessionID: sessionID) == .init(
            threadID: "replacement-thread",
            turnID: "replacement-turn",
            providerSessionID: "replacement-acp",
            pendingPermissionIDs: [permissionID]
        ))
    }

    @Test func permissionRegistrationRejectsAlreadyCancelledOwner() {
        let registry = InteractiveProcessRegistry()
        let sessionID = UUID()
        guard case .accepted(let owner) = registry.register(
            process: BoundedProcessTransport(request: request),
            input: nil,
            for: sessionID,
            start: registry.beginStart(for: sessionID)
        ) else {
            Issue.record("Owner should register")
            return
        }
        _ = registry.cancel(sessionID: sessionID)
        #expect(!registry.registerPendingPermission(UUID(), owner: owner, sessionID: sessionID))
    }

    @Test func permissionHandoffDetectsCancellationBetweenRegistryAndLocalStore() {
        let registry = InteractiveProcessRegistry()
        let sessionID = UUID()
        guard case .accepted(let owner) = registry.register(
            process: BoundedProcessTransport(request: request),
            input: nil,
            for: sessionID,
            start: registry.beginStart(for: sessionID)
        ) else {
            Issue.record("Owner should register")
            return
        }
        let requestID = UUID()
        #expect(registry.registerPendingPermission(requestID, owner: owner, sessionID: sessionID))

        // This is the exact handoff boundary: registry metadata exists, while
        // the harness-local waiter insertion has not yet completed.
        let target = registry.cancel(sessionID: sessionID)
        #expect(target.metadata.pendingPermissionIDs.contains(requestID))
        #expect(!registry.isPendingPermissionActive(requestID, owner: owner, sessionID: sessionID))
    }

    @Test func unscopedCancelMarksActiveOwnerAndAlreadyReservedReplacement() {
        let registry = InteractiveProcessRegistry()
        let sessionID = UUID()
        let activeStart = registry.beginStart(for: sessionID)
        guard case .accepted(let activeOwner) = registry.register(
            process: BoundedProcessTransport(request: request),
            input: nil,
            for: sessionID,
            start: activeStart
        ) else {
            Issue.record("Active run should register")
            return
        }
        let replacementStart = registry.beginStart(for: sessionID)

        _ = registry.cancel(sessionID: sessionID)

        #expect(registry.unregister(activeOwner, sessionID: sessionID).wasCancelled)
        guard case .cancelled = registry.register(
            process: BoundedProcessTransport(request: request),
            input: nil,
            for: sessionID,
            start: replacementStart
        ) else {
            Issue.record("Already-reserved replacement must observe cancellation")
            return
        }
    }

    @Test func staleTokenCancellationCannotCancelReplacementOwner() {
        let registry = InteractiveProcessRegistry()
        let sessionID = UUID()
        let staleStart = registry.beginStart(for: sessionID)
        guard case .accepted(let staleOwner) = registry.register(
            process: BoundedProcessTransport(request: request),
            input: nil,
            for: sessionID,
            start: staleStart
        ) else {
            Issue.record("Stale run should register")
            return
        }
        let replacementStart = registry.beginStart(for: sessionID)
        guard case .accepted(let replacementOwner) = registry.register(
            process: BoundedProcessTransport(request: request),
            input: nil,
            for: sessionID,
            start: replacementStart
        ) else {
            Issue.record("Replacement should register")
            return
        }

        let staleTarget = registry.cancel(sessionID: sessionID, start: staleStart)
        #expect(staleTarget.process == nil)
        #expect(registry.unregister(staleOwner, sessionID: sessionID).wasCancelled)
        let replacementResult = registry.unregister(replacementOwner, sessionID: sessionID)
        #expect(replacementResult.removedCurrentOwner)
        #expect(!replacementResult.wasCancelled)
    }

    @Test func scopedCancellationRejectsOnlyMatchingPendingStart() {
        let registry = InteractiveProcessRegistry()
        let sessionID = UUID()
        let cancelledStart = registry.beginStart(for: sessionID)
        let survivingStart = registry.beginStart(for: sessionID)
        _ = registry.cancel(sessionID: sessionID, start: cancelledStart)

        guard case .cancelled = registry.register(
            process: BoundedProcessTransport(request: request),
            input: nil,
            for: sessionID,
            start: cancelledStart
        ) else {
            Issue.record("Matching pending start must be cancelled")
            return
        }
        guard case .accepted(let owner) = registry.register(
            process: BoundedProcessTransport(request: request),
            input: nil,
            for: sessionID,
            start: survivingStart
        ) else {
            Issue.record("Unrelated pending start must survive scoped cancellation")
            return
        }
        #expect(registry.unregister(owner, sessionID: sessionID).removedCurrentOwner)
    }
}
