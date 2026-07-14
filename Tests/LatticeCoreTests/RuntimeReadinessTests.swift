import Foundation
import Testing
@testable import LatticeCore

@Suite("Runtime readiness and setup")
struct RuntimeReadinessTests {
    private let route = ExecutionRoute(mode: .code, providerID: "opencode", modelID: "opencode-go/model", runtimeID: "pi")

    @Test func confirmationIDUsesRuntimeAndActionValues() {
        let request = RuntimeConfirmationRequest(runtime: .pi, action: .firstUseInstall)
        #expect(request.id == "pi:firstUseInstall")
    }

    @Test func runtimeActionsUsePlainConsistentVerbs() {
        #expect(RuntimeLifecyclePresentationPolicy.actionTitle(for: .firstUseInstall) == "Install")
        #expect(RuntimeLifecyclePresentationPolicy.actionTitle(
            for: .update,
            installedVersion: "0.79.3",
            targetVersion: "0.80.6"
        ) == "Update")
        #expect(RuntimeLifecyclePresentationPolicy.actionTitle(
            for: .update,
            installedVersion: "0.80.6",
            targetVersion: "0.80.6"
        ) == "Repair")
        #expect(RuntimeLifecyclePresentationPolicy.actionTitle(for: .uninstall) == "Remove")
        #expect(RuntimeLifecyclePresentationPolicy.actionTitle(for: .rollback) == "Restore Previous Version")
        #expect(RuntimeLifecyclePresentationPolicy.actionTitle(for: .cancel) == "Stop")
    }

    @Test func availabilityStatesUseConsistentUserFacingLanguage() {
        #expect(ExecutionRouteReadiness.loading.detail == "Checking availability…")
        #expect(ExecutionRouteReadiness.authenticationRequired.detail == "Sign in required.")
        #expect(ExecutionRouteReadiness.runnable.detail == "Available")
        #expect(!ExecutionRouteReadiness.validating.detail.localizedCaseInsensitiveContains("validating"))
    }

    @Test func readinessRequiresEachIndependentRequirement() {
        let missing = RouteReadinessEvaluator.evaluate(
            route: route,
            requirements: .init(runtimePresent: false, authenticationValidated: true, modelValidated: true, sandboxAvailable: true)
        )
        #expect(missing.readiness == .missingRuntime)

        let auth = RouteReadinessEvaluator.evaluate(
            route: route,
            requirements: .init(runtimePresent: true, authenticationValidated: false, modelValidated: true, sandboxAvailable: true)
        )
        #expect(auth.readiness == .authenticationRequired)

        let validating = RouteReadinessEvaluator.evaluate(
            route: route,
            requirements: .init(runtimePresent: true, authenticationValidated: true, modelValidated: true, sandboxAvailable: true),
            validating: true
        )
        #expect(validating.readiness == .validating)

        let noModel = RouteReadinessEvaluator.evaluate(
            route: route,
            requirements: .init(runtimePresent: true, authenticationValidated: true, modelValidated: false, sandboxAvailable: true)
        )
        #expect(!noModel.readiness.isRunnable)
        #expect(noModel.readiness.detail.contains("model"))

        let noSandbox = RouteReadinessEvaluator.evaluate(
            route: route,
            requirements: .init(runtimePresent: true, authenticationValidated: true, modelValidated: true, sandboxAvailable: false)
        )
        #expect(!noSandbox.readiness.isRunnable)
        #expect(noSandbox.readiness.detail.contains("sandbox"))

        let runnable = RouteReadinessEvaluator.evaluate(
            route: route,
            requirements: .init(runtimePresent: true, authenticationValidated: true, modelValidated: true, sandboxAvailable: true)
        )
        #expect(runnable.readiness == .runnable)
    }

    @Test func setupDescriptorsPinVersionWithoutInventingHashOrSize() {
        let pi = RuntimeInstallDescriptor.pi
        #expect(pi.source.contains("earendil-works/pi/releases/tag/v0.80.6"))
        #expect(pi.immutableVersion == "0.80.6")
        #expect(pi.installReference.hasSuffix("@0.80.6"))
        #expect(pi.estimatedSizeBytes == nil)
        #expect(!pi.hasPublishedHash)
        #expect(pi.registryIntegrity == "sha512-vcfD6tOk402isLl3Cm/qbn2O10TvgroMp1+/fEGM24ZdvETFCdOYv5VZ7m59EI5fPsjfSJh+CpQ5bhBrhfOg7g==")
        #expect(pi.verificationLabel.contains("not independently hashed"))

        let hermes = RuntimeInstallDescriptor.hermes
        #expect(hermes.source.contains("NousResearch/hermes-agent/releases/tag/v2026.7.7.2"))
        #expect(hermes.immutableVersion == "v2026.7.7.2")
        #expect(hermes.installReference.hasSuffix("@b7751df34688835a108e0d630f3495fc11f3df79"))
        #expect(hermes.pinnedSourceCommit == "b7751df34688835a108e0d630f3495fc11f3df79")
        #expect(hermes.estimatedSizeBytes == nil)
        #expect(!hermes.hasPublishedHash)
    }

    @Test func registryIntegrityMismatchFailsClosed() {
        let expected = RuntimeInstallDescriptor.pi.registryIntegrity!
        #expect(RuntimeArtifactVerification.registryIntegrityMatches(reported: "\"\(expected)\"\n", expected: expected))
        #expect(!RuntimeArtifactVerification.registryIntegrityMatches(reported: "sha512-wrong", expected: expected))
        #expect(!RuntimeArtifactVerification.registryIntegrityMatches(reported: expected, expected: ""))
    }

    @Test func cancellationAndRollbackTransitionsRemainTruthful() {
        #expect(RuntimeLifecycleTransition.phaseAfterCancellation(from: .installing) == .cancelled)
        #expect(RuntimeLifecycleTransition.phaseAfterCancellation(from: .updating) == .updateInterrupted)
        #expect(RuntimeLifecycleTransition.rollbackPhase(previousVersion: nil) == .failed)
        #expect(RuntimeLifecycleTransition.rollbackPhase(previousVersion: "0.79.3") == .rollingBack)
    }

    @Test func externalRuntimeCannotBeUninstalledByLattice() {
        #expect(!RuntimeOwnershipPolicy.canUninstall(.pi, managedRuntimeIDs: []))
        #expect(RuntimeOwnershipPolicy.canUninstall(.pi, managedRuntimeIDs: [.pi]))
        #expect(!RuntimeOwnershipPolicy.canUninstall(.hermes, managedRuntimeIDs: [.pi]))
    }

    @Test func onlySuccessfulFirstUseInstallCreatesRuntimeOwnership() {
        #expect(RuntimeOwnershipPolicy.shouldRecordOwnership(
            after: .firstUseInstall,
            status: 0,
            executableAvailable: true
        ))
        #expect(!RuntimeOwnershipPolicy.shouldRecordOwnership(
            after: .update,
            status: 0,
            executableAvailable: true
        ))
        #expect(!RuntimeOwnershipPolicy.shouldRecordOwnership(
            after: .firstUseInstall,
            status: 1,
            executableAvailable: true
        ))
    }

    @Test func providerOwnedChildEnvironmentExcludesAmbientSecrets() {
        let environment = ChildProcessEnvironmentPolicy.providerOwnedRuntime(
            from: [
                "PATH": "/usr/bin",
                "HOME": "/Users/example",
                "OPENAI_API_KEY": "synthetic-secret",
                "GITHUB_TOKEN": "synthetic-token",
                "AWS_SECRET_ACCESS_KEY": "synthetic-aws-secret"
            ],
            temporaryDirectory: URL(fileURLWithPath: "/tmp/lattice-child")
        )

        #expect(environment["PATH"] == "/usr/bin")
        #expect(environment["HOME"] == "/Users/example")
        #expect(environment["TMPDIR"] == "/tmp/lattice-child/")
        #expect(environment["OPENAI_API_KEY"] == nil)
        #expect(environment["GITHUB_TOKEN"] == nil)
        #expect(environment["AWS_SECRET_ACCESS_KEY"] == nil)
    }

    @Test func legacyOpenCodeBridgeCannotServeNewPiOrHermesRoutes() {
        let direct = ExecutionRoute(mode: .code, providerID: "opencode", modelID: "legacy-model", runtimeID: "opencode")
        let pi = ExecutionRoute(mode: .code, providerID: "opencode", modelID: "opencode-go/model", runtimeID: "pi")
        let hermes = ExecutionRoute(mode: .work, providerID: "opencode", modelID: "opencode-go:model", runtimeID: "hermes")

        #expect(LegacyOpenCodeBridgePolicy.allows(direct))
        #expect(!LegacyOpenCodeBridgePolicy.allows(pi))
        #expect(!LegacyOpenCodeBridgePolicy.allows(hermes))
    }

    @Test func OpenCodeKeychainCredentialIsLimitedToPiAndHermesAndUsesRuntimeEnvNames() {
        let pi = route
        let hermesGo = ExecutionRoute(mode: .work, providerID: "opencode", modelID: "opencode-go:model", runtimeID: "hermes")
        let hermesZen = ExecutionRoute(mode: .work, providerID: "opencode", modelID: "opencode-zen:model", runtimeID: "hermes")
        let direct = ExecutionRoute(mode: .code, providerID: "opencode", modelID: "opencode-go/model", runtimeID: "opencode")

        #expect(OpenCodeCredentialPolicy.allowsKeychainCredential(for: pi))
        #expect(OpenCodeCredentialPolicy.allowsKeychainCredential(for: hermesGo))
        #expect(OpenCodeCredentialPolicy.allowsKeychainCredential(for: hermesZen))
        #expect(!OpenCodeCredentialPolicy.allowsKeychainCredential(for: direct))
        #expect(OpenCodeCredentialPolicy.allowsKeychainCredential(for: pi, enabledModes: [.code]))
        #expect(!OpenCodeCredentialPolicy.allowsKeychainCredential(for: pi, enabledModes: [.work]))
        #expect(OpenCodeCredentialPolicy.allowsKeychainCredential(for: hermesGo, enabledModes: [.work]))
        #expect(!OpenCodeCredentialPolicy.allowsKeychainCredential(for: hermesGo, enabledModes: [.code]))
        #expect(OpenCodeCredentialPolicy.environmentKey(for: pi) == "OPENCODE_API_KEY")
        #expect(OpenCodeCredentialPolicy.environmentKey(for: hermesGo) == "OPENCODE_GO_API_KEY")
        #expect(OpenCodeCredentialPolicy.environmentKey(for: hermesZen) == "OPENCODE_ZEN_API_KEY")
        #expect(OpenCodeCredentialPolicy.environmentKey(for: direct) == nil)
    }

    @Test func routeReadinessUsesExplicitCompactStatusWords() {
        #expect(ExecutionRouteReadiness.loading.conciseStatus == "checking")
        #expect(ExecutionRouteReadiness.validating.conciseStatus == "checking")
        #expect(ExecutionRouteReadiness.missingRuntime.conciseStatus == "setup needed")
        #expect(ExecutionRouteReadiness.authenticationRequired.conciseStatus == "sign-in needed")
        #expect(ExecutionRouteReadiness.runnable.conciseStatus == "ready")
        #expect(ExecutionRouteReadiness.failed("offline").conciseStatus == "unavailable")
    }

    @Test func readinessActionsResolveToExactRecoveryFlows() {
        let setup = HarnessReadinessActionPolicy.resolve(readiness: .missingRuntime, modeName: "Code", runtimeName: "Pi")
        #expect(setup.kind == .setupRuntime)
        #expect(setup.title == "Set Up Code")
        #expect(setup.isInteractive && setup.isEnabled)

        let signIn = HarnessReadinessActionPolicy.resolve(readiness: .authenticationRequired, modeName: "Work", runtimeName: "Hermes")
        #expect(signIn.kind == .signIn)
        #expect(signIn.title == "Sign In to Work")
        #expect(signIn.accessibilityHint.contains("only after"))

        let credential = HarnessReadinessActionPolicy.resolve(readiness: .authenticationRequired, modeName: "Code", runtimeName: "Pi", authenticationAction: .validate)
        #expect(credential.kind == .validate)
        #expect(credential.title == "Check Code")
    }

    @Test func readyAndLoadingReadinessRemainNonInteractiveState() {
        let ready = HarnessReadinessActionPolicy.resolve(readiness: .runnable, modeName: "Code", runtimeName: "Pi")
        #expect(ready.kind == .stateOnly)
        #expect(ready.title == "Code ready")
        #expect(!ready.isInteractive && !ready.isEnabled)

        let loading = HarnessReadinessActionPolicy.resolve(readiness: .validating, modeName: "Work", runtimeName: "Hermes")
        #expect(loading.kind == .stateOnly)
        #expect(loading.title == "Work checking")
        #expect(!loading.isInteractive && !loading.isEnabled)
    }

    @Test func failureOffersDiagnosticsAndBusyActionRejectsDuplicateActivation() {
        let failure = HarnessReadinessActionPolicy.resolve(readiness: .failed("Model check failed."), modeName: "Work", runtimeName: "Hermes", actionAvailable: false)
        #expect(failure.kind == .diagnostics)
        #expect(failure.title == "Diagnose Work")
        #expect(failure.isInteractive)
        #expect(!failure.isEnabled)
        #expect(failure.accessibilityHint.contains("Wait"))
    }

    @Test func authenticationContinuationIsTypedAndIndependentOfCopy() {
        #expect(HarnessReadinessAuthenticationPhase.signInRequired.action == .signIn)
        #expect(HarnessReadinessAuthenticationPhase.afterTerminalOpen(succeeded: true).action == .validate)
        #expect(HarnessReadinessAuthenticationPhase.afterTerminalOpen(succeeded: false).action == .signIn)
        #expect(HarnessReadinessAuthenticationPhase.afterValidation().action == .signIn)
    }
}
