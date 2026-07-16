import Testing
@testable import LatticeCore

@Suite("Route capability disclosure")
struct RouteCapabilityTests {

    // MARK: - Exhaustive matrix

    @Test(arguments: RouteCapability.knownHarnessIDs, ExecutionPolicy.allCases)
    func knownHarnessMatrixIsDeterministic(harnessID: String, policy: ExecutionPolicy) {
        let first = RouteCapability.resolve(harnessID: harnessID, policy: policy)
        let second = RouteCapability.resolve(harnessID: harnessID, policy: policy)
        #expect(first == second)
        #expect(first.harnessID == harnessID)
        #expect(first.policy == policy)
        #expect(!first.executionOwner.displayName.isEmpty)
        #expect(!first.brokerMediation.displayName.isEmpty)
        #expect(!first.writeContainment.summary.isEmpty)
        #expect(!first.approvalBehavior.summary.isEmpty)
        #expect(!first.fileReadRestriction.summary.isEmpty)
        #expect(!first.networkRestriction.summary.isEmpty)
        #expect(!first.credentialReadProtection.summary.isEmpty)
        #expect(!first.structuredEvents.summary.isEmpty)
        #expect(!first.providerSessionResume.summary.isEmpty)
        #expect(!first.cancellation.summary.isEmpty)
        #expect(!first.warnings.isEmpty)
        #expect(first.primaryWarning == first.warnings.first)
        #expect(first.lifecycleSummary.contains("Events:"))
        #expect(first.lifecycleSummary.contains("Resume:"))
        #expect(first.lifecycleSummary.contains("Cancel:"))
    }

    // MARK: - Codex mapping pin

    @Test func codexMappingMatchesProviderRouteTruthSource() {
        let ask = CodexProviderExecutionRoute.resolve(policy: .ask)
        #expect(ask.approvalPolicy == "on-request")
        #expect(ask.sandbox == "read-only")

        let askWrite = CodexProviderExecutionRoute.resolve(policy: .ask, workspaceWrite: true)
        #expect(askWrite.approvalPolicy == "on-request")
        #expect(askWrite.sandbox == "workspace-write")

        let smart = CodexProviderExecutionRoute.resolve(policy: .smart)
        #expect(smart.approvalPolicy == "on-request")
        #expect(smart.sandbox == "workspace-write")

        let yolo = CodexProviderExecutionRoute.resolve(policy: .yolo)
        #expect(yolo.approvalPolicy == "never")
        #expect(yolo.sandbox == "danger-full-access")
    }

    @Test(arguments: ExecutionPolicy.allCases)
    func selfEditCodexAlwaysLaunchesReadOnlyOnRequest(sessionPolicy: ExecutionPolicy) {
        _ = sessionPolicy
        let route = CodexProviderExecutionRoute.resolve(
            policy: SelfEditProviderLaunchPolicy.codexExecutionPolicy,
            workspaceWrite: SelfEditProviderLaunchPolicy.codexWorkspaceWrite
        )
        #expect(route.approvalPolicy == "on-request")
        #expect(route.sandbox == "read-only")
    }

    @Test func coldStartDoesNotInventAProviderModel() {
        #expect(BackendAvailabilityPolicy.initialSelection(persisted: nil) == .ollama(model: ""))
        #expect(BackendAvailabilityPolicy.initialSelection(persisted: .codex(model: "discovered")) == .codex(model: "discovered"))
    }

    @Test(arguments: ExecutionPolicy.allCases)
    func codexCapabilityDerivesFromSameMapping(policy: ExecutionPolicy) {
        let route = CodexProviderExecutionRoute.resolve(policy: policy)
        let capability = RouteCapability.resolve(harnessID: "codex", policy: policy)
        #expect(capability.executionOwner == .providerOwned)
        #expect(capability.brokerMediation == .notMediated)
        #expect(capability.writeContainment.detail.contains(route.sandbox))
        #expect(capability.approvalBehavior.detail.contains(route.approvalPolicy))
        #expect(capability.fileReadRestriction.assurance == .absent)
        #expect(capability.networkRestriction.assurance == .absent)
        #expect(capability.credentialReadProtection.assurance == .absent)
    }

