import Foundation
import Testing
@testable import LatticeCore

@Suite("Agent task scheduler")
struct AgentTaskSchedulerTests {
    private func request(
        _ sessionID: UUID = UUID(),
        workspace: String = "workspace-a",
        provider: String = "codex",
        route: String = "codex/openai",
        priority: AgentTaskPriority = .normal,
        sensitivity: AgentTaskRecoverySensitivity = .ordinary
    ) -> AgentTaskSchedulerRequest {
        AgentTaskSchedulerRequest(
            id: sessionID,
            sessionID: sessionID,
            resources: .init(workspaceID: workspace, providerID: provider, routeID: route),
            priority: priority,
            recoverySensitivity: sensitivity
        )
    }

    @Test("global workspace provider and route caps are enforced")
    func resourceLimits() {
        var scheduler = AgentTaskScheduler(limits: .init(
            global: 3,
            perWorkspace: 1,
            providerCaps: ["codex": 1],
            routeCaps: ["ollama/local": 1]
        ))
        let first = UUID(), sameWorkspace = UUID(), sameProvider = UUID()
        let local = UUID(), sameRoute = UUID(), independent = UUID()

        let admittedFirst = scheduler.submit(request(first))
        let blockedWorkspace = scheduler.submit(request(sameWorkspace, provider: "grok", route: "grok/xai"))
        let blockedProvider = scheduler.submit(request(sameProvider, workspace: "workspace-b"))
        let admittedLocal = scheduler.submit(request(local, workspace: "workspace-c", provider: "ollama", route: "ollama/local"))
        let blockedRoute = scheduler.submit(request(sameRoute, workspace: "workspace-d", provider: "ollama", route: "ollama/local"))
        let admittedIndependent = scheduler.submit(request(independent, workspace: "workspace-e", provider: "pi", route: "pi/local"))

        #expect(admittedFirst == [first])
        #expect(blockedWorkspace.isEmpty)
        #expect(blockedProvider.isEmpty)
        #expect(admittedLocal == [local])
        #expect(blockedRoute.isEmpty)
        #expect(admittedIndependent == [independent])
        #expect(scheduler.snapshots.filter { $0.state == .running }.count == 3)
    }

    @Test("priority aging prevents low priority starvation")
    func fairnessAgesLowPriority() {
        var scheduler = AgentTaskScheduler(limits: .init(global: 1, perWorkspace: 1), fairnessInterval: 1)
        let blocker = UUID(), low = UUID(), high1 = UUID(), high2 = UUID(), high3 = UUID()
        let admittedBlocker = scheduler.submit(request(blocker))
        _ = scheduler.submit(request(low, priority: .low))
        _ = scheduler.submit(request(high1, priority: .high))
        let afterBlocker = scheduler.finish(blocker)
        _ = scheduler.submit(request(high2, priority: .high))
        let afterHigh1 = scheduler.finish(high1)
        _ = scheduler.submit(request(high3, priority: .high))
        let afterHigh2 = scheduler.finish(high2)

        #expect(admittedBlocker == [blocker])
        #expect(afterBlocker == [high1])
        #expect(afterHigh1 == [high2])
        #expect(afterHigh2 == [low])
        #expect(scheduler.snapshot(for: high3)?.state == .queued)
    }

    @Test("reprioritization deterministically changes the next admission")
    func reprioritization() {
        var scheduler = AgentTaskScheduler(limits: .init(global: 1, perWorkspace: 1))
        let blocker = UUID(), first = UUID(), promoted = UUID()
        _ = scheduler.submit(request(blocker))
        _ = scheduler.submit(request(first, priority: .normal))
        _ = scheduler.submit(request(promoted, priority: .low))
        let reprioritized = scheduler.reprioritize(promoted, to: .high)
        let afterFinish = scheduler.finish(blocker)

        #expect(reprioritized.isEmpty)
        #expect(afterFinish == [promoted])
        #expect(scheduler.snapshot(for: first)?.queuePosition == 1)
    }

