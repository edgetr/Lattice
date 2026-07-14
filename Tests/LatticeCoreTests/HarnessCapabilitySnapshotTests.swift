import Testing
@testable import LatticeCore

@Suite("Live harness capability snapshot")
struct HarnessCapabilitySnapshotTests {
    private let piRoute = ExecutionRoute(
        mode: .code,
        providerID: "opencode",
        modelID: "opencode-go/model",
        runtimeID: "pi"
    )

    @Test func derivesAvailabilityFromCurrentDiscovery() {
        let unavailable = readiness(
            runtimePresent: false,
            authenticationValidated: false,
            modelValidated: false,
            sandboxAvailable: true
        )
        let first = HarnessCapabilitySnapshot.resolve(
            route: piRoute,
            policy: .ask,
            readiness: unavailable,
            hasProviderSession: false,
            isRunning: false,
            routeCredentialEnabled: false
        )
        #expect(first.providerAvailability.assurance == .absent)
        #expect(first.providerAvailability.summary.contains("Runtime unavailable"))
        #expect(first.modelAvailability.assurance == .unknown)
        #expect(first.credentialBoundary.summary.contains("disabled"))

        let recovered = readiness(
            runtimePresent: true,
            authenticationValidated: true,
            modelValidated: true,
            sandboxAvailable: true
        )
        let second = HarnessCapabilitySnapshot.resolve(
            route: piRoute,
            policy: .ask,
            readiness: recovered,
            hasProviderSession: false,
            isRunning: false,
            routeCredentialEnabled: true
        )
        #expect(second.providerAvailability.assurance == .present)
        #expect(second.modelAvailability.assurance == .present)
        #expect(second.credentialBoundary.summary.contains("enabled"))
    }

    @Test func reportsUnknownInsteadOfInventingLegacyDiscovery() {
        let route = ExecutionRoute(
            mode: .code,
            providerID: "future-provider",
            modelID: "future-model",
            runtimeID: "future-runtime"
        )
        let snapshot = HarnessCapabilitySnapshot.resolve(
            route: route,
            policy: .smart,
            readiness: nil,
            hasProviderSession: false,
            isRunning: false
        )
        #expect(snapshot.protocolTransport.assurance == .unknown)
        #expect(snapshot.providerAvailability.assurance == .unknown)
        #expect(snapshot.modelAvailability.assurance == .unknown)
        #expect(snapshot.resumeState == .unknown)
        #expect(snapshot.sandboxOwner.assurance == .absent)
    }

    @Test func resumeStateTracksChatHandleAndActiveTurnWithoutExposingIt() {
        let ready = readiness(
            runtimePresent: true,
            authenticationValidated: true,
            modelValidated: true,
            sandboxAvailable: true
        )
        let fresh = HarnessCapabilitySnapshot.resolve(
            route: piRoute,
            policy: .ask,
            readiness: ready,
            hasProviderSession: false,
            isRunning: false
        )
        #expect(fresh.resumeState == .notEstablished)

        let resumable = HarnessCapabilitySnapshot.resolve(
            route: piRoute,
            policy: .ask,
            readiness: ready,
            hasProviderSession: true,
            isRunning: false
        )
        #expect(resumable.resumeState == .resumable)
        #expect(resumable.resume.summary == "Ready to resume")

        let active = HarnessCapabilitySnapshot.resolve(
            route: piRoute,
            policy: .ask,
            readiness: ready,
            hasProviderSession: true,
            isRunning: true
        )
        #expect(active.resumeState == .active)
        #expect(active.resume.detail.contains("holds the provider session handle"))
    }

    @Test func antigravityTruthfullyReportsTranscriptAndNoResume() {
        let route = ExecutionRoute(
            mode: .code,
            providerID: "antigravity",
            modelID: "discovered-model",
            runtimeID: "antigravity"
        )
        let snapshot = HarnessCapabilitySnapshot.resolve(
            route: route,
            policy: .smart,
            readiness: nil,
            hasProviderSession: true,
            isRunning: false
        )
        #expect(snapshot.protocolTransport.summary.contains("transcript"))
        #expect(snapshot.resumeState == .unsupported)
        #expect(snapshot.sandboxOwner.summary == "Provider")
        #expect(snapshot.routeCapability.writeContainment.detail.contains("does not independently verify"))
    }

    @Test func localTransportsRemainProviderSpecificAndHaveNoToolSandbox() {
        let apple = HarnessCapabilitySnapshot.resolve(
            route: .init(mode: .local, providerID: "apple", runtimeID: "lattice"),
            policy: .ask,
            readiness: nil,
            hasProviderSession: false,
            isRunning: false
        )
        let ollama = HarnessCapabilitySnapshot.resolve(
            route: .init(mode: .local, providerID: "ollama", modelID: "local", runtimeID: "lattice"),
            policy: .ask,
            readiness: nil,
            hasProviderSession: false,
            isRunning: false
        )
        #expect(apple.protocolTransport.summary.contains("in process"))
        #expect(ollama.protocolTransport.summary.contains("loopback"))
        #expect(apple.sandboxOwner.assurance == .notApplicable)
        #expect(ollama.resumeState == .unsupported)
    }

    private func readiness(
        runtimePresent: Bool,
        authenticationValidated: Bool,
        modelValidated: Bool,
        sandboxAvailable: Bool
    ) -> RouteReadinessSnapshot {
        RouteReadinessEvaluator.evaluate(
            route: piRoute,
            requirements: .init(
                runtimePresent: runtimePresent,
                authenticationValidated: authenticationValidated,
                modelValidated: modelValidated,
                sandboxAvailable: sandboxAvailable
            )
        )
    }
}