    @Test func codexYOLOIsUnbrokeredUncontainedApprovalDisabled() {
        let capability = RouteCapability.resolve(harnessID: "codex", policy: .yolo)
        #expect(capability.brokerMediation == .notMediated)
        #expect(capability.writeContainmentKind == .none)
        #expect(capability.writeContainment.assurance == .absent)
        #expect(capability.writeContainment.summary.localizedCaseInsensitiveContains("absent"))
        #expect(capability.approvalBehaviorKind == .disabled)
        #expect(capability.approvalBehavior.summary.localizedCaseInsensitiveContains("disabled"))
        #expect(capability.warnings.contains(where: { $0.localizedCaseInsensitiveContains("danger-full-access") }))
        #expect(capability.warnings.contains(where: { $0.localizedCaseInsensitiveContains("LocalToolBroker") }))
    }

    @Test func codexAskDefaultIsProviderReadOnlyOnRequest() {
        let capability = RouteCapability.resolve(harnessID: "codex", policy: .ask)
        #expect(capability.writeContainmentKind == .readOnly)
        #expect(capability.approvalBehaviorKind == .providerRequestForwarding)
        #expect(capability.writeContainment.detail.localizedCaseInsensitiveContains("not Lattice sandbox-exec"))
    }

    @Test func codexAskExplicitWorkspaceWriteUsesProviderWorkspaceWrite() {
        let capability = RouteCapability.resolve(harnessID: "codex", policy: .ask, workspaceWrite: true)
        #expect(capability.writeContainmentKind == .providerConfiguredSandbox)
        #expect(capability.writeContainment.detail.contains("workspace-write"))
    }

    @Test func codexSmartIsProviderWorkspaceWriteOnRequest() {
        let capability = RouteCapability.resolve(harnessID: "codex", policy: .smart)
        #expect(capability.writeContainmentKind == .providerConfiguredSandbox)
        #expect(capability.approvalBehaviorKind == .providerRequestForwarding)
        #expect(capability.writeContainment.detail.contains("workspace-write"))
    }

    // MARK: - ACP / Pi

    @Test(arguments: ["grok", "opencode", "hermes"], ExecutionPolicy.allCases)
    func acpRoutesUseLatticeWriteContainmentButRemainProviderOwnedUnbrokered(
        harnessID: String,
        policy: ExecutionPolicy
    ) {
        let capability = RouteCapability.resolve(harnessID: harnessID, policy: policy)
        #expect(capability.executionOwner == .providerOwned)
        #expect(capability.brokerMediation == .notMediated)
        #expect(capability.writeContainmentKind == .latticeMacOSWriteContainment)
        #expect(capability.writeContainment.assurance == .enforced)
        #expect(capability.fileReadRestriction.assurance == .absent)
        #expect(capability.networkRestriction.assurance == .absent)
        #expect(capability.credentialReadProtection.assurance == .absent)
        #expect(capability.fileReadRestriction.summary.localizedCaseInsensitiveContains("unrestricted"))
        #expect(capability.networkRestriction.summary.localizedCaseInsensitiveContains("unrestricted"))
        #expect(capability.warnings.contains(where: { $0.localizedCaseInsensitiveContains("LocalToolBroker") }))
        switch policy {
        case .ask:
            #expect(capability.approvalBehaviorKind == .providerRequestForwarding)
        case .smart, .acceptEdits, .yolo:
            #expect(capability.approvalBehaviorKind == .automaticPolicyDecisionsAfterRequest)
        }
    }