    @Test("cancelling one task preserves other runs and admits queued work")
    func cancellationIsIsolated() {
        var scheduler = AgentTaskScheduler(limits: .init(global: 2, perWorkspace: 2))
        let cancelled = UUID(), survivor = UUID(), queued = UUID()
        _ = scheduler.submit(request(cancelled))
        _ = scheduler.submit(request(survivor))
        _ = scheduler.submit(request(queued))

        let afterCancel = scheduler.cancel(cancelled)
        #expect(afterCancel == [queued])
        #expect(scheduler.snapshot(for: cancelled) == nil)
        #expect(scheduler.snapshot(for: survivor)?.state == .running)
        #expect(scheduler.snapshot(for: queued)?.state == .running)
    }

    @Test("approval waits release and reacquire a slot")
    func approvalTransitions() {
        var scheduler = AgentTaskScheduler(limits: .init(global: 1, perWorkspace: 1))
        let approval = UUID(), other = UUID()
        _ = scheduler.submit(request(approval))
        _ = scheduler.submit(request(other))

        let afterWait = scheduler.waitForApproval(approval, releasesExecutionSlot: true)
        #expect(afterWait == [other])
        #expect(scheduler.snapshot(for: approval)?.state == .waitingForApproval)

        let afterResolve = scheduler.resolveApproval(approval)
        #expect(afterResolve.isEmpty)
        #expect(scheduler.snapshot(for: approval)?.state == .queued)
        #expect(scheduler.snapshot(for: approval)?.isApprovalResume == true)

        let afterFinish = scheduler.finish(other)
        #expect(afterFinish == [approval])

        var held = AgentTaskScheduler(limits: .init(global: 1, perWorkspace: 1))
        let unsafeToRelease = UUID(), blocked = UUID()
        _ = held.submit(request(unsafeToRelease))
        _ = held.submit(request(blocked))
        let heldWait = held.waitForApproval(unsafeToRelease, releasesExecutionSlot: false)
        let heldLimits = held.updateLimits(held.limits)
        let heldCancel = held.cancel(unsafeToRelease)
        #expect(heldWait.isEmpty)
        #expect(heldLimits.isEmpty)
        #expect(heldCancel == [blocked])
    }

    @Test("recovery holds every task and never replays sensitive work")
    func recoveryIsFailClosed() throws {
        let ordinary = request(UUID())
        let approval = request(UUID(), sensitivity: .approvalSensitive)
        let external = request(UUID(), sensitivity: .externallyConsequential)
        let metadata = PersistedAgentTaskQueue(entries: [ordinary, approval, external])
        let encoded = try JSONEncoder().encode(metadata)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("prompt"))

        var recovered = AgentTaskScheduler(limits: .init(global: 3, perWorkspace: 3))
        recovered.recover(try JSONDecoder().decode(PersistedAgentTaskQueue.self, from: encoded))
        #expect(recovered.snapshots.allSatisfy { $0.state == .recoveryHeld })
        #expect(recovered.snapshots.filter { $0.state == .running }.isEmpty)
        #expect(recovered.persistedMetadata.entries.isEmpty)
    }

    @Test("updated concurrency limits admit safely without preempting active work")
    func updatedLimits() {
        var scheduler = AgentTaskScheduler(limits: .init(global: 1, perWorkspace: 1))
        let running = UUID(), queued = UUID()
        let first = scheduler.submit(request(running))
        let second = scheduler.submit(request(queued, workspace: "workspace-b", provider: "grok"))
        let raised = scheduler.updateLimits(.init(global: 2, perWorkspace: 1))
        let lowered = scheduler.updateLimits(.init(global: 1, perWorkspace: 1))

        #expect(first == [running])
        #expect(second == [])
        #expect(raised == [queued])
        #expect(scheduler.snapshot(for: running)?.state == .running)
        #expect(scheduler.snapshot(for: queued)?.state == .running)
        #expect(lowered == [])
        #expect(scheduler.snapshots.filter { $0.state == .running }.count == 2)
    }
}
