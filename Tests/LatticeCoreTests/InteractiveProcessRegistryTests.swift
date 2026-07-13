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
}
