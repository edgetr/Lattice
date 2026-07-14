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

        #expect(scheduler.submit(request(first)) == [first])
        #expect(scheduler.submit(request(sameWorkspace, provider: "grok", route: "grok/xai")).isEmpty)
        #expect(scheduler.submit(request(sameProvider, workspace: "workspace-b")).isEmpty)
        #expect(scheduler.submit(request(local, workspace: "workspace-c", provider: "ollama", route: "ollama/local")) == [local])
        #expect(scheduler.submit(request(sameRoute, workspace: "workspace-d", provider: "ollama", route: "ollama/local")).isEmpty)
        #expect(scheduler.submit(request(independent, workspace: "workspace-e", provider: "pi", route: "pi/local")) == [independent])
        #expect(scheduler.snapshots.filter { $0.state == .running }.count == 3)
    }

    @Test("priority aging prevents low priority starvation")
    func fairnessAgesLowPriority() {
        var scheduler = AgentTaskScheduler(limits: .init(global: 1, perWorkspace: 1), fairnessInterval: 1)
        let blocker = UUID(), low = UUID(), high1 = UUID(), high2 = UUID(), high3 = UUID()
        #expect(scheduler.submit(request(blocker)) == [blocker])
        scheduler.submit(request(low, priority: .low))
        scheduler.submit(request(high1, priority: .high))
        #expect(scheduler.finish(blocker) == [high1])
        scheduler.submit(request(high2, priority: .high))
        #expect(scheduler.finish(high1) == [high2])
        scheduler.submit(request(high3, priority: .high))
        #expect(scheduler.finish(high2) == [low])
        #expect(scheduler.snapshot(for: high3)?.state == .queued)
    }

    @Test("reprioritization deterministically changes the next admission")
    func reprioritization() {
        var scheduler = AgentTaskScheduler(limits: .init(global: 1, perWorkspace: 1))
        let blocker = UUID(), first = UUID(), promoted = UUID()
        scheduler.submit(request(blocker))
        scheduler.submit(request(first, priority: .normal))
        scheduler.submit(request(promoted, priority: .low))
        #expect(scheduler.reprioritize(promoted, to: .high).isEmpty)
        #expect(scheduler.finish(blocker) == [promoted])
        #expect(scheduler.snapshot(for: first)?.queuePosition == 1)
    }

    @Test("cancelling one task preserves other runs and admits queued work")
    func cancellationIsIsolated() {
        var scheduler = AgentTaskScheduler(limits: .init(global: 2, perWorkspace: 2))
        let cancelled = UUID(), survivor = UUID(), queued = UUID()
        scheduler.submit(request(cancelled))
        scheduler.submit(request(survivor))
        scheduler.submit(request(queued))

        #expect(scheduler.cancel(cancelled) == [queued])
        #expect(scheduler.snapshot(for: cancelled) == nil)
        #expect(scheduler.snapshot(for: survivor)?.state == .running)
        #expect(scheduler.snapshot(for: queued)?.state == .running)
    }

    @Test("approval waits release and reacquire a slot")
    func approvalTransitions() {
        var scheduler = AgentTaskScheduler(limits: .init(global: 1, perWorkspace: 1))
        let approval = UUID(), other = UUID()
        scheduler.submit(request(approval))
        scheduler.submit(request(other))

        #expect(scheduler.waitForApproval(approval, releasesExecutionSlot: true) == [other])
        #expect(scheduler.snapshot(for: approval)?.state == .waitingForApproval)
        #expect(scheduler.resolveApproval(approval).isEmpty)
        #expect(scheduler.snapshot(for: approval)?.state == .queued)
        #expect(scheduler.snapshot(for: approval)?.isApprovalResume == true)
        #expect(scheduler.finish(other) == [approval])

        var held = AgentTaskScheduler(limits: .init(global: 1, perWorkspace: 1))
        let unsafeToRelease = UUID(), blocked = UUID()
        held.submit(request(unsafeToRelease))
        held.submit(request(blocked))
        #expect(held.waitForApproval(unsafeToRelease, releasesExecutionSlot: false).isEmpty)
        #expect(held.updateLimits(held.limits).isEmpty)
        #expect(held.cancel(unsafeToRelease) == [blocked])
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
}