    @Test(arguments: ExecutionPolicy.allCases)
    func piUsesLatticeWriteContainmentWithProviderOwnedUnbrokeredTools(policy: ExecutionPolicy) {
        let capability = RouteCapability.resolve(harnessID: "pi", policy: policy)
        #expect(capability.executionOwner == .providerOwned)
        #expect(capability.brokerMediation == .notMediated)
        #expect(capability.writeContainmentKind == .latticeMacOSWriteContainment)
        #expect(capability.fileReadRestriction.assurance == .absent)
        #expect(capability.networkRestriction.assurance == .absent)
        #expect(capability.credentialReadProtection.assurance == .absent)
        switch policy {
        case .ask, .smart:
            #expect(capability.approvalBehaviorKind == .providerRequestForwarding)
            #expect(capability.approvalBehavior.summary.localizedCaseInsensitiveContains("permission") ||
                    capability.approvalBehavior.detail.localizedCaseInsensitiveContains("write/edit/bash"))
        case .acceptEdits:
            #expect(capability.approvalBehaviorKind == .automaticPolicyDecisionsAfterRequest)
            #expect(capability.approvalBehavior.summary.localizedCaseInsensitiveContains("accept") ||
                    capability.approvalBehavior.detail.localizedCaseInsensitiveContains("reversible"))
        case .yolo:
            #expect(capability.approvalBehaviorKind == .automaticPolicyDecisionsAfterRequest)
            #expect(capability.approvalBehavior.summary.localizedCaseInsensitiveContains("auto-allow") ||
                    capability.approvalBehavior.detail.localizedCaseInsensitiveContains("auto-allow"))
        }
    }

    // MARK: - Antigravity

    @Test(arguments: [ExecutionPolicy.ask, .smart, .acceptEdits])
    func antigravityAskSmartArePlanOnlyProviderDeclared(policy: ExecutionPolicy) {
        let capability = RouteCapability.resolve(harnessID: "antigravity", policy: policy)
        #expect(capability.executionOwner == .providerOwned)
        #expect(capability.brokerMediation == .notMediated)
        #expect(capability.writeContainmentKind == .providerDeclaredSandbox)
        #expect(capability.approvalBehaviorKind == .planOnly)
        #expect(capability.structuredEvents.assurance == .unknown)
        #expect(capability.structuredEvents.summary.localizedCaseInsensitiveContains("runtime"))
        #expect(capability.providerSessionResume.detail.localizedCaseInsensitiveContains("never scraped"))
        #expect(capability.approvalBehavior.summary.localizedCaseInsensitiveContains("plan"))
        #expect(capability.warnings.contains(where: { $0.localizedCaseInsensitiveContains("independently verify") }))
    }

    @Test func antigravityYOLODisablesProviderPermissions() {
        let capability = RouteCapability.resolve(harnessID: "antigravity", policy: .yolo)
        #expect(capability.brokerMediation == .notMediated)
        #expect(capability.writeContainmentKind == .providerDeclaredSandbox)
        #expect(capability.approvalBehaviorKind == .disabled)
        #expect(capability.structuredEvents.assurance == .unknown)
        #expect(capability.approvalBehavior.summary.localizedCaseInsensitiveContains("disabled") ||
                capability.approvalBehavior.detail.localizedCaseInsensitiveContains("dangerously-skip-permissions"))
        #expect(capability.warnings.contains(where: { $0.localizedCaseInsensitiveContains("permissions") }))
    }

    // MARK: - Local lattice

    @Test(arguments: ExecutionPolicy.allCases)
    func latticeLocalRouteHasNoDelegatedTools(policy: ExecutionPolicy) {
        let capability = RouteCapability.resolve(harnessID: "lattice", policy: policy)
        #expect(capability.executionOwner == .noDelegatedTools)
        #expect(capability.brokerMediation == .notApplicable)
        #expect(capability.writeContainmentKind == .notApplicable)
        #expect(capability.approvalBehaviorKind == .notApplicable)
        #expect(capability.warnings.contains(where: { $0.localizedCaseInsensitiveContains("no delegated tool") }))
        #expect(capability.warnings.contains(where: {
            $0.localizedCaseInsensitiveContains("Apple Intelligence") ||
            $0.localizedCaseInsensitiveContains("Ollama") ||
            $0.localizedCaseInsensitiveContains("broker-mediated")
        }))
        // Must not pretend broker mediation for Apple Intelligence / Ollama lattice harness.
        #expect(capability.brokerMediation != .mediatedByLocalToolBroker)
    }

    // MARK: - Unknown fallback

    @Test(arguments: ExecutionPolicy.allCases)
    func unknownHarnessIsConservative(policy: ExecutionPolicy) {
        let capability = RouteCapability.resolve(harnessID: "mystery-agent", policy: policy)
        #expect(capability.harnessID == "mystery-agent")
        #expect(capability.brokerMediation == .notMediated)
        #expect(capability.writeContainment.assurance == .unknown)
        #expect(capability.approvalBehavior.assurance == .unknown)
        #expect(capability.fileReadRestriction.assurance == .unknown)
        #expect(capability.networkRestriction.assurance == .unknown)
        #expect(capability.credentialReadProtection.assurance == .absent)
        #expect(capability.warnings.contains(where: { $0.localizedCaseInsensitiveContains("unknown") }))
        #expect(capability.warnings.contains(where: { $0.localizedCaseInsensitiveContains("LocalToolBroker") }))
    }

    // MARK: - No live route claims broker mediation today

    @Test(arguments: RouteCapability.knownHarnessIDs, ExecutionPolicy.allCases)
    func noKnownLiveRouteClaimsBrokerMediation(harnessID: String, policy: ExecutionPolicy) {
        let capability = RouteCapability.resolve(harnessID: harnessID, policy: policy)
        #expect(capability.brokerMediation != .mediatedByLocalToolBroker)
    }
}
